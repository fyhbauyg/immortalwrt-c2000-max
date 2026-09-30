'use strict';
'require view';
'require rpc';
'require poll';
'require dom';
'require ui';

var callStatus = rpc.declare({
	object: 'c2000max',
	method: 'sim_status',
	expect: { '': {} }
});

var callSwitch = rpc.declare({
	object: 'c2000max',
	method: 'sim_switch',
	params: [ 'slot' ],
	expect: { '': {} }
});

var callForce = rpc.declare({
	object: 'c2000max',
	method: 'sim_force',
	params: [ 'slot' ],
	expect: { '': {} }
});

var callJobStatus = rpc.declare({
	object: 'c2000max', method: 'sim_job_status',
	params: [ 'job_id' ], expect: { '': {} }
});

function waitForSimJob(result) {
	if (!result || !result.job_id || result.done)
		return Promise.resolve(result || {});
	var id = result.job_id, attempts = 0;
	function check() {
		return callJobStatus(id).then(function(state) {
			if (state.done)
				return state.result || state;
			if (++attempts >= 120)
				throw new Error(_('等待 SIM 操作超时，请刷新查看当前状态'));
			return new Promise(function(resolve) { window.setTimeout(resolve, 2000); }).then(check);
		});
	}
	return check();
}

var slotNames = {
	external1: _('外置卡槽 1'),
	external2: _('外置卡槽 2'),
	internal: _('内置贴片卡'),
	unknown: _('未知')
};

var stateNames = {
	stable: _('已确认'),
	noncanonical: _('已识别（GPIO 将在下次切换时归一化）'),
	inactive: _('SIM 接口未激活（目标卡槽可能为空）'),
	inconsistent: _('模组状态不一致'),
	offline: _('模组离线'),
	unknown: _('无法确认')
};

function value(v, fallback) {
	return (v != null && String(v).length) ? v : (fallback || _('未知'));
}

function isRecognizedMT5700(data) {
	var identity = [ data && data.model, data && data.manufacturer, data && data.platform ]
		.filter(function(part) { return part != null; }).join(' ').toLowerCase();
	return !!(data && (data.available === true || data.available === 1) &&
		/(?:mt\s*-?\s*5700|\b5700\b)/.test(identity));
}

