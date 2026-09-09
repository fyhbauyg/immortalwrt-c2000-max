'use strict';

// No sockets: the production worker is exercised with a virtual clock/transport.
// SPEEDTEST_SOURCE may name the worker .js file or its containing web directory.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const supplied = process.env.SPEEDTEST_SOURCE;
const source = supplied ? (fs.statSync(supplied).isDirectory() ? path.join(supplied, 'speedtest_worker.js') : supplied) :
  [path.join(__dirname, '../src/web/speedtest_worker.js'), path.join(__dirname, '../src/speedtest-x-go/src/web/speedtest_worker.js')].find(fs.existsSync);
const { createWorker } = require(source);
const MiB = 1024 * 1024;

class Harness {
  constructor(options = {}) {
    this.options = options;
    this.time = 0;
    this.serial = 0;
    this.events = new Map();
    this.messages = [];
    this.requests = [];
    this.blobs = new Set();
    this.workerTimers = 0;
    this.reads = 0;
    this.readers = [];
    this.acked = 0;
    this.delivered = 0;
    this.env = {
      fetch: this.fetch.bind(this), URL, TextDecoder, ReadableStream, Blob, AbortController,
      performance: { now: () => this.time }, location: { href: 'http://unit.invalid/speedtest_worker.js' },
      crypto: { getRandomValues: a => a.fill(37) },
      postMessage: message => this.messages.push({ at: this.time, state: JSON.parse(message) }),
      setTimeout: (fn, ms) => { this.workerTimers++; return this.schedule(fn, ms); },
      clearTimeout: id => this.events.delete(id),
    };
    this.worker = createWorker(this.env);
  }
  schedule(fn, ms) {
    const id = ++this.serial;
    this.events.set(id, { id, at: this.time + Math.max(0, ms), fn });
    return id;
  }
  async flush() { for (let i = 0; i < 40; i++) await Promise.resolve(); }
  async until(end) {
    await this.flush();
    let iterations = 0;
    for (;;) {
      const next = [...this.events.values()].filter(e => e.at <= end).sort((a, b) => a.at - b.at || a.id - b.id)[0];
      if (!next) break;
      assert.ok(++iterations < 150000, 'bounded virtual event loop');
      this.events.delete(next.id);
      this.time = next.at;
      next.fn();
      await this.flush();
    }
    this.time = end;
    await this.flush();
  }
  later(ms, signal, fn, ignoreAbort = false) {
    return new Promise((resolve, reject) => {
      let settled = false;
      const stop = () => {
        if (settled) return;
        settled = true;
        this.events.delete(id);
        reject(new Error('mock transport aborted'));
      };
      const id = this.schedule(() => {
        if (settled) return;
        settled = true;
        signal?.removeEventListener('abort', stop);
        try { resolve(fn()); } catch (error) { reject(error); }
      }, ms);
      if (!ignoreAbort) {
        signal?.addEventListener('abort', stop, { once: true });
        if (signal?.aborted) stop();
      }
    });
  }
  response(data, status = 200) {
    const bytes = new TextEncoder().encode(typeof data === 'string' ? data : JSON.stringify(data));
    return {
      status, ok: status >= 200 && status < 300, headers: { get: () => null },
      body: { getReader: () => {
        let read = false;
        return {
          read: async () => read ? { done: true } : (read = true, { done: false, value: bytes }),
          cancel: async () => {}, releaseLock() {},
        };
      } },
    };
  }
  fetch(url, init = {}) {
    const parsed = new URL(url);
    const call = { at: this.time, url: parsed, init, aborted: false };
    this.requests.push(call);
    init.signal.addEventListener('abort', () => { call.aborted = true; }, { once: true });
    const o = this.options;
    if (parsed.pathname.endsWith('/healthz')) {
      return this.later(o.healthDelay ?? 1, init.signal, () => this.response(o.health ?? {
        protocol: 3, upload_session: true, max_download_mib: o.maxDownload ?? 50, max_streams: 24,
      }));
    }
    if (parsed.pathname.endsWith('/getIP.php')) {
      return this.later(1, init.signal, () => this.response({ processedString: '192.0.2.2 - LAN' }));
    }
    if (parsed.pathname.endsWith('/empty.php') && init.method !== 'POST') {
      const delay = o.pingDelays ? o.pingDelays.shift() : 0.5;
      return this.later(delay, init.signal, () => this.response(''));
    }
    if (init.method === 'POST') {
      assert.equal(parsed.searchParams.get('ack'), '1');
      this.blobs.add(init.body);
      return this.later(o.uploadDelay ?? 300, init.signal, () => {
        if (o.uploadError) throw new Error('upload network failure');
        const value = o.ack === undefined ? { bytes: init.body.size } : o.ack;
        if (!o.uploadStatus && value.bytes === init.body.size) this.acked += init.body.size;
        return this.response(value, o.uploadStatus ?? 200);
      }, o.ignoreUploadAbort);
    }
    if (parsed.pathname.endsWith('/garbage.php')) {
      const record = { cancelled: false, released: false, reads: 0 };
      this.readers.push(record);
      const chunk = new Uint8Array(o.chunkBytes ?? 64000);
      const response = {
        ok: (o.downloadStatus ?? 200) === 200, status: o.downloadStatus ?? 200,
        headers: { get: name => name === 'content-length' ? (o.length === undefined ? String(50 * MiB) : o.length) : null },
        arrayBuffer: () => { throw new Error('whole-response buffering forbidden'); },
        body: { getReader: () => ({
          read: () => this.later(o.chunkDelay ?? 100, init.signal, () => {
            this.reads++; record.reads++;
            if (o.readError) throw new Error('download read failure');
            if (record.reads > (o.chunks ?? Infinity)) return { done: true };
            this.delivered += chunk.byteLength;
            return { done: false, value: chunk };
          }, o.ignoreReadAbort),
          cancel: async () => { record.cancelled = true; },
          releaseLock: () => { record.released = true; },
        }) },
      };
      return this.later(o.headerDelay ?? 0, init.signal, () => response);
    }
    throw new Error('Unexpected mock URL ' + url);
  }
  start(direction = 'D', extra = {}) {
    this.worker.handleMessage('start ' + JSON.stringify({
      test_order: direction, time_dl_max: 1, time_ul_max: 1,
      time_dlGraceTime: 0, time_ulGraceTime: 0,
      xhr_dlMultistream: 4, xhr_ulMultistream: 4, ...extra,
    }));
  }
  result() { return this.worker.snapshot(); }
  async clean() {
    await this.flush();
    assert.deepEqual(this.worker.diagnostics(), { requests: 0, timers: 0 });
    assert.ok(this.requests.every(r => r.aborted), 'all fetch controllers released');
    assert.ok(this.readers.every(r => r.cancelled && r.released), 'all download readers released');
  }
}

