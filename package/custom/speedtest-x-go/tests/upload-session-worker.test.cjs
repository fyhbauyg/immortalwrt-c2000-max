'use strict';

// Production worker against independently clocked receiver counters, no network.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { UploadSessionRuntime } = require('./upload-session-runtime.cjs');
const supplied = process.env.SPEEDTEST_SOURCE;
const workerSource = supplied ? (fs.statSync(supplied).isDirectory() ? path.join(supplied, 'speedtest_worker.js') : supplied) : path.join(__dirname, '../src/web/speedtest_worker.js');
const { createWorker } = require(workerSource);
const MiB = 1024 * 1024;
function setup(options = {}, extra = {}) {
  const runtime = new UploadSessionRuntime(options);
  const worker = createWorker(runtime.env);
  const start = (direction = 'U', more = {}) => worker.handleMessage('start ' + JSON.stringify({
    test_order: direction, time_dl_max: 1, time_ul_max: 1,
    time_dlGraceTime: 0, time_ulGraceTime: 0, xhr_dlMultistream: 4, xhr_ulMultistream: 4,
    xhr_ul_blob_megabytes: 1, request_timeout_ms: 3000, ...extra, ...more,
  }));
  return { runtime, worker, start, result: () => worker.snapshot() };
}
async function clean(t) {
  await t.runtime.flush();
  assert.deepEqual(t.worker.diagnostics(), { requests: 0, timers: 0 });
  assert.equal(t.runtime.sessions.size, 0, 'server session released');
  assert.equal(t.runtime.activePosts, 0);
}
function valid(t) {
  const value = t.result();
  assert.equal(value.testState, 4, value.error);
  const session = t.runtime.allSessions.at(-1);
  const m = value.measurements.upload;
  assert.equal(m.accounting, 'server-received-fixed-window');
  assert.equal(m.elapsedSeconds, session.duration / 1000);
  assert.equal(m.bytes, session.bytes);
  assert.equal(Number(value.ulStatus), Number((m.bytes * 8 / m.elapsedSeconds / 1e6).toFixed(2)));
  return value;
}
const cases = [];
const test = (name, run) => cases.push({ name, run });

for (const options of [{ protocol: 2 }, { uploadSession: false }]) {
  test('incompatible health ' + JSON.stringify(options) + ' refuses upload before session creation', async () => {
    const t = setup(options); t.start();
    await t.runtime.until(2000);
    assert.equal(t.result().testState, 5);
    assert.match(t.result().error, /protocol 3/);
    assert.equal(t.runtime.allSessions.length, 0);
    assert.equal(t.runtime.requests.filter(r => r.size).length, 0);
    await clean(t);
  });
}

test('server fixed window counts partial POSTs instead of full-ACK-only bytes', async () => {
  const t = setup(); t.start();
  await t.runtime.until(2500);
  const value = valid(t);
  assert.notEqual(value.measurements.upload.bytes, t.runtime.acknowledgedBytes);
  assert.ok(t.runtime.requests.some(r => {
    const counted = t.runtime.sessionReceives.filter(d => d.request === r && d.counted).reduce((n, d) => n + d.bytes, 0);
    return counted > 0 && counted < r.size;
  }), 'only the in-window part of a crossing POST is counted');
  assert.ok(t.runtime.requests.some(r => r.size && r.received < r.size && r.aborted));
  assert.equal(t.runtime.blobs.size, 1);
  assert.equal([...t.runtime.blobs][0].size, MiB);
  assert.equal(t.runtime.deleted.length, 1);
  await clean(t);
});

test('warmup is one continuous transfer and excludes only receiver reads before measurement', async () => {
  const t = setup({}, { time_ulGraceTime: 1, xhr_ul_blob_megabytes: 4 }); t.start();
  await t.runtime.until(3500);
  const value = valid(t);
  const session = t.runtime.allSessions[0];
  const counted = t.runtime.sessionReceives.filter(r => r.time >= session.start + 1000 && r.time < session.start + 2000);
  assert.equal(value.measurements.upload.bytes, counted.reduce((n, r) => n + r.bytes, 0));
  const spanning = t.runtime.requests.filter(r => r.size && r.time < session.start + 1000 &&
    t.runtime.sessionReceives.some(d => d.request === r && d.time >= session.start + 1000));
  assert.equal(spanning.length, 4, 'all initial POSTs cross warmup boundary without drain/restart');
  assert.equal(t.runtime.allSessions.length, 1);
  await clean(t);
});

