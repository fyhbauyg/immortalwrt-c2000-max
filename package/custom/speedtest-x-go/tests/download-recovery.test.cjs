'use strict';

// Reuse the existing socket-free virtual transport without executing its suite.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const { createRequire } = require('node:module');
const testFile = path.join(__dirname, 'worker.test.cjs');
const source = fs.readFileSync(testFile, 'utf8');
const boundary = source.indexOf('const cases = [];');
assert.ok(boundary > 0, 'existing transport harness boundary');
const context = { require: createRequire(testFile), __dirname, process, console,
  URL, TextDecoder, TextEncoder, ReadableStream, Blob, AbortController };
vm.createContext(context);
vm.runInContext(source.slice(0, boundary) + '\nglobalThis.Harness = Harness;', context, { filename: testFile });
class Transport extends context.Harness {
  constructor(options = {}) {
    super(Object.assign({ health: { protocol: 3, upload_session: true, max_download_mib: 50, max_streams: 24 } }, options));
  }
  async clean() {
    await this.flush();
    const diagnostic = this.worker.diagnostics();
    assert.equal(diagnostic.requests, 0);
    assert.equal(diagnostic.timers, 0);
    assert.ok(this.requests.every(r => r.aborted), 'all controllers released');
    // Mock headers can be cancelled before getReader() is ever called.
    assert.ok(this.readers.filter(r => r.reads > 0).every(r => r.cancelled && r.released), 'acquired readers released');
  }
  fetch(url, init) {
    if (!String(url).includes('/garbage.php')) return super.fetch(url, init);
    this.downloadCalls = (this.downloadCalls || 0) + 1;
    const previous = this.options;
    this.options = Object.assign({}, previous, this.plan?.(this.downloadCalls));
    (this.downloadOptions ||= []).push(this.options);
    try { return super.fetch(url, init); }
    finally { this.options = previous; }
  }
}
function complete(h, seconds) {
  const s = h.result();
  assert.equal(s.testState, 4, s.error);
  assert.equal(s.measurements.download.elapsedSeconds, seconds);
  assert.equal(s.measurements.download.bytes, h.delivered);
  assert.equal(Number(s.dlStatus), Number((h.delivered * 8 / seconds / 1e6).toFixed(2)));
  return s;
}
const cases = [];
const test = (name, fn) => cases.push({ name, fn });

for (const [label, stall] of [
  ['response headers', { headerDelay: 20000 }],
  ['response body', { chunkDelay: 20000 }],
]) {
  test('one stalled ' + label + ' restarts only that stream and keeps true elapsed', async () => {
    const h = new Transport();
    h.plan = n => n === 1 ? stall : {};
    h.start('D', { time_dl_max: 10 });
    await h.until(11000);
    const s = complete(h, 10);
    assert.equal(h.downloadCalls, 5);
    assert.equal(s.measurements.download.interruptions, 1);
    assert.equal(s.measurements.download.retries, 1);
    assert.equal(s.measurements.download.retiredStreams, 0);
    assert.equal(s.measurements.download.degraded, true);
    assert.ok(s.warning);
    await h.clean();
  });
}

test('persistently stalled stream retires after two retries, healthy streams finish with warning', async () => {
  const h = new Transport();
  h.plan = n => n === 1 || n > 4 ? { chunkDelay: 40000 } : {};
  h.start('D', { time_dl_max: 20 });
  await h.until(21000);
  const s = complete(h, 20);
  assert.equal(h.downloadCalls, 6);
  assert.equal(s.measurements.download.interruptions, 3);
  assert.equal(s.measurements.download.retries, 2);
  assert.equal(s.measurements.download.retiredStreams, 1);
  assert.match(s.warning, /1 条异常连接/);
  await h.clean();
});

for (const [name, plan] of [
  ['all stalled headers', () => ({ headerDelay: 40000 })],
  ['all stalled bodies', () => ({ chunkDelay: 40000 })],
  ['zero-length chunks are not progress', () => ({ chunkBytes: 0 })],
]) {
  test(name + ' remains a bounded hard failure', async () => {
    const h = new Transport();
    h.plan = plan;
    h.start('D', { time_dl_max: 15 });
    await h.until(6000);
    assert.equal(h.result().testState, 5);
    assert.match(h.result().error, /Download timed out: no data/);
    assert.ok(!h.result().measurements.download);
    assert.equal(h.downloadCalls, 4);
    assert.ok(h.messages.at(-1).at <= 5001);
    assert.equal(h.worker.diagnostics().requests, 0);
    assert.equal(h.worker.diagnostics().timers, 0);
  });
}

test('earlier healthy bytes do not hide a later global stall', async () => {
  const h = new Transport();
  h.start('D', { time_dl_max: 15 });
  await h.until(250);
  for (const options of h.downloadOptions) options.chunkDelay = 40000;
  await h.until(6500);
  assert.ok(h.delivered > 0);
  assert.equal(h.result().testState, 5);
  assert.match(h.result().error, /no data received on any stream/);
  assert.ok(!h.result().measurements.download);
  await h.clean();
});

test('warmup also requires real global progress', async () => {
  const h = new Transport({ chunkDelay: 40000 });
  h.start('D', { time_dl_max: 15, time_dlGraceTime: 5 });
  await h.until(6000);
  assert.equal(h.result().testState, 5);
  assert.match(h.result().error, /no data received on any stream/);
  assert.ok(!h.result().measurements.download);
  await h.clean();
});

for (const [name, broken, pattern] of [
  ['HTTP 503', { downloadStatus: 503 }, /HTTP 503/],
  ['truncation', { chunks: 1 }, /Truncated download/],
  ['oversized body', { length: '1' }, /exceeded Content-Length/],
  ['missing content length', { length: null }, /Content-Length/],
  ['unknown read failure', { readError: true }, /read failure/],
]) {
  test(name + ' in one stream still fails the stage instead of retrying or hiding it', async () => {
    const h = new Transport();
    h.plan = n => n === 1 ? broken : {};
    h.start('D', { time_dl_max: 10 });
    await h.until(2000);
    assert.equal(h.result().testState, 5);
    assert.match(h.result().error, pattern);
    assert.equal(h.downloadCalls, 4);
    assert.ok(!h.result().measurements.download);
    await h.clean();
  });
}

test('deadline wins over a same-time stream idle timeout without needless retry', async () => {
  const h = new Transport();
  h.plan = n => n === 1 ? { chunkDelay: 20000 } : {};
  h.start('D', { time_dl_max: 5 });
  await h.until(6000);
  const s = complete(h, 5);
  assert.equal(h.downloadCalls, 4);
  assert.equal(s.measurements.download.retries, 0);
  assert.equal(s.measurements.download.interruptions, 0);
  await h.clean();
});

test('abort during recovery cleans all timers and never starts another retry', async () => {
  const h = new Transport();
  h.plan = n => n === 1 || n > 4 ? { chunkDelay: 40000 } : {};
  h.start('D', { time_dl_max: 20 });
  await h.until(5100);
  assert.equal(h.downloadCalls, 5);
  h.worker.handleMessage('abort');
  await h.until(30000);
  assert.equal(h.result().phase, 'cancelled');
  assert.equal(h.downloadCalls, 5);
  assert.ok(!h.result().measurements.download);
  await h.clean();
});

(async () => {
  for (const entry of cases) {
    try { await entry.fn(); console.log('PASS ' + entry.name); }
    catch (error) { console.error('FAIL ' + entry.name); throw error; }
  }
  console.log(`download recovery: ${cases.length}/${cases.length} socket-free regressions passed`);
})().catch(error => { console.error(error); process.exitCode = 1; });
