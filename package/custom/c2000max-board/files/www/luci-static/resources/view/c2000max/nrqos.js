'use strict';
'require view';
'require form';
'require rpc';
'require poll';
'require dom';

var callStatus = rpc.declare({
	object: 'c2000max-nrqos',
	method: 'status',
	expect: { '': {} }
});

function flag(value) {
	return value === true || value === 1 || value === '1';
}

function rate(value) {
	var n = Number(value);
	return n > 0 && isFinite(n) ? '%s kbit/s（%s Mbit/s）'.format(n, (n / 1000).toFixed(1)) : '—';
}

function numberInRange(value, low, high) {
	return /^\d+$/.test(String(value)) && Number(value) >= low && Number(value) <= high;
}

function validProbe(value) {
	var parts = String(value).split('.');
	if (parts.length !== 4 || !parts.every(function(p) {
		return /^(0|[1-9]\d{0,2})$/.test(p) && Number(p) <= 255;
	}))
		return false;
	return Number(parts[0]) > 0 && Number(parts[0]) !== 127 && Number(parts[0]) < 224;
}

function validateProbes(values) {
	if (!Array.isArray(values) || values.length < 2 || values.length > 3)
		return _('请添加 2 至 3 个不同的 IPv4 探测地址。');
	if (!values.every(validProbe))
		return _('探测地址须为有效 IPv4 地址，不能是回环或组播地址。');
	if (values.some(function(v, i) { return values.indexOf(v) !== i; }))
		return _('探测地址不能重复。');
	return true;
}

function probeStatus(value) {
	var labels = { hold: _('保持'), increase: _('提高限速'), decrease: _('降低限速'), warming: _('基线预热'), idle: _('空闲'), 'probe-loss': _('探测无响应') };
	var match = /^(\d+):([a-z-]+)$/.exec(String(value || ''));
	if (match)
		return _('%s 个健康目标 · %s').format(match[1], labels[match[2]] || match[2]);
	return !value || value === 'starting' ? _('等待探测') : String(value);
}

function renderStatus(data) {
	var enabled = flag(data.enabled), active = flag(data.active);
	var state = active ? _('上行 CAKE 队列运行中') : (enabled ? _('配置已启用，队列未运行') : _('已关闭'));
	if (active && !enabled)
		state = _('队列仍在运行，等待停止');
	if (data._rpc_error || data.active == null)
		state = _('无法读取运行状态');
	var rows = [
		[ _('运行状态'), state ],
		[ _('当前上行限速'), active ? rate(data.upload_kbit) : '—' ],
		[ _('硬件加速'), _('本功能不修改 HNAT 开关；硬件命中与延迟改善仍需流量实测。') ]
	];
	if (active && flag(data.autorate)) {
		var delay = data.delay_ms == null ? NaN : Number(data.delay_ms);
		var load = data.load_percent == null ? NaN : Number(data.load_percent);
		rows.push([ _('自适应状态'), probeStatus(data.probes) ]);
		rows.push([ _('RTT 抬升 / 上行负载'), '%s / %s'.format(
			isFinite(delay) && delay >= 0 ? '%.1f ms'.format(delay) : '—',
			isFinite(load) && load >= 0 ? '%.0f%%'.format(load) : '—') ]);
	}
	var content = [ E('table', { 'class': 'table' }, rows.map(function(row) {
		return E('tr', { 'class': 'tr' }, [
			E('td', { 'class': 'td left', 'width': '30%' }, row[0]),
			E('td', { 'class': 'td left' }, row[1])
		]);
	})) ];
	if (data.error)
		content.push(E('p', { 'class': 'alert-message warning' }, [ _('未生效原因 / 最近错误：'), String(data.error) ]));
	if (data._rpc_error)
		content.push(E('p', { 'class': 'alert-message warning' }, _('无法读取运行状态，请检查服务与 RPC 是否可用。')));
	return E('div', {}, content);
}

function readStatus() {
	return callStatus().catch(function() { return { _rpc_error: true }; });
}