const cases = [];
const test = (name, fn) => cases.push({ name, fn });
const near = (actual, expected, epsilon = 0.00001) => assert.ok(Math.abs(actual - expected) <= epsilon, `${actual} != ${expected}`);

test('streamed bytes / monotonic fixed elapsed, no overhead or auto-shortening', async () => {
  const h = new Harness();
  const original = Date.now;
  Date.now = () => { throw new Error('wall clock used for measurement'); };
  try {
    h.start('D', { time_dl_max: 10, time_auto: true, overheadCompensationFactor: 999 });
    await h.until(11000);
    const s = h.result();
    assert.equal(s.testState, 4, s.error);
    near(s.measurements.download.elapsedSeconds, 10);
    near(Number(s.dlStatus), s.measurements.download.bytes * 8 / 10 / 1e6, 0.0051);
    assert.equal(s.measurements.download.bytes, h.delivered);
    await h.clean();
  } finally { Date.now = original; }
});

// Protocol-2 ACK-drain upload tests have moved to upload-session-worker.test.cjs.
// Their integrity/Blob/cleanup coverage is retained there, but ACK drain is no
// longer the numerator or denominator: server reads use a fixed session window.

for (const [name, options, pattern] of [
  ['old protocol', { health: { protocol: 1 } }, /protocol 3/],
  ['health timeout', { healthDelay: 70000 }, /timed out/],
  ['download 503', { downloadStatus: 503 }, /HTTP 503/],
  ['download read error', { readError: true }, /read failure/],
  ['empty body', { chunks: 0 }, /Empty download/],
  ['truncated body', { chunks: 1 }, /Truncated download/],
  ['oversized body', { length: '1' }, /exceeded Content-Length/],
  ['missing length', { length: null }, /Content-Length/],
  ['stalled body', { chunkDelay: 20000 }, /timed out/],
  ['stalled headers', { headerDelay: 20000 }, /timed out/],
]) {
  test(name + ' cannot produce a valid result', async () => {
    const h = new Harness(options);
    h.start('D', { time_dl_max: 10 });
    await h.until(80000);
    assert.equal(h.result().testState, 5);
    assert.match(h.result().error, pattern);
    assert.ok(!h.messages.some(m => m.state.testState === 4));
    // A fetch cancelled before headers has no reader to acquire/release.
    assert.deepEqual(h.worker.diagnostics(), { requests: 0, timers: 0 });
    assert.ok(h.requests.every(r => r.aborted));
  });
}

