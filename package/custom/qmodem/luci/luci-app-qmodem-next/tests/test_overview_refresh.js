const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const source = fs.readFileSync(path.join(__dirname, '../htdocs/luci-static/resources/view/qmodem/overview.js'), 'utf8');

class Node {
  constructor(tag, attrs, content) {
    this.tag = tag; this.attrs = attrs || {}; this.style = {}; this.children = [];
    this.events = {}; this.classList = {add() {}, remove() {}};
    this.textContent = typeof content === 'string' ? content : '';
    for (const child of Array.isArray(content) ? content : []) this.appendChild(child);
  }
  appendChild(child) {
    this.children.push(child); child.parentNode = this;
    if (this.tag === 'select' && this.value == null) this.value = child.attrs.value;
  }
  removeChild(child) { this.children.splice(this.children.indexOf(child), 1); child.parentNode = null; }
  addEventListener(name, callback) { this.events[name] = callback; }
  querySelector(selector) { return this.find(node => selector === '.spinning' && (node.attrs.class || '').includes('spinning')); }
  find(predicate) {
    if (predicate(this)) return this;
    for (const child of this.children) { const found = child.find(predicate); if (found) return found; }
  }
}
const E = (tag, attrs, children) => new Node(tag, attrs, children);
const frames = [], calls = [], poll = {add(callback) { this.callback = callback; }};
const api = {};
for (const name of ['BaseInfo', 'NetworkInfo', 'CellInfo', 'SimInfo', 'Copyright']) {
  api['get' + name] = modem => new Promise((resolve, reject) => calls.push({name, modem, resolve, reject, done: false}));
}
const page = new Function('view', 'poll', 'ui', 'dom', 'uci', 'qmodem', 'document', 'E', 'L', '_', 'console', source)(
  {extend: object => object}, poll, {},
  {content(node, content) { node.children = []; node.appendChild(content); }}, {}, api,
  {head: E('head'), styleSheets: []}, E, {resource: name => name}, text => text, {error() {}});
page.getModemList = () => [{id: 'a', name: 'FM150'}, {id: 'b', name: 'SRM825'}];
const renderTables = page.renderModemInfo;
page.attachSectionHandlers = () => {};
page.getSectionOrder = () => [];
page.getCollapsedState = () => false;
page.renderModemInfo = (modem, tables, container, time, groups) => {
  frames.push({modem, groups: groups.filter(Boolean).map(g => g.modem_info[0]?.value)});
  const fieldset = E('fieldset'); container.appendChild(fieldset); tables.Basic = {fieldset};
};
const content = page.render();
const select = content.find(node => node.tag === 'select');
const flush = () => new Promise(resolve => setImmediate(resolve));
const info = value => ({modem_info: [{class: 'Basic', key: 'name', value, type: 'plain_text'}]});
function finish(call, value, error) { call.done = true; error ? call.reject(error) : call.resolve(value); }
function active() { return calls.filter(call => !call.done); }

(async () => {
  await flush();
  assert.equal(calls.length, 1); assert.equal(calls[0].name, 'BaseInfo');
  const pending = poll.callback();
  for (let i = 0; i < 5; i++) assert.equal(poll.callback(), pending);
  await flush(); assert.equal(calls.length, 1, 'slow poll starts no additional RPC');
  finish(calls[0], info('FM150')); await flush();
  assert.deepEqual(frames[0], {modem: 'a', groups: ['FM150']});
  assert.equal(active()[0].name, 'NetworkInfo');
  // One failed group must not suppress basic data or prevent remaining groups.
  finish(active()[0], null, new Error('timeout')); await flush();
  assert.equal(active()[0].name, 'CellInfo');
  finish(active()[0], info('-85 dBm')); await flush();
  assert.equal(active()[0].name, 'SimInfo');
  assert.deepEqual(frames.at(-1).groups, ['FM150', '-85 dBm']);
  const previousFrames = frames.length;
  select.value = 'b'; select.events.change(); await flush();
  assert.equal(active().length, 1, 'modem switch waits for outstanding RPC');
  finish(active()[0], info('OLD SIM')); await flush();
  assert.equal(frames.length, previousFrames, 'old response cannot populate new modem');
  assert.equal(active()[0].modem, 'b');
  for (const name of ['BaseInfo', 'NetworkInfo', 'CellInfo', 'SimInfo', 'Copyright']) {
    assert.equal(active().length, 1); assert.equal(active()[0].name, name);
    finish(active()[0], name === 'Copyright' ? {copyright: {Vendor: 'MEIG'}} : info('b ' + name));
    await flush();
  }
  await pending;
  assert.equal(active().length, 0);
  assert.deepEqual(frames.at(-1).groups, ['b BaseInfo', 'b NetworkInfo', 'b CellInfo', 'b SimInfo']);
  // A background cache refresh in another reader retains the last group here.
  const next = poll.callback(); await flush();
  for (const name of ['BaseInfo', 'NetworkInfo', 'CellInfo', 'SimInfo']) {
    assert.equal(active()[0].name, name);
    finish(active()[0], {modem_info: [], cache_pending: true}); await flush();
  }
  await next;
  assert.equal(active().length, 0);
  assert.equal(calls.filter(c => c.name === 'Copyright' && c.modem === 'b').length, 1);
  assert.deepEqual(frames.at(-1).groups, ['b BaseInfo', 'b NetworkInfo', 'b CellInfo', 'b SimInfo']);

  const cold = page.render(); await flush();
  const coldRefresh = poll.callback();
  for (let i = 0; i < 4; i++) {
    assert.equal(active().length, 1);
    finish(active()[0], {modem_info: [], cache_pending: true}); await flush();
  }
  finish(active()[0], {copyright: {}}); await coldRefresh;
  const coldContainer = cold.find(node => node.attrs.id === 'modem_info_container');
  assert.equal(coldContainer.children[0].textContent, 'Waiting for the modem to become ready...');
  const retry = poll.callback(); await flush();
  for (let i = 0; i < 4; i++) {
    assert.equal(active().length, 1); finish(active()[0], info('ready')); await flush();
  }
  await retry;

  // Exercise the real table renderer with partial groups as well.
  const tables = {}, tableContainer = E('div');
  const clock = E('div'); tableContainer.appendChild(E('div', {class: 'spinning'}));
  renderTables.call(page, 'a', tables, tableContainer, clock, [info('FM150')]);
  assert.equal(tableContainer.querySelector('.spinning'), undefined);
  assert.equal(tables.Basic.rows[0].right.textContent, 'FM150');
  renderTables.call(page, 'a', tables, tableContainer, clock, [info('FM150'), info('connected')]);
  assert.equal(tables.Basic.rows.length, 2);
  assert.equal(tables.Basic.rows[1].right.textContent, 'connected');
  assert.equal(tableContainer.children.length, 1, 'partial groups reuse their table');
  console.log('PASS: slow RPC polling, partial data, failed group, modem switch and pending cache');
})().catch(error => { console.error(error); process.exitCode = 1; });
