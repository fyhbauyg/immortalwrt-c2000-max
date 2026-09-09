const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const path = require('node:path');
const web = process.env.SPEEDTEST_WEB || (fs.existsSync(path.join(__dirname, '../src/web'))
  ? path.join(__dirname, '../src/web') : path.join(__dirname, '../src/speedtest-x-go/src/web'));
function harness() {
  const workers = [], timers = new Set(), timeouts = new Map(), requests = [], elements = new Map(), listeners = {};
  let timerId = 0;
  function element(id) {
    if (!elements.has(id)) elements.set(id, {
      textContent: '', style: {}, disabled: false, value: id === 'duration' ? '15' : '4',
      classList: { add() {}, remove() {}, toggle() {} },
      addEventListener(type, fn) { this[type] = fn; }
    });
    return elements.get(id);
  }
  const document = {
    hidden: false, body: element('body'), getElementById: element,
    addEventListener(type, fn) { listeners[type] = fn; }
  };
  class Worker {
    constructor(url) { this.url = url; this.messages = []; this.stopped = false; workers.push(this); }
    postMessage(data) { assert.ok(!this.stopped); this.messages.push(data); }
    terminate() { this.stopped = true; }
    send(data) { this.onmessage({ data: JSON.stringify(data) }); }
  }
  const ctx = vm.createContext({
    console: { log() {}, warn: console.warn, error: console.error },
    Worker, document, URLSearchParams, Date,
    setInterval() { const id = ++timerId; timers.add(id); return id; },
    clearInterval(id) { timers.delete(id); },
    setTimeout(fn) { const id = ++timerId; timers.add(id); timeouts.set(id, fn); return id; },
    clearTimeout(id) { timers.delete(id); timeouts.delete(id); },
    fetch(url, options) { requests.push({ url, options }); return Promise.resolve({ ok: true }); },
    window: { addEventListener(type, fn) { listeners[type] = fn; } }
  });
  // Browser window.status is a legacy DOMString property, not a free DOM slot.
  let browserStatus = 'browser-status';
  Object.defineProperty(ctx, 'status', {
    configurable: true,
    get() { return browserStatus; },
    set(value) { browserStatus = String(value); }
  });
  vm.runInContext(fs.readFileSync(path.join(web, 'speedtest.js'), 'utf8'), ctx);
  const html = fs.readFileSync(path.join(web, 'index.html'), 'utf8');
  vm.runInContext(html.match(/<script>\s*([\s\S]*?)<\/script>/)[1], ctx);
  return { ctx, workers, timers, timeouts, requests, element, document, listeners,
    expire() { for (const [id, fn] of [...timeouts]) { timeouts.delete(id); timers.delete(id); fn(); } } };
}
const success = { testState: 4, phase: 'done', error: '', dlStatus: '123', ulStatus: '45',
  pingStatus: '2', jitterStatus: '1', dlProgress: 1, ulProgress: 1, pingProgress: 1, clientIp: 'LAN' };
{
  const h = harness();
  h.element('startStop').click();
  assert.equal(h.workers.length, 1);
  const settings = JSON.parse(h.workers[0].messages[0].slice(6));
  assert.equal(settings.time_dl_max, 15);
  assert.equal(settings.xhr_ulMultistream, 4);
  h.workers[0].send(success);
  assert.equal(h.timers.size, 0);
  assert.ok(h.workers[0].stopped);
  assert.equal(h.requests.length, 1);
  h.workers[0].send(success);
  assert.equal(h.requests.length, 1, 'duplicate terminal cannot save twice');
  assert.equal(h.ctx.status, 'browser-status', 'statusNode must not overwrite window.status');
  h.element('duration').value = '30';
  h.element('streams').value = '1';
  h.element('startStop').click();
  assert.equal(JSON.parse(h.workers[1].messages[0].slice(6)).time_ul_max, 30);
  assert.equal(JSON.parse(h.workers[1].messages[0].slice(6)).xhr_dlMultistream, 1);
  h.element('startStop').click();
  assert.equal(h.workers[1].stopped, false, 'worker gets time to release its session');
  h.workers[1].send({ testState: 5, phase: 'cancelled', error: '' });
  assert.ok(h.workers[1].stopped);
  assert.equal(h.timers.size, 0);
  assert.equal(h.requests.length, 1);
  assert.equal(h.element('upload').textContent, '—');
}
for (const mode of ['error', 'worker-error', 'hidden', 'pagehide']) {
  const h = harness();
  h.element('startStop').click();
  if (mode === 'error') h.workers[0].send({ ...success, testState: 5, phase: 'error', error: 'HTTP 503' });
  if (mode === 'worker-error') h.workers[0].onerror({ preventDefault() {} });
  if (mode === 'hidden') { h.document.hidden = true; h.listeners.visibilitychange(); }
  if (mode === 'pagehide') h.listeners.pagehide();
  if (mode === 'hidden' || mode === 'pagehide') h.expire();
  assert.equal(h.requests.length, 0, `${mode} cannot save valid history`);
  assert.equal(h.timers.size, 0);
  assert.ok(h.workers[0].stopped);
  assert.equal(h.element('settings').disabled, false);
  assert.equal(h.element('download').textContent, '—');
}
for (const [name, payload] of [
  ['null', null],
  ['array', []],
  ['missing state', {}],
  ['string state', { ...success, testState: '4' }],
  ['negative state', { ...success, testState: -2 }],
  ['out-of-range state', { ...success, testState: 6 }],
  ['fractional state', { ...success, testState: 3.5 }],
  ['NaN rate', { ...success, dlStatus: 'NaN' }],
  ['Infinity rate', { ...success, ulStatus: 'Infinity' }],
  ['overflow rate', { ...success, ulStatus: '9'.repeat(400) }],
  ['missing download rate', { ...success, dlStatus: undefined }],
  ['missing upload rate', { ...success, ulStatus: undefined }],
  ['null rate', { ...success, ulStatus: null }],
  ['empty rate', { ...success, dlStatus: '' }],
  ['negative rate', { ...success, dlStatus: '-1' }]
]) {
  const h = harness();
  h.element('startStop').click();
  assert.doesNotThrow(() => h.workers[0].send(payload), `${name} must be handled`);
  assert.equal(h.requests.length, 0, `${name} cannot enter successful history`);
  assert.equal(h.timers.size, 0, `${name} must stop the poll timer`);
  assert.ok(h.workers[0].stopped, `${name} must terminate the worker`);
  assert.equal(h.element('settings').disabled, false);
  assert.equal(h.element('download').textContent, '—');
  assert.equal(h.element('upload').textContent, '—');
  h.element('startStop').click();
  h.workers[1].send(success);
  assert.equal(h.requests.length, 1, `${name} must not prevent a subsequent valid run`);
}
{
  const h = harness();
  h.element('startStop').click();
  assert.doesNotThrow(() => h.workers[0].onmessage({ data: '{invalid JSON' }));
  assert.equal(h.requests.length, 0);
  assert.equal(h.timers.size, 0);
  assert.ok(h.workers[0].stopped);
  assert.equal(h.element('settings').disabled, false);
}
{
  const h = harness();
  const instance = vm.runInContext('new Speedtest()', h.ctx);
  instance._state = 1;
  assert.throws(() => instance.start());
  assert.equal(h.workers.length, 0, 'invalid server state must not create a worker');
}
console.log('PASS UI: fixed settings, success, repeated start, abort, hidden page, worker error, cleanup, window.status, malformed/null/state validation, finite complete rates, no invalid history');
