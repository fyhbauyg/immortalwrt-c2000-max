const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

String.prototype.format = function(...args) {
  let pos = 0;
  return this.replace(/%\.([0-9]+)f|%[sf]|%%/g, (token, precision) => {
    if (token === '%%') return '%';
    const value = args[pos++];
    return precision == null ? String(value) : Number(value).toFixed(Number(precision));
  });
};

const maps = [], polls = [];
class Option {
  constructor(name) { this.option = name; }
  value() {}
  depends() {}
  formvalue() { return this.valueForTest; }
  parse() { return Promise.resolve('base-parse'); }
}
class Map {
  constructor() { this.options = {}; maps.push(this); }
  section() { return { option: (_type, name) => this.options[name] = new Option(name) }; }
  render() { return Promise.resolve({ type: 'form' }); }
}
const form = { Map, NamedSection: {}, Flag: Option, ListValue: Option, Value: Option, DynamicList: Option };
const E = (tag, attrs, children) => Array.isArray(tag) ? tag : ({ tag, attrs, children });
const ui = new Function('rpc', 'view', 'form', 'poll', 'dom', 'E', '_',
  fs.readFileSync(path.join(__dirname, '../files/www/luci-static/resources/view/c2000max/nrqos.js'), 'utf8'))(
  { declare: () => () => Promise.resolve({ enabled: false, active: false }) },
  { extend: value => value }, form, { add: (cb, delay) => polls.push({ cb, delay }) },
  { content: (node, value) => node.children = value }, E, value => value);

(async () => {
  const rendered = await ui.render({ enabled: true, active: true, upload_kbit: 130000, autorate: true, probes: '2:hold', delay_ms: 3, load_percent: 75 });
  const options = maps[0].options;
  const text = JSON.stringify(rendered);
  assert.match(text, /130000 kbit\/s（130\.0 Mbit\/s）/);
  assert.match(text, /上行 CAKE 队列运行中/);
  assert.match(text, /2 个健康目标 · 保持/);
  assert.equal(polls[0].delay, 3);
  assert.equal(options.enabled.default, '0');
  assert.equal(options.autorate.default, '0');
  options.enabled.valueForTest = '1';
  options.autorate.valueForTest = '0';
  for (const value of ['128', '130000', '1000000']) assert.equal(options.upload_kbit.validate('main', value), true);
  for (const value of ['0', '-1', '127', '1.5', '1000001']) assert.notEqual(options.upload_kbit.validate('main', value), true);
  options.autorate.valueForTest = '1';
  options.upload_kbit.valueForTest = '130000';
  options.min_upload_kbit.valueForTest = '50000';
  options.max_upload_kbit.valueForTest = '140000';
  assert.equal(options.upload_kbit.validate('main', '130000'), true);
  assert.equal(options.min_upload_kbit.validate('main', '50000'), true);
  options.max_upload_kbit.valueForTest = '120000';
  assert.notEqual(options.upload_kbit.validate('main', '130000'), true);
  options.max_upload_kbit.valueForTest = '140000';
  options.ping_hosts.valueForTest = ['223.5.5.5', '119.29.29.29'];
  assert.equal(await options.ping_hosts.parse('main'), 'base-parse');
  for (const addresses of [[], ['223.5.5.5'], ['1.1.1.1', '1.1.1.1'], ['127.0.0.1', '119.29.29.29'], ['224.1.1.1', '119.29.29.29'], ['1.1.1.1', '8.8.8.8', '9.9.9.9', '4.2.2.1']]) {
    options.ping_hosts.valueForTest = addresses;
    await assert.rejects(() => options.ping_hosts.parse('main'));
  }
  for (const address of ['223.5.5.5', '119.29.29.29', '10.0.0.1']) assert.equal(options.ping_hosts.validate('main', address), true);
  for (const address of ['::1', 'localhost', '0.0.0.0', '127.0.0.1', '255.255.255.255', '1.2.3.999', '01.2.3.4']) assert.notEqual(options.ping_hosts.validate('main', address), true);
  options.autorate.valueForTest = '0';
  options.ping_hosts.valueForTest = [];
  assert.equal(await options.ping_hosts.parse('main'), 'base-parse');
  for (const name of ['upload_kbit', 'autorate', 'min_upload_kbit', 'max_upload_kbit', 'interval', 'delay_target_ms', 'ping_hosts']) assert.equal(options[name].retain, true);
  const acl = JSON.parse(fs.readFileSync(path.join(__dirname, '../files/usr/share/rpcd/acl.d/c2000max-nrqos.json')));
  assert.deepEqual(acl['c2000max-nrqos'].write, { uci: ['c2000max_nrqos'] });
  assert.deepEqual(acl['c2000max-nrqos'].read.ubus, { 'c2000max-nrqos': ['status'] });
  JSON.parse(fs.readFileSync(path.join(__dirname, '../files/usr/share/luci/menu.d/c2000max-nrqos.json')));
  console.log('NR QoS UI tests passed: defaults, bounds, cross-field limits, probe lists, retained settings, scoped ACL.');
})().catch(error => { console.error(error); process.exitCode = 1; });