test('late ACK and response body cannot stretch the upload denominator', async () => {
  const t = setup({ uploadAckDelay: 2500, ackBodyDelay: 1000 }); t.start();
  await t.runtime.until(2500);
  const value = valid(t);
  assert.equal(value.measurements.upload.elapsedSeconds, 1);
  assert.equal(t.runtime.acknowledgedBytes, 0);
  assert.equal(value.measurements.upload.bytes, 4 * MiB);
  await clean(t);
});

test('large unfinished requests are counted without ever receiving an ACK', async () => {
  const t = setup({}, { xhr_ul_blob_megabytes: 16 }); t.start();
  await t.runtime.until(2500);
  const value = valid(t);
  assert.ok(value.measurements.upload.bytes > 0);
  assert.equal(t.runtime.acknowledgedBytes, 0);
  assert.equal(t.runtime.requests.filter(r => r.size).length, 4);
  await clean(t);
});

test('six requested upload streams reserve one browser connection for controls', async () => {
  const t = setup({}, { xhr_ulMultistream: 6 }); t.start();
  await t.runtime.until(2500);
  const value = valid(t);
  assert.equal(value.measurements.upload.requestedStreams, 6);
  assert.equal(value.measurements.upload.streams, 5);
  assert.equal(t.runtime.peakPosts, 5);
  assert.ok(t.runtime.polls >= 2);
  await clean(t);
});

for (const [name, options, pattern] of [
  ['HTTP 413', { uploadStatus: 413 }, /HTTP 413/],
  ['HTTP 503', { uploadStatus: 503 }, /HTTP 503/],
  ['network failure', { uploadError: true }, /network failure/],
  ['invalid ACK JSON', { ackBody: 'not JSON' }, /acknowledgement JSON/],
  ['short ACK bytes', { ackBytes: MiB - 1 }, /byte count mismatch/],
  ['negative ACK bytes', { ackBytes: -1 }, /byte count mismatch/],
  ['string ACK bytes', { ackBody: { bytes: String(MiB) } }, /byte count mismatch/],
  ['missing ACK bytes', { ackBody: {} }, /byte count mismatch/],
  ['control HTTP 503', { pollStatus: 503 }, /HTTP 503/],
  ['invalid counter JSON', { mutatePoll: () => 'not JSON' }, /counter JSON/],
  ['wrong session ID', { mutatePoll: v => ({ ...v, id: 'f'.repeat(32) }) }, /inconsistent/],
  ['negative counter bytes', { mutatePoll: v => ({ ...v, bytes: -1 }) }, /inconsistent/],
  ['fractional counter bytes', { mutatePoll: v => ({ ...v, bytes: 1.5 }) }, /inconsistent/],
  ['string counter bytes', { mutatePoll: v => ({ ...v, bytes: String(v.bytes) }) }, /inconsistent/],
  ['changed duration', { mutatePoll: v => ({ ...v, duration_ms: 999 }) }, /inconsistent/],
  ['elapsed above duration', { mutatePoll: v => ({ ...v, elapsed_ms: 1001 }) }, /inconsistent/],
  ['done before full elapsed', { mutatePoll: v => ({ ...v, state: 'done', remaining_ms: 0 }) }, /inconsistent/],
  ['waiting with byte count', { mutatePoll: v => ({ ...v, state: 'waiting' }) }, /inconsistent/],
]) {
  test(name + ' fails explicitly and releases session', async () => {
    const t = setup(options); t.start();
    await t.runtime.until(6000);
    assert.equal(t.result().testState, 5, t.result().error);
    assert.match(t.result().error, pattern);
    assert.ok(!t.runtime.messages.some(m => m.data.testState === 4));
    assert.ok(!t.result().measurements.upload);
    await clean(t);
  });
}

test('decreasing counters cannot overwrite a newer receiver sample', async () => {
  const t = setup({ mutatePoll: (v, n) => n === 2 ? { ...v, bytes: 0 } : v }); t.start();
  await t.runtime.until(6000);
  assert.equal(t.result().testState, 5);
  assert.match(t.result().error, /inconsistent/);
  await clean(t);
});

for (const [name, mutation] of [
  ['measuring creation state', v => ({ ...v, state: 'measuring', bytes: 1 })],
  ['already-done creation state', v => ({ ...v, state: 'done', bytes: 1, elapsed_ms: 1000, remaining_ms: 0 })],
]) {
  test(name + ' is rejected before bulk requests are dispatched', async () => {
    const t = setup({ mutateCreate: mutation }); t.start();
    await t.runtime.until(6000);
    assert.equal(t.result().testState, 5);
    assert.match(t.result().error, /inconsistent/);
    assert.equal(t.runtime.requests.filter(r => r.size).length, 0);
    assert.ok(!t.result().measurements.upload);
  });
}

