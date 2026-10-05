'use strict';
const fs = require('node:fs');
const path = require('node:path');
const assert = require('node:assert/strict');
const root = process.argv[2] || path.join(__dirname, '..');
const luci = path.join(root, '..', 'luci-app-c2000max-app');
const source = fs.readFileSync(process.argv[3] || path.join(luci, 'htdocs/luci-static/resources/view/c2000max/app.js'), 'utf8');
const ids = new Map();
const calls = [];
const notifications = [];
let statusReply, setReply = { success: false };
function E(tag, attrs = {}, content = []) {
 const children = Array.isArray(content) ? content.slice() : [content];
 const node = { tag, attrs, children, value: attrs.value || '', checked: false,
  get firstChild() { return this.children[0]; },
  removeChild(child) { this.children.splice(this.children.indexOf(child), 1); },
  appendChild(child) { this.children.push(child); }
 };
 if (attrs.id) { assert(!ids.has(attrs.id), 'duplicate form ID ' + attrs.id); ids.set(attrs.id, node); }
 return node;
}
let setParams;
const rpc = { declare(def) {
 if (def.method === 'set') setParams = def.params;
 return async (...args) => { calls.push({ method: def.method, args }); return def.method === 'status' ? statusReply : setReply; };
}};
const ui = { addNotification: (...args) => notifications.push(args), createHandlerFn: (target, fn) => fn.bind(target) };
const L = { resolveDefault: (value, fallback) => Promise.resolve(value).catch(() => fallback) };
const window = { confirm: () => true, setTimeout: () => {}, location: { reload: () => assert.fail('must not reload during refresh') } };
const document = { getElementById: id => ids.get(id) };
const view = new Function('rpc', 'ui', 'view', 'L', 'E', 'document', 'window', source)(rpc, ui, { extend: x => x }, L, E, document, window);
const initial = { local_protocol_mode: 'auto', root_password_configured: false,
 modem_cache_interval: 10, selector_cache_interval: 15, cache_warm_interval: 2,
 cache_idle_interval: 30, cache_active_window: 180, signal_test_interval: 1,
 local_enable: true, remote_enable: false, cache_running: true, cache_state: 'idle',
 cache_last_success: 100, cache_elapsed_ms: 50, status_updated: 101, app_plugin_version: '1.11.0',
 presence_interval: 4, status_interval: 40, report_interval: 600, signal_normal_interval: 3,
 signal_carrier_interval: 10, local_led_enable: true, remote_led_enable: false };
for (const match of source.split('const INTERVALS')[0].matchAll(/name:\s*'([^']+)'/g)) {
 if (!(match[1] in initial)) initial[match[1]] = false;
}
function allText(node) {
 return typeof node === 'string' ? node : node && node.children ? node.children.map(allText).join(' ') : '';
}
(async () => {
 const tree = view.render(initial);
 assert.equal(ids.get('c2000max-app-presence_interval').value, '4');
 assert.equal(ids.get('c2000max-app-status_interval').value, '40');
 assert.equal(ids.get('c2000max-app-report_interval').value, '600');
 assert.equal(ids.get('c2000max-app-local_led_enable').checked, true);
 assert.equal(ids.get('c2000max-app-remote_led_enable').checked, false);
 assert(allText(tree).includes('1.5 秒'), 'document the APP-side cache limit');
 assert(allText(tree).includes('1.11.0'), 'show actual plugin version');
 const unsaved = ids.get('c2000max-app-presence_interval'); unsaved.value = '6';
 const unsavedFlag = ids.get('c2000max-app-remote_enable'); unsavedFlag.checked = true;
 statusReply = { ...initial, cache_state: 'error', cache_last_error: 'fixture query failed', presence_interval: 10 };
 await view.refreshStatus();
 assert.equal(unsaved.value, '6'); assert.equal(unsavedFlag.checked, true);
 assert.equal(view.currentStatus, initial, 'status read must retain permission confirmation baseline');
 assert(allText(ids.get('c2000max-app-status')).includes('fixture query failed'));
 assert.equal(ids.get('c2000max-app-refresh').disabled, false);
 statusReply = {};
 await view.refreshStatus();
 assert.equal(notifications.length, 1, 'show invalid status response and keep existing diagnostics');
 assert.equal(ids.get('c2000max-app-refresh').disabled, false);
 assert(allText(ids.get('c2000max-app-status')).includes('fixture query failed'));
 unsaved.value = '1';
 await view.save();
 assert(!calls.some(x => x.method === 'set'), 'reject invalid presence interval before RPC');
 unsaved.value = '6';
 await view.save();
 const set = calls.find(x => x.method === 'set'); assert(set);
 assert.equal(set.args[setParams.indexOf('presence_interval')], 6);
 assert.equal(set.args[setParams.indexOf('report_interval')], 600);
 assert.equal(set.args[setParams.indexOf('local_led_enable')], true);
 assert.equal(set.args[setParams.indexOf('remote_led_enable')], false);
 assert.equal(ids.get('c2000max-app-save').disabled, false, 'failed save permits retry');
 console.log('PASS: refresh configuration, LED permissions, status-only refresh, validation and preservation');
})().catch(error => { console.error(error); process.exitCode = 1; });
