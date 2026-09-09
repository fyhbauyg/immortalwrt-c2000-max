'use strict';

// Black-box accuracy/race review: actual worker, synthetic transport, no network.
const assert = require('node:assert/strict');
const path = require('node:path');
const fs = require('node:fs');
const vm = require('node:vm');
const { UploadSessionRuntime } = require('./upload-session-runtime.cjs');
const workerPath = path.resolve(process.argv[2] || (process.env.SPEEDTEST_WEB && path.join(process.env.SPEEDTEST_WEB, 'speedtest_worker.js')) || path.join(__dirname, '../src/web/speedtest_worker.js'));
const sandbox = { module: { exports: {} }, Date: class extends Date { static now() { return -123456789; } } };
vm.runInNewContext(fs.readFileSync(workerPath, 'utf8'), sandbox, { filename: workerPath });
const { createWorker } = sandbox.module.exports;
assert.equal(typeof createWorker, 'function', 'worker must expose the production factory for isolation tests');

const settings = (direction, extra = {}) => ({
  test_order: direction,
  time_dl_max: 10,
  time_ul_max: 10,
  time_dlGraceTime: 0,
  time_ulGraceTime: 0,
  xhr_dlMultistream: 4,
  xhr_ulMultistream: 4,
  xhr_ul_blob_megabytes: 1,
  upload_drain_ms: 5000,
  request_timeout_ms: 20000,
  ...extra,
});
const cases = [];
const instances = [];
const test = (name, run) => cases.push({ name, run });
const setup = (options = {}) => {
  const runtime = new UploadSessionRuntime(options);
  const worker = createWorker(runtime.env);
  instances.push({ runtime, worker });
  const send = (message) => worker.handleMessage(message);
  // Cancellation intentionally defers terminal postMessage until cleanup;
  // inspect the factory snapshot here while separately asserting late emissions.
  const status = () => { send('status'); return worker.snapshot(); };
  const start = (direction, extra) => send('start ' + JSON.stringify(settings(direction, extra)));
  return { runtime, worker, send, status, start };
};
const near = (actual, expected, epsilon, message) => assert.ok(Math.abs(actual - expected) <= epsilon, `${message}: ${actual} != ${expected}`);

test('download reads real bytes, retains no full response, uses monotonic time', async () => {
  const t = setup();
  t.start('D');
  await t.runtime.until(12000);
  const final = t.status();
  assert.equal(final.testState, 4, final.error);
  const measured = final.measurements.download;
  assert.ok(measured.bytes > 0);
  assert.ok(measured.bytes <= t.runtime.deliveredBytes, 'cannot credit bytes not delivered by reader');
  near(measured.elapsedSeconds, 10, 0.02, 'fixed 10s direction');
  near(Number(final.dlStatus), measured.bytes * 8 / measured.elapsedSeconds / 1e6, 0.011, 'payload bits, no synthetic overhead boost');
  assert.equal(t.runtime.requests.filter((r) => r.url.pathname.endsWith('/garbage.php')).length, 4);
  assert.ok(t.runtime.requests.filter((r) => r.url.pathname.endsWith('/garbage.php')).every((r) => r.aborted || r.cancelled || r.settled));
});

test('high chunk frequency does not create one worker watchdog/timer per chunk', async () => {
  const t = setup({ chunkDelay: 1, chunkBytes: 64, chunksPerResponse: 100000 });
  t.start('D');
  await t.runtime.until(11000);
  assert.equal(t.status().testState, 4, t.status().error);
  assert.ok(t.runtime.deliveries.length > 30000, 'exercise a high-frequency stream');
  assert.ok(t.runtime.workerTimerSchedules < 100, `per-stream watchdog must remain bounded: ${t.runtime.workerTimerSchedules}`);
});

test('upload uses fixed receiver bytes/time and retains one bounded Blob', async () => {
  const t = setup();
  t.start('U');
  await t.runtime.until(13000);
  const final = t.status();
  assert.equal(final.testState, 4, final.error);
  const measured = final.measurements.upload;
  const uploads = t.runtime.requests.filter((r) => r.size);
  const session = t.runtime.allSessions[0];
  assert.equal(measured.bytes, session.bytes, 'server reads, not final ACK delivery, define numerator');
  near(measured.elapsedSeconds, 10, 0.0001, 'fixed receiver measurement window');
  near(Number(final.ulStatus), measured.bytes * 8 / measured.elapsedSeconds / 1e6, 0.011, 'receiver-window throughput');
  assert.equal(t.runtime.blobs.size, 1, 'reuse one immutable upload Blob');
  assert.ok(uploads.every((r) => r.size === 1048576), 'bounded 1 MiB payload');
  assert.ok(t.runtime.sessionReceives.filter(d => d.counted).every(d => d.time < session.start + 10000), 'no post-deadline bytes credited');
  assert.ok(uploads.every(r => r.aborted || r.settled), 'all data streams released after final counter');
});

test('late ACK response body does not extend fixed receiver elapsed', async () => {
  const t = setup({ uploadAckDelay: 700, ackBodyDelay: 1000 });
  t.start('U');
  await t.runtime.until(10000);
  assert.equal(t.status().testState, 3);
  await t.runtime.until(13000);
  const final = t.status();
  assert.equal(final.testState, 4, final.error);
  near(final.measurements.upload.elapsedSeconds, 10, 0.0001, 'counter window excludes response delivery');
  assert.equal(final.measurements.upload.bytes, t.runtime.allSessions[0].bytes);
});