for (const [name, mutation] of [
  ['zero remaining while measuring', v => ({ ...v, remaining_ms: 0 })],
  ['fractional remaining', v => ({ ...v, remaining_ms: v.remaining_ms + 0.5 })],
  ['remaining inconsistent with elapsed', v => ({ ...v, remaining_ms: 999 })],
  ['premature done before the requested interval', v => ({ ...v, state: 'done', elapsed_ms: 1000, remaining_ms: 0 })],
]) {
  test(name + ' cannot become a plausible successful result', async () => {
    const t = setup({ mutatePoll: (v, n) => n === 1 ? mutation(v) : v }); t.start();
    await t.runtime.until(6000);
    assert.equal(t.result().testState, 5);
    assert.match(t.result().error, /inconsistent/);
    assert.ok(!t.result().measurements.upload);
    await clean(t);
  });
}

test('perpetually waiting server has a hard overall timeout', async () => {
  const t = setup({ mutatePoll: v => ({ ...v, state: 'waiting', bytes: 0, elapsed_ms: 0, remaining_ms: 1000 }) }); t.start();
  await t.runtime.until(6500);
  assert.equal(t.result().testState, 5, t.result().error);
  assert.match(t.result().error, /timed out/);
  assert.ok(!t.result().measurements.upload);
  await clean(t);
});

test('all-zero final measured counter is not successful zero Mbps', async () => {
  const t = setup({ mutatePoll: v => ({ ...v, bytes: 0 }) }); t.start();
  await t.runtime.until(4000);
  assert.equal(t.result().testState, 5);
  assert.match(t.result().error, /No measured upload data/);
  await clean(t);
});

test('delayed session DELETE response cannot hang completion or alter the measured window', async () => {
  const t = setup({ deleteDelay: 5000, ignoreDeleteAbort: true }); t.start();
  await t.runtime.until(3500);
  valid(t);
  const final = JSON.stringify(t.result());
  assert.equal(t.runtime.deleted.length, 1);
  await t.runtime.until(10000);
  assert.equal(JSON.stringify(t.result()), final);
  await clean(t);
});

test('abort and immediate restart isolate sessions, late ACKs and control replies', async () => {
  const t = setup({ ignoreUploadAbort: true, ignorePollAbort: true, pollDelay: 600, uploadAckDelay: 1700 });
  t.start(); await t.runtime.until(750);
  const first = t.runtime.allSessions[0].id;
  t.worker.handleMessage('abort');
  assert.equal(t.result().phase, 'cancelled');
  t.runtime.options.ignoreUploadAbort = false;
  t.runtime.options.ignorePollAbort = false;
  t.runtime.options.pollDelay = 1;
  t.runtime.options.uploadAckDelay = 1;
  t.start(); await t.runtime.until(5500);
  const value = valid(t);
  const second = t.runtime.allSessions[1];
  assert.notEqual(first, second.id);
  assert.equal(value.measurements.upload.bytes, second.bytes);
  assert.deepEqual([...t.runtime.deleted].sort(), [first, second.id].sort());
  const final = JSON.stringify(value);
  await t.runtime.until(10000);
  assert.equal(JSON.stringify(t.result()), final);
  await clean(t);
});

test('download warning survives the succeeding upload phase', async () => {
  const t = setup();
  const fetch = t.runtime.env.fetch;
  let downloads = 0;
  t.runtime.env.fetch = (url, init) => {
    if (String(url).includes('/garbage.php') && ++downloads === 1)
      return t.runtime.later(20000, init.signal, () => { throw new Error('not reached'); });
    return fetch(url, init);
  };
  t.start('DU', { time_dl_max: 6 });
  await t.runtime.until(10000);
  const value = valid(t);
  assert.equal(value.measurements.download.interruptions, 1);
  assert.ok(value.warning);
  await clean(t);
});

(async () => {
  const results = [];
  for (const entry of cases) {
    try { await entry.run(); results.push({ name: entry.name, pass: true }); }
    catch (error) { results.push({ name: entry.name, pass: false, error: error.stack }); }
  }
  console.log(JSON.stringify({ passed: results.filter(r => r.pass).length, total: results.length, results }, null, 2));
  process.exitCode = results.every(r => r.pass) ? 0 : 1;
})();