return view.extend({
	load: function() {
		return L.resolveDefault(callStatus(), {});
	},

	renderStatus: function(data) {
		var current = data.current_slot || 'unknown';
		var table = E('table', { 'class': 'table' }, [
			E('tr', { 'class': 'tr' }, [ E('td', { 'class': 'td left', 'width': '33%' }, _('当前模组名称')), E('td', { 'class': 'td left' }, value(data.model)) ]),
			E('tr', { 'class': 'tr' }, [ E('td', { 'class': 'td left' }, _('当前 SIM 卡槽')), E('td', { 'class': 'td left' }, slotNames[current] || slotNames.unknown) ]),
			E('tr', { 'class': 'tr' }, [ E('td', { 'class': 'td left' }, _('槽位检测状态')), E('td', { 'class': 'td left' }, stateNames[data.route_state] || stateNames.unknown) ]),
			E('tr', { 'class': 'tr' }, [ E('td', { 'class': 'td left' }, _('ICCID')), E('td', { 'class': 'td left' }, value(data.iccid, _('未检测到 SIM 卡'))) ]),
			E('tr', { 'class': 'tr' }, [ E('td', { 'class': 'td left' }, _('运营商')), E('td', { 'class': 'td left' }, value(data.carrier)) ]),
			E('tr', { 'class': 'tr' }, [ E('td', { 'class': 'td left' }, _('SIM 状态')), E('td', { 'class': 'td left' }, value(data.cpin)) ]),
			E('tr', { 'class': 'tr' }, [ E('td', { 'class': 'td left' }, _('QModem / AT 串口')), E('td', { 'class': 'td left' }, '%s / %s'.format(value(data.qmodem_section), value(data.at_port))) ]),
			E('tr', { 'class': 'tr' }, [ E('td', { 'class': 'td left' }, _('硬件选择状态')), E('td', { 'class': 'td left' }, _('模组通道 %s，GPIO48=%s').format(value(data.module_channel, '-'), value(data.gpio_mux, '-'))) ])
		]);
		if (data.forced_slot) {
			table.appendChild(E('tr', { 'class': 'tr' }, [
				E('td', { 'class': 'td left' }, _('最近一次强制 GPIO 操作')),
				E('td', { 'class': 'td left' }, _('GPIO48=%s（模组已重启）').format(value(data.forced_gpio, '-')) + ' · ' + ({ changed: _('已确认换卡'), unchanged: _('ICCID 未变化，换卡未确认'), readable: _('SIM 可读，换卡未确认'), unavailable: _('SIM 未就绪，换卡未确认') }[data.force_verification] || _('换卡未确认')))
			]));
		}

		var buttons = E('div', { 'class': 'cbi-page-actions', 'style': 'display:flex;gap:.5em;flex-wrap:wrap;justify-content:flex-start' });
		[ 'external1', 'external2', 'internal' ].forEach(L.bind(function(slot) {
			buttons.appendChild(E('button', {
				'class': 'btn cbi-button cbi-button-action' + (current === slot ? ' important' : ''),
				'disabled': current === slot ? '' : null,
				'click': ui.createHandlerFn(this, 'handleSwitch', slot)
			}, [ current === slot ? _('当前：') + slotNames[slot] : _('切换到') + slotNames[slot] ]));
		}, this));

		var forceButtons = E('div', { 'style': 'display:flex;gap:.5em;flex-wrap:wrap;margin-top:.8em' });
		[ 'external1', 'external2' ].forEach(L.bind(function(slot) {
			forceButtons.appendChild(E('button', {
				'class': 'btn cbi-button cbi-button-negative',
				'type': 'button',
				'click': ui.createHandlerFn(this, 'handleForce', slot)
			}, _('重启并设置 GPIO48=%s（%s）').format(slot === 'external1' ? '0' : '1', slot === 'external1' ? _('低电平') : _('高电平'))));
		}, this));
		var forceBox = E('div', { 'class': 'alert-message warning', 'style': 'margin-top:1em' }, [
			E('strong', {}, _('GPIO 切卡与模组重启：')),
			E('span', {}, _('模组断电后切换 GPIO48，再重新上电读取 SIM，并检查 ICCID 是否变化。该操作保留模组当前的内部 SIM 通道；若切换后仍读到原卡，请检查 SIM 通道与硬件连接。')),
			forceButtons
		]);

		return E(isRecognizedMT5700(data) ? [ table, buttons ] : [ table, buttons, forceBox ]);
	},

	updateStatus: function(data) {
		if (this.statusNode)
			dom.content(this.statusNode, this.renderStatus(data || {}));
	},

	handleSwitch: function(slot, ev) {
		ev.currentTarget.blur();
		/* Do not let the periodic status request issue AT commands while the
		 * switch sequence owns the modem port. */
		poll.stop();
		ui.showModal(_('正在切换 SIM 卡'), [
			E('p', { 'class': 'spinning' }, _('正在安全停用 SIM、切换模组通道/GPIO 并校验结果，请稍候……'))
		]);

		return callSwitch(slot).then(waitForSimJob).then(L.bind(function(result) {
			ui.hideModal();
			this.updateStatus(result);
			ui.addNotification(null, E('p', {}, result.success ? value(result.message, _('SIM 卡切换成功')) : value(result.message, _('SIM 卡切换失败'))),
				result.success ? 'info' : 'error');
			poll.start();
		}, this)).catch(function(err) {
			ui.hideModal();
			ui.addNotification(null, E('p', {}, _('SIM 卡切换失败：%s').format(err.message || err)), 'error');
			poll.start();
		});
	},

	handleForce: function(slot, ev) {
		var self = this;
		ev.currentTarget.blur();
		ui.showModal(_('确认强制 GPIO 切换'), [
			E('p', {}, _('该操作会让模组断电约 8 秒，在断电期间设置 GPIO48，然后重新上电并读取 SIM。蜂窝网络会暂时断开，路由器和 Wi-Fi 保持运行。')),
			E('p', {}, _('目标 GPIO48=%s；实际卡槽需另行确认').format(slot === 'external1' ? '0' : '1')),
			E('div', { 'class': 'right' }, [
				E('button', {
					'class': 'btn',
					'type': 'button',
					'click': ui.hideModal
				}, _('取消')),
				' ',
				E('button', {
					'class': 'btn cbi-button cbi-button-negative important',
					'type': 'button',
					'click': function() { return self.executeForce(slot); }
				}, _('确认强制切换'))
			])
		]);
	},

	executeForce: function(slot) {
		poll.stop();
		ui.showModal(_('正在切换 SIM 并重启模组'), [
			E('p', { 'class': 'spinning' }, _('正在断电切换 GPIO、重新启动模组并等待 SIM 就绪，可能需要一至两分钟……'))
		]);
		return callForce(slot).then(waitForSimJob).then(L.bind(function(result) {
			ui.hideModal();
			this.updateStatus(result);
			ui.addNotification(null, E('p', {}, result.success ? value(result.message, _('GPIO 强制切换完成')) : value(result.message, _('GPIO 强制切换失败'))),
				result.success ? 'warning' : 'error');
			poll.start();
		}, this)).catch(function(err) {
			ui.hideModal();
			ui.addNotification(null, E('p', {}, _('GPIO 强制切换失败：%s').format(err.message || err)), 'error');
			poll.start();
		});
	},

	render: function(data) {
		this.statusNode = E('div', { 'class': 'cbi-section' }, this.renderStatus(data || {}));
		poll.add(L.bind(function() {
			return L.resolveDefault(callStatus(), {}).then(L.bind(this.updateStatus, this));
		}, this));

		return E([ 
			E('h2', {}, _('SIM 卡切换')),
			this.statusNode
		]);
	},

	handleSaveApply: null,
	handleSave: null,
	handleReset: null
});