// HTTP 413/503, network errors and all malformed ACK cases are exercised by
// upload-session-worker.test.cjs. A late ACK may now correctly succeed if the
// authoritative fixed receiver window completed; late/missing controls may not.

test('unsupported stream API fails explicitly before network use', async () => {
  const h = new Harness();
  h.env.ReadableStream = undefined;
  h.start();
  await h.flush();
  assert.match(h.result().error, /ReadableStream/);
  assert.equal(h.requests.length, 0);
  await h.clean();
});

test('server download cap is honored in request query', async () => {
  const h = new Harness({ maxDownload: 3 });
  h.start();
  await h.until(2000);
  assert.equal(h.result().testState, 4);
  assert.ok(h.requests.filter(r => r.url.pathname.endsWith('garbage.php')).every(r => r.url.searchParams.get('ckSize') === '3'));
  await h.clean();
});

test('download warmup preserves connections but contributes no measured bytes/time', async () => {
  const h = new Harness();
  h.start('D', { time_dlGraceTime: 1 });
  await h.until(3000);
  const s = h.result();
  assert.equal(s.testState, 4, s.error);
  near(s.measurements.download.elapsedSeconds, 1);
  assert.ok(s.measurements.download.bytes < h.delivered);
  assert.equal(h.requests.filter(r => r.url.pathname.endsWith('garbage.php')).length, 4);
  await h.clean();
});

// Continuous warmup exclusion is verified by a POST spanning the receiver's
// warmup boundary in upload-session-worker.test.cjs (no drain/restart gap).

test('ping uses mean round-trip and mean absolute jitter without 1ms floor', async () => {
  const h = new Harness({ pingDelays: [4, 0.2, 0.4, 0.6] });
  h.start('P', { count_ping: 3 });
  await h.until(1000);
  assert.equal(h.result().testState, 4);
  assert.equal(h.result().pingStatus, '0.40');
  assert.equal(h.result().jitterStatus, '0.20');
  await h.clean();
});

test('abort, duplicate start and immediate restart isolate stale responses', async () => {
  const h = new Harness({ chunkDelay: 7000, ignoreReadAbort: true });
  h.start('D', { time_dl_max: 10 });
  await h.until(20);
  h.start('D');
  assert.equal(h.requests.filter(r => r.url.pathname.endsWith('healthz')).length, 1);
  h.worker.handleMessage('abort');
  assert.equal(h.result().phase, 'cancelled');
  assert.equal(h.result().error, '');
  h.options.chunkDelay = 100;
  h.start('D');
  await h.until(3000);
  const finished = h.result();
  assert.equal(finished.testState, 4, finished.error);
  await h.until(15000);
  assert.deepEqual(h.result(), finished);
  await h.clean();
});

test('many chunks use bounded watchdog timers and no per-chunk Promise.race', async () => {
  const h = new Harness({ chunkDelay: 0.1, chunkBytes: 4096 });
  const original = Promise.race;
  let races = 0;
  Promise.race = function (iterable) { races++; return original.call(this, iterable); };
  try {
    h.start('D');
    await h.until(1200);
    assert.equal(h.result().testState, 4, h.result().error);
    assert.ok(h.reads > 30000, String(h.reads));
    assert.ok(h.workerTimers < 50, 'worker timers ' + h.workerTimers);
    assert.ok(races < 30, 'Promise.race count ' + races);
    await h.clean();
  } finally { Promise.race = original; }
});

(async () => {
  let passed = 0;
  for (const entry of cases) {
    try { await entry.fn(); passed++; console.log('PASS ' + entry.name); }
    catch (error) { console.error('FAIL ' + entry.name); throw error; }
  }
  console.log(`worker: ${passed}/${cases.length} mock regressions passed; no network or device use`);
})().catch(error => { console.error(error); process.exitCode = 1; });