return view.extend({
	load: function() {
		return readStatus();
	},

	render: function(status) {
		var m = new form.Map('c2000max_nrqos', _('5G NR 低延迟 QoS'),
			_('实验性上行整形：使用 CAKE 公平排队，减少上传占满时的排队延迟。只支持默认出口为 eth2 的纯 5G 模式，不支持 WAN / 双 WAN，也不整形下行。'));
		var s = m.section(form.NamedSection, 'main', 'main', _('队列设置'));
		s.addremove = false;
		s.anonymous = true;

		var enabled = s.option(form.Flag, 'enabled', _('启用低延迟 QoS'));
		enabled.default = '0';
		enabled.rmempty = false;
		enabled.description = _('默认关闭。与 SQM、C2000MAX 网络限速互斥，不会自动关闭这些插件。');

		var o = s.option(form.ListValue, 'interface', _('5G 上行接口'));
		o.value('eth2', 'eth2');
		o.default = 'eth2';
		o.rmempty = false;

		var upload = s.option(form.Value, 'upload_kbit', _('上行限速（kbit/s）'));
		upload.default = '130000';
		upload.datatype = 'and(uinteger,range(128,1000000))';
		upload.rmempty = false;
		upload.retain = true;
		upload.depends('enabled', '1');
		upload.description = _('1000 kbit/s = 1 Mbit/s。若通常上行为 150 Mbit/s，可从 130000 开始测试；这不是保证速率。限速必须低于当前可用上行带宽才有整形效果。');

		var autorate = s.option(form.Flag, 'autorate', _('自适应上行限速（实验）'));
		autorate.default = '0';
		autorate.rmempty = false;
		autorate.retain = true;
		autorate.depends('enabled', '1');
		autorate.description = _('根据上行负载和多个目标的 RTT 抬升调整队列速率，仅在出口速率接近当前上限时辅助调整，不能保证跟踪基站容量骤降。5G 信号变化也会影响 RTT，建议先验证固定限速，再启用此项。');

		var minimum = s.option(form.Value, 'min_upload_kbit', _('自适应下限（kbit/s）'));
		var maximum = s.option(form.Value, 'max_upload_kbit', _('自适应上限（kbit/s）'));
		[ minimum, maximum ].forEach(function(option) {
			option.datatype = 'and(uinteger,range(128,1000000))';
			option.rmempty = false;
			option.retain = true;
			option.depends({ enabled: '1', autorate: '1' });
			option.validate = function(section_id, value) {
				if (!numberInRange(value, 128, 1000000))
					return _('请输入 128 至 1000000 之间的整数。');
				var low = Number(minimum.formvalue(section_id));
				var base = Number(upload.formvalue(section_id));
				var high = Number(maximum.formvalue(section_id));
				return low <= base && base <= high ? true : _('须满足：自适应下限 ≤ 上行限速 ≤ 自适应上限。');
			};
		});
		minimum.description = _('按较差信号时仍可维持的上传能力填写，启用自适应时不能为 0。');
		maximum.description = _('按实际可用上行带宽填写，避免持续超出链路容量。');
		upload.validate = function(section_id, value) {
			if (!numberInRange(value, 128, 1000000))
				return _('请输入 128 至 1000000 之间的整数。');
			if (!flag(autorate.formvalue(section_id)))
				return true;
			return Number(minimum.formvalue(section_id)) <= Number(value) && Number(value) <= Number(maximum.formvalue(section_id))
				? true : _('须满足：自适应下限 ≤ 上行限速 ≤ 自适应上限。');
		};

		o = s.option(form.Value, 'interval', _('探测间隔（秒）'));
		o.default = '3';
		o.datatype = 'and(uinteger,range(2,30))';
		o.rmempty = false;
		o.retain = true;
		o.depends({ enabled: '1', autorate: '1' });

		o = s.option(form.Value, 'delay_target_ms', _('允许 RTT 抬升（毫秒）'));
		o.default = '15';
		o.datatype = 'and(uinteger,range(5,200))';
		o.rmempty = false;
		o.retain = true;
		o.depends({ enabled: '1', autorate: '1' });
		o.description = _('相对各目标正常基线的额外延迟，不是 RTT 总值或游戏延迟目标。');

		o = s.option(form.DynamicList, 'ping_hosts', _('探测目标 IPv4'));
		o.default = [ '223.5.5.5', '119.29.29.29' ];
		o.rmempty = false;
		o.retain = true;
		o.depends({ enabled: '1', autorate: '1' });
		o.description = _('填写 2 至 3 个不同且稳定响应 Ping 的地址；默认地址只是候选，请验证在当前运营商线路上的稳定性。');
		o.validate = function(section_id, value) {
			return validProbe(value) ? true : _('请输入有效的非回环、非组播 IPv4 地址。');
		};
		o.parse = function(section_id) {
			if (flag(enabled.formvalue(section_id)) && flag(autorate.formvalue(section_id))) {
				var valid = validateProbes(this.formvalue(section_id));
				if (valid !== true)
					return Promise.reject(new Error(_('探测目标 IPv4：') + valid));
			}
			return form.DynamicList.prototype.parse.call(this, section_id);
		};

		var statusBody = E('div', { 'id': 'c2000max-nrqos-status' }, renderStatus(status || {}));
		var statusNode = E('div', { 'class': 'cbi-section' }, [
			E('h3', {}, _('实时状态')),
			statusBody,
			E('p', {}, _('这里显示当前运行状态，每 3 秒刷新；下方修改需“保存并应用”后生效。'))
		]);
		var scopeNode = E('div', { 'class': 'cbi-section' }, [
			E('p', { 'class': 'alert-message notice' }, _('本功能不修改 HNAT / HQoS 开关、连接标记或官方 Flash，也不将所有 UDP 流量强制提权。它不能消除基站调度、弱信号或运营商核心网造成的延迟。'))
		]);
		poll.add(function() {
			return readStatus().then(function(data) { dom.content(statusBody, renderStatus(data)); });
		}, 3);
		return m.render().then(function(formNode) { return E([ statusNode, formNode, scopeNode ]); });
	}
});