for (const [name, options] of [
  ['mismatched count', { ackBytes: 1048575 }],
  ['numeric string count', { ackBody: { bytes: '1048576' } }],
  ['missing count', { ackBody: { ok: true } }],
  ['HTTP rejection', { uploadStatus: 413 }],
]) {
  test(`upload ${name} cannot yield a successful result`, async () => {
    const t = setup(options);
    t.start('U');
    await t.runtime.until(20000);
    const final = t.status();
    assert.equal(final.testState, 5);
    assert.ok(final.error);
    assert.match(final.error, /acknowledgement|HTTP 413/);
    assert.ok(!t.runtime.messages.some((m) => m.data.testState === 4));
  });
}

test('counter response timeout invalidates result even when a reply arrives later', async () => {
  const t = setup({ pollDelay: 40000, ignorePollAbort: true });
  t.start('U');
  await t.runtime.until(22000);
  const failed = t.status();
  assert.equal(failed.testState, 5);
  assert.match(failed.error, /timed out/);
  await t.runtime.until(30000);
  assert.equal(t.status().testState, 5);
  assert.ok(!t.runtime.messages.some((m) => m.data.testState === 4));
});

test('download body read failure invalidates partial samples', async () => {
  const t = setup({ readFailure: true });
  t.start('D');
  await t.runtime.until(12000);
  const final = t.status();
  assert.equal(final.testState, 5);
  assert.match(final.error, /injected network failure/);
});

test('premature EOF cannot recycle a truncated download as successful data', async () => {
  const t = setup({ chunksPerResponse: 1 });
  t.start('D');
  await t.runtime.until(12000);
  const final = t.status();
  assert.equal(final.testState, 5);
  assert.match(final.error, /[Tt]runcat|[Ll]ength|[Ss]ize/);
});

test('download stalls are invalid, not successful zero throughput', async () => {
  const t = setup({ chunkDelay: 6500 });
  t.start('D');
  await t.runtime.until(12000);
  const final = t.status();
  assert.equal(final.testState, 5);
  assert.match(final.error, /[Tt]imed out|[Ss]tall/);
});

test('cancelled download late chunks cannot contaminate a restarted worker', async () => {
  const t = setup({ ignoreReadAbort: true });
  t.start('D');
  await t.runtime.until(500);
  t.send('abort');
  assert.equal(t.status().testState, 5);
  const restartedAt = t.runtime.now;
  t.start('D');
  await t.runtime.until(12000);
  const final = t.status();
  assert.equal(final.testState, 4, final.error);
  const newRequests = t.runtime.requests.filter((r) => r.url.pathname.endsWith('/garbage.php') && r.time >= restartedAt);
  assert.equal(newRequests.length, 4);
  const measuredStart = newRequests[0].time;
  const credited = t.runtime.deliveries.filter((d) => newRequests.includes(d.request) && d.time < measuredStart + 10000).reduce((n, d) => n + d.bytes, 0);
  assert.equal(final.measurements.download.bytes, credited, 'no aborted-generation or post-deadline chunks credited');
});

test('protocol 1 health refuses to start bulk traffic', async () => {
  const t = setup({ protocol: 1 });
  t.start('DU');
  await t.runtime.until(30000);
  assert.equal(t.status().testState, 5);
  assert.match(t.status().error, /protocol 3/);
  assert.equal(t.runtime.requests.filter((r) => /garbage|empty/.test(r.url.pathname)).length, 0);
});

test('cancelled upload cannot turn into success on late ACK and worker is reusable', async () => {
  const t = setup({ uploadAckDelay: 1700, ignoreUploadAbort: true });
  t.start('U');
  await t.runtime.until(500);
  t.send('abort');
  assert.equal(t.status().testState, 5);
  assert.ok(!t.status().error, 'user cancellation is not transport failure');
  const boundary = t.runtime.messages.length;
  t.runtime.options.uploadAckDelay = 1;
  t.runtime.options.ignoreUploadAbort = false;
  t.start('U');
  await t.runtime.until(15000);
  const final = t.status();
  assert.equal(final.testState, 4, final.error);
  const measured = final.measurements.upload;
  // Old run data/ACKs remain tied to their retired server session.
  assert.equal(measured.bytes, t.runtime.allSessions[1].bytes);
  assert.equal(t.runtime.sessions.size, 0);
  assert.ok(t.runtime.messages.slice(boundary).filter((m) => m.data.testState === 4).every((m) => m.time >= 10500));
});

test('independent warmup is excluded from measured payload and duration', async () => {
  const t = setup();
  t.start('U', { time_ulGraceTime: 1 });
  await t.runtime.until(16000);
  const final = t.status();
  assert.equal(final.testState, 4, final.error);
  const measured = final.measurements.upload;
  assert.ok(measured.bytes < t.runtime.sessionReceives.reduce((n, d) => n + d.bytes, 0), 'warmup and tail receiver reads are excluded');
  near(measured.elapsedSeconds, 10, 0.0001, 'warmup does not shorten the fixed measurement');
});

(async () => {
  const results = [];
  for (const item of cases) {
    try {
      instances.length = 0;
      await item.run();
      for (const { runtime, worker } of instances) {
        await runtime.flush();
        const diagnostics = worker.diagnostics();
        assert.equal(diagnostics.requests, 0, 'no retained worker requests after terminal state');
        assert.equal(diagnostics.timers, 0, 'no retained worker timers after terminal state');
      }
      results.push({ name: item.name, ok: true });
    } catch (error) {
      results.push({ name: item.name, ok: false, error: error.stack });
    }
  }
  console.log(JSON.stringify({ source: workerPath, passed: results.filter((r) => r.ok).length, total: results.length, results }, null, 2));
  process.exitCode = results.every((r) => r.ok) ? 0 : 1;
})();
