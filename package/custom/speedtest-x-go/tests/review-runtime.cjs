'use strict';

// Independent virtual browser/network for review tests. It never opens a socket.
const assert = require('node:assert/strict');

class ReviewRuntime {
  constructor(options = {}) {
    this.options = options;
    this.now = 0;
    this.serial = 0;
    this.events = new Map();
    this.messages = [];
    this.requests = [];
    this.deliveredBytes = 0;
    this.deliveries = [];
    this.acknowledgedBytes = 0;
    this.blobs = new Set();
    this.workerTimerSchedules = 0;
    this.clock = () => this.now;
    this.env = {
      performance: { now: this.clock },
      Date: class extends Date { static now() { return -123456789; } },
      fetch: this.fetch.bind(this),
      setTimeout: (...args) => { this.workerTimerSchedules++; return this.setTimeout(...args); },
      clearTimeout: this.clearTimeout.bind(this),
      setInterval: this.setInterval.bind(this),
      clearInterval: this.clearTimeout.bind(this),
      postMessage: (message) => this.messages.push({ time: this.now, data: typeof message === 'string' ? JSON.parse(message) : message }),
      AbortController,
      Blob,
      ReadableStream,
      TextDecoder,
      Uint8Array,
      URL,
      URLSearchParams,
      Math,
      JSON,
      console: { log() {}, warn() {}, error() {} },
      navigator: { userAgent: 'ReviewBrowser' },
      crypto: { getRandomValues: (array) => array.fill(19) },
      location: { href: 'http://review.invalid/speedtest_worker.js' },
      addEventListener() {},
    };
    this.env.self = this.env;
  }

  setTimeout(callback, delay = 0) {
    const id = ++this.serial;
    this.events.set(id, { id, at: this.now + Math.max(0, Number(delay)), callback });
    return id;
  }

  setInterval(callback, delay = 0) {
    const id = ++this.serial;
    this.events.set(id, { id, at: this.now + Math.max(1, Number(delay)), callback, interval: Math.max(1, Number(delay)) });
    return id;
  }

  clearTimeout(id) { this.events.delete(id); }

  async flush() {
    // Nested async functions in the worker may need several promise turns.
    for (let i = 0; i < 32; ++i) await Promise.resolve();
  }

  async until(time) {
    await this.flush();
    let count = 0;
    while (true) {
      const event = [...this.events.values()].filter((e) => e.at <= time).sort((a, b) => a.at - b.at || a.id - b.id)[0];
      if (!event) break;
      assert.ok(++count < 100000, 'virtual event loop must be bounded');
      this.now = event.at;
      this.events.delete(event.id);
      if (event.interval) this.events.set(event.id, { ...event, at: this.now + event.interval });
      event.callback();
      await this.flush();
    }
    this.now = time;
    await this.flush();
  }

  later(delay, signal, action, ignoreAbort = false) {
    return new Promise((resolve, reject) => {
      let done = false;
      const fail = () => {
        if (done) return;
        done = true;
        this.clearTimeout(timer);
        reject(Object.assign(new Error('aborted'), { name: 'AbortError' }));
      };
      const timer = this.setTimeout(() => {
        if (done) return;
        done = true;
        signal?.removeEventListener('abort', fail);
        try { resolve(action()); } catch (error) { reject(error); }
      }, delay);
      if (!ignoreAbort) {
        signal?.addEventListener('abort', fail, { once: true });
        if (signal?.aborted) fail();
      }
    });
  }

  fetch(url, init = {}) {
    const parsed = new URL(url, 'http://review.invalid/');
    const req = { url: parsed, time: this.now, init, settled: false, aborted: false };
    this.requests.push(req);
    init.signal?.addEventListener('abort', () => { req.aborted = true; });
    const response = (status, data, bodyDelay = 0) => {
      const text = typeof data === 'string' ? data : JSON.stringify(data);
      return {
        ok: status >= 200 && status < 300,
        status,
        headers: { get: () => null },
        json: async () => data,
        text: async () => text,
        body: { getReader: () => {
          let used = false;
          return {
            read: async () => {
              if (used) return { done: true };
              used = true;
              const result = { done: false, value: new TextEncoder().encode(text) };
              return bodyDelay ? this.later(bodyDelay, init.signal, () => result) : result;
            },
            cancel: async () => {},
            releaseLock() {},
          };
        } },
      };
    };
    if (parsed.pathname.endsWith('/healthz')) {
      return this.later(this.options.healthDelay ?? 1, init.signal, () => response(200, { ok: true, protocol: this.options.protocol ?? 3, upload_session: this.options.uploadSession ?? true, max_download_mib: 50, max_streams: 24 }));
    }
    if (parsed.pathname.endsWith('/getIP.php')) return Promise.resolve(response(200, '192.0.2.1 - LAN - REVIEW'));
    if (parsed.pathname.endsWith('/empty.php') && init.method === 'POST') {
      this.blobs.add(init.body);
      req.size = init.body.size;
      assert.equal(parsed.searchParams.get('ack'), '1', 'upload must request authoritative ACK');
      return this.later(this.options.uploadDelay ?? 700, init.signal, () => {
        req.settled = true;
        const bytes = this.options.ackBytes ?? req.size;
        if ((this.options.uploadStatus ?? 200) === 200 && bytes === req.size) this.acknowledgedBytes += bytes;
        return response(this.options.uploadStatus ?? 200, this.options.ackBody ?? { bytes }, this.options.ackBodyDelay ?? 0);
      }, !!this.options.ignoreUploadAbort);
    }
    if (parsed.pathname.endsWith('/garbage.php')) {
      let reads = 0;
      const reader = {
        read: () => this.later(this.options.chunkDelay ?? 250, init.signal, () => {
          reads++;
          if (reads > (this.options.chunksPerResponse ?? 1000)) {
            req.settled = true;
            return { done: true };
          }
          if (this.options.readFailure) throw new Error('injected network failure');
          const value = new Uint8Array(this.options.chunkBytes ?? 64000);
          this.deliveredBytes += value.byteLength;
          this.deliveries.push({ request: req, time: this.now, bytes: value.byteLength });
          return { done: false, value };
        }, !!this.options.ignoreReadAbort),
        cancel: async () => { req.cancelled = true; },
        releaseLock() {},
      };
      const result = response(this.options.downloadStatus ?? 200, null);
      result.headers = { get: (name) => name.toLowerCase() === 'content-length' ? String(this.options.contentLength ?? Number(parsed.searchParams.get('ckSize') || 50) * 1048576) : null };
      result.body = { getReader: () => reader };
      result.arrayBuffer = async () => { throw new Error('full response buffering forbidden'); };
      return Promise.resolve(result);
    }
    if (parsed.pathname.endsWith('/empty.php')) return this.later(5, init.signal, () => response(200, ''));
    throw new Error(`Unexpected URL: ${parsed}`);
  }

  latest() { return this.messages.at(-1)?.data; }
  terminal() { return this.messages.filter((m) => m.data.testState >= 4); }
}

module.exports = { ReviewRuntime };
