/* C2000MAX V37.01 overview: a live dashboard over LuCI's existing status view. */
(function () {
  'use strict';
  if (!/\/admin\/status\/overview\/?$/.test(location.pathname)) return;

  var base = (window.L && L.env && L.env.scriptname) || '/cgi-bin/luci';
  var asset = '/luci-static/c2000max/';
  var chartRx = [], chartTx = [], lastCounters = null, deviceCall = null;
  var icons = { device: 'status', signal: 'network', sim: 'storage', wifi: 'wifi', speed: 'speed', resources: 'system', clients: 'devices', arrow: 'arrow' };
  function icon(name) { return '<svg class="c2k-icon" aria-hidden="true"><use href="' + asset + 'icons.svg?v=1.2.0#' + (icons[name] || name) + '"></use></svg>'; }
  function section(name) {
    return Array.prototype.find.call(document.querySelectorAll('#view > .cbi-section'), function (node) {
      var h = node.querySelector('h3');
      return h && h.firstChild && h.firstChild.textContent.trim() === name;
    });
  }
  function rows(name) {
    var s = section(name), result = {};
    if (!s) return result;
    Array.prototype.forEach.call(s.querySelectorAll('tr'), function (tr) {
      var cells = tr.querySelectorAll('td');
      if (cells.length < 2) return;
      var key = cells[0].textContent.trim();
      var value = cells[1].querySelector('.cbi-progressbar');
      result[key] = value ? (value.getAttribute('title') || '') : cells[1].textContent.trim();
    });
    return result;
  }
  function put(id, value) {
    var el = document.getElementById('c2k-' + id);
    if (el) el.textContent = value || '—';
  }
  function percent(raw) { var m = String(raw || '').match(/\((\d+)%\)/); return m ? Math.max(0, Math.min(100, +m[1])) : 0; }
  function signalNumber(raw) { var m = String(raw || '').match(/-?\d+(?:\.\d+)?/); return m ? m[0] : '—'; }
  function detail(label, id) { return '<div><dt>' + label + '</dt><dd id="c2k-' + id + '">—</dd></div>'; }
  function cardHead(type, title, url) {
    return '<div class="c2k-card-head"><span class="c2k-card-icon ' + (type === 'sim' ? 'green' : 'blue') + '">' + icon(type) + '</span><h2>' + title + '</h2>' + (url ? '<a href="' + base + url + '" aria-label="打开' + title + '">' + icon('arrow') + '</a>' : '') + '</div>';
  }
  function dashboardHTML() {
    return '<section class="c2k-hero" aria-label="C2000MAX 概览">' +
      '<div class="c2k-hero-copy"><div class="c2k-overline"><span class="c2k-status-dot"></span> C2000MAX · V37.01</div>' +
      '<h1>你好，<br>一切正常运行</h1><p>设备已运行 <strong id="c2k-hero-uptime">—</strong></p>' +
      '<div class="c2k-hero-chips"><span id="c2k-hero-network">正在读取网络状态</span><span id="c2k-hero-wireless">正在读取 Wi-Fi 状态</span></div></div>' +
      '<div class="c2k-hero-slogan">更快的连接<br><strong>成就更好的生活</strong></div>' +
      '<img class="c2k-hero-device" src="' + asset + 'cpe-device.svg" alt="C2000MAX 设备插画"></section>' +
      '<div class="c2k-overview-grid">' +
      '<section class="c2k-dashboard-card card c2k-device-card">' + cardHead('device', '设备状态', '/admin/status/overview') +
      '<div class="c2k-online"><span class="c2k-online-dot"></span><strong id="c2k-connection">—</strong><small id="c2k-connection-note">读取中</small></div>' +
      '<div class="c2k-device-mini"><img src="' + asset + 'cpe-device.svg" alt=""></div><dl class="c2k-detail-list">' +
      detail('型号', 'model') + detail('上游 IP', 'wan-ip') + detail('运行时间', 'uptime') + detail('温度', 'temperature') + '</dl></section>' +
      '<section class="c2k-dashboard-card card c2k-signal-card">' + cardHead('signal', '信号强度', '/admin/modem/mt5700') +
      '<div class="c2k-signal-grade"><span class="c2k-bars" aria-hidden="true"><i></i><i></i><i></i><i></i><i></i></span><div><small>模组连接</small><strong id="c2k-signal-grade">—</strong></div></div>' +
      '<div class="c2k-signal-meters"><div><span>RSRP</span><em id="c2k-rsrp">—</em><b id="c2k-rsrp-bar"></b></div>' +
      '<div><span>RSRQ</span><em id="c2k-rsrq">—</em><b id="c2k-rsrq-bar"></b></div>' +
      '<div><span>SINR</span><em id="c2k-sinr">—</em><b id="c2k-sinr-bar" class="blue-meter"></b></div></div></section>' +
      '<section class="c2k-dashboard-card card">' + cardHead('sim', 'SIM / 模组', '/admin/modem/c2000max') +
      '<dl class="c2k-detail-list c2k-sim-list">' + detail('模组', 'modem-name') + detail('连接状态', 'modem-status') +
      detail('固件版本', 'modem-version') + detail('模组温度', 'modem-temp') +
      '<div><dt>SIM 管理</dt><dd><a href="' + base + '/admin/modem/c2000max">打开设置 ' + icon('arrow') + '</a></dd></div></dl></section>' +
      '<section class="c2k-dashboard-card card">' + cardHead('wifi', 'Wi-Fi 状态', '/admin/network/wireless') +
      '<div id="c2k-wifi-list" class="c2k-wifi-list"><div class="c2k-wifi-row">正在读取无线状态</div></div>' +
      '<div class="c2k-wifi-total">' + icon('clients') + ' 在线终端 <strong id="c2k-wifi-clients">—</strong></div></section></div>' +
      '<div class="c2k-analysis-grid">' +
      '<section class="c2k-dashboard-card card c2k-speed-card">' + cardHead('speed', '实时速率', '/admin/status/realtime') +
      '<div class="c2k-speed-values"><div><span class="c2k-speed-symbol">↓</span><span>下载速率<strong id="c2k-download">—</strong></span></div>' +
      '<div><span class="c2k-speed-symbol up">↑</span><span>上传速率<strong id="c2k-upload">—</strong></span></div></div>' +
      '<div class="c2k-live-chart"><svg viewBox="0 0 540 120" preserveAspectRatio="none" role="img" aria-label="最近一分钟的实时速率"><path id="c2k-rx-line" class="c2k-rx-line"/><path id="c2k-tx-line" class="c2k-tx-line"/></svg></div>' +
      '<div class="c2k-chart-caption"><span>最近一分钟 · WAN 接口</span><span><i></i> 下行 <i></i> 上行</span></div></section>' +
      '<section class="c2k-dashboard-card card c2k-usage-card">' + cardHead('resources', '资源使用', '/admin/status/overview') +
      '<div class="c2k-donuts"><div><span>CPU</span><div id="c2k-cpu-ring" class="c2k-donut blue-donut"><div><strong id="c2k-cpu">—</strong><small>当前使用</small></div></div></div>' +
      '<div><span>内存</span><div id="c2k-memory-ring" class="c2k-donut green-donut"><div><strong id="c2k-memory">—</strong><small>当前使用</small></div></div></div></div>' +
      '<div class="c2k-resource-meta">设备存储 <strong id="c2k-storage">—</strong></div></section>' +
      '<section class="c2k-dashboard-card card c2k-clients-card">' + cardHead('clients', '设备与租约', '/admin/status/overview') +
      '<ul id="c2k-client-list" class="c2k-clients"></ul><a class="c2k-card-more" href="' + base + '/admin/status/overview#c2k-original-details">查看完整设备详情 ' + icon('arrow') + '</a></section></div>' +
      '<section class="c2k-actions card"><div class="c2k-actions-title"><span class="c2k-card-icon blue">' + icon('speed') + '</span><strong>快捷入口</strong></div>' +
      '<a href="' + base + '/admin/network/network">' + icon('network') + ' 网络接口</a>' +
      '<a href="' + base + '/admin/network/wireless">' + icon('wifi') + ' 无线设置</a>' +
      '<a href="' + base + '/admin/services/c2000max-traffic">' + icon('speed') + ' 流量统计</a>' +
      '<a href="' + base + '/admin/system/package-manager">' + icon('grid') + ' 软件包</a>' +
      '<a href="' + base + '/admin/modem/qmodem">' + icon('signal') + ' QModem</a></section>';
  }
  function update() {
    var sys = rows('系统'), modem = rows('调制解调器信息'), hardware = rows('C2000-MAX 硬件与 PPE 状态');
    var mem = rows('内存'), disk = rows('存储'), network = section('网络'), wireless = section('无线');
    var connected = /^(yes|connected|online|已连接|是)$/i.test(modem['连接状态'] || '');
    var uptime = sys['运行时间'] || '—';
    put('hero-uptime', uptime); put('uptime', uptime); put('model', sys['型号']);
    put('connection', connected ? '在线' : '未连接'); put('connection-note', connected ? '模组运行中' : '请检查模组连接');
    put('hero-network', connected ? '模组已连接' : '模组未连接');
    put('temperature', hardware['CPU 温度'] || sys['温度']);
    put('modem-name', modem['名称']); put('modem-status', modem['连接状态']);
    put('modem-version', modem['修订版本']); put('modem-temp', modem['温度']);
    var wan = network && Array.prototype.find.call(network.querySelectorAll('strong'), function (e) { return e.textContent.trim() === '地址:'; });
    put('wan-ip', wan && wan.nextSibling && wan.nextSibling.textContent.trim());
    var metrics = [ ['参考信号接收功率', 'rsrp', 'dBm'], ['参考信号接收质量', 'rsrq', 'dBm'], ['信号与干扰加噪声比带宽', 'sinr', 'dB'] ];
    metrics.forEach(function (x) { var raw = modem[x[0]]; put(x[1], raw ? signalNumber(raw) + ' ' + x[2] : '—'); var bar = document.getElementById('c2k-' + x[1] + '-bar'); if (bar) bar.style.setProperty('--amount', percent(raw) + '%'); });
    var signal = percent(modem['参考信号接收功率']);
    put('signal-grade', connected ? (signal >= 65 ? '优秀' : signal >= 40 ? '良好' : '较弱') : '未连接');
    var cpu = Math.max(0, Math.min(100, parseFloat(sys['CPU 使用率（%）']) || 0));
    var memory = percent(mem['已使用']);
    put('cpu', Math.round(cpu) + '%'); put('memory', memory + '%'); put('storage', disk['磁盘空间']);
    var cpuRing = document.getElementById('c2k-cpu-ring'), memRing = document.getElementById('c2k-memory-ring');
    if (cpuRing) cpuRing.style.setProperty('--value', cpu + '%'); if (memRing) memRing.style.setProperty('--value', memory + '%');
    if (wireless) {
      var strongs = wireless.querySelectorAll('strong'), radios = [], current = null;
      Array.prototype.forEach.call(strongs, function (s) {
        var key = s.textContent.trim().replace(/:$/, '');
        if (/^MT\d/.test(key)) { current = { name: key }; radios.push(current); }
        else if (current && /^(SSID|信道|关联数)$/.test(key)) current[key] = s.nextSibling && s.nextSibling.textContent.trim();
      });
      var list = document.getElementById('c2k-wifi-list');
      if (list) {
        list.replaceChildren();
        radios.forEach(function (radio) {
          var row = document.createElement('div'); row.className = 'c2k-wifi-row';
          var band = /2\.4/.test(radio['信道']) ? '2.4 GHz' : /5\./.test(radio['信道']) ? '5 GHz' : radio.name;
          var title = document.createElement('span'), badge = document.createElement('span'), sub = document.createElement('small');
          title.textContent = band; sub.textContent = radio.SSID || 'SSID 未设置'; badge.textContent = '运行中'; badge.className = 'c2k-on-badge';
          row.appendChild(title); row.appendChild(sub); row.appendChild(badge); list.appendChild(row);
        });
      }
      put('wifi-clients', radios.reduce(function (n, r) { return n + (+r['关联数'] || 0); }, 0) + ' 台');
      put('hero-wireless', radios.length ? radios.length + ' 组 Wi-Fi 运行中' : 'Wi-Fi 状态未知');
    }
    var leases = section('DHCP 租约'), clients = document.getElementById('c2k-client-list');
    if (leases && clients) {
      clients.replaceChildren();
      Array.prototype.slice.call(leases.querySelectorAll('tr')).forEach(function (tr) {
        if (clients.children.length >= 5) return;
        var cells = tr.querySelectorAll('td'); if (cells.length < 3) return;
        var ip = cells[1].textContent.trim(), host = cells[0].textContent.trim();
        if (!/^\d+\.\d+\.\d+\.\d+$/.test(ip)) return;
        var li = document.createElement('li'), mark = document.createElement('span'), body = document.createElement('div'), title = document.createElement('strong'), sub = document.createElement('small'), address = document.createElement('em');
        mark.textContent = '▣'; title.textContent = host === '-' ? '未知设备' : host.replace(/ \(.*/, ''); sub.textContent = 'DHCP 租约'; address.textContent = ip;
        body.appendChild(title); body.appendChild(sub); li.appendChild(mark); li.appendChild(body); li.appendChild(address); clients.appendChild(li);
      });
      if (!clients.children.length) { var li = document.createElement('li'); li.textContent = '暂无设备信息'; clients.appendChild(li); }
    }
  }
  function formatRate(bytesPerSec) {
    if (!isFinite(bytesPerSec) || bytesPerSec < 0) return '—';
    var mbps = bytesPerSec * 8 / 1000000;
    return (mbps >= 100 ? Math.round(mbps) : mbps >= 10 ? mbps.toFixed(1) : mbps.toFixed(2)) + ' Mbps';
  }
  function drawChart() {
    var peak = Math.max(1, ...chartRx, ...chartTx), size = Math.max(chartRx.length, chartTx.length, 2);
    function path(data) { return data.map(function (v, i) { return (i ? 'L' : 'M') + (i * 540 / (size - 1)).toFixed(1) + ' ' + (114 - v / peak * 102).toFixed(1); }).join(' '); }
    document.getElementById('c2k-rx-line').setAttribute('d', path(chartRx));
    document.getElementById('c2k-tx-line').setAttribute('d', path(chartTx));
  }
  function startSpeed() {
    if (!window.L || !L.require) return;
    L.require('rpc').then(function (rpc) {
      deviceCall = rpc.declare({ object: 'network.device', method: 'status', params: ['name'], expect: {} });
      var net = section('网络'), text = net ? net.textContent : '', match = text.match(/以太网适配器:\s*["“]([^"”]+)["”]/);
      var device = match ? match[1] : 'eth2';
      function sample() {
        deviceCall(device).then(function (data) {
          var stat = data && data.statistics;
          if (!stat && data && data[device]) stat = data[device].statistics;
          if (!stat) return;
          var now = Date.now(), rx = +stat.rx_bytes, tx = +stat.tx_bytes;
          if (lastCounters) {
            var seconds = (now - lastCounters.time) / 1000;
            if (seconds > 0 && rx >= lastCounters.rx && tx >= lastCounters.tx) {
              var down = (rx - lastCounters.rx) / seconds, up = (tx - lastCounters.tx) / seconds;
              put('download', formatRate(down)); put('upload', formatRate(up));
              chartRx.push(down); chartTx.push(up); if (chartRx.length > 20) chartRx.shift(); if (chartTx.length > 20) chartTx.shift(); drawChart();
            }
          }
          lastCounters = { rx: rx, tx: tx, time: now };
        }).catch(function () { put('download', '请查看实时信息'); put('upload', '—'); });
      }
      sample(); setInterval(sample, 3000);
    }).catch(function () { put('download', '请查看实时信息'); });
  }
  function mount() {
    var view = document.getElementById('view'), main = document.getElementById('maincontent');
    if (!view || !view.querySelector('.cbi-section') || !main || document.getElementById('c2k-dashboard')) return false;
    document.body.classList.add('c2k-overview-page');
    var wrap = document.createElement('div'); wrap.id = 'c2k-dashboard'; wrap.innerHTML = dashboardHTML();
    view.parentNode.insertBefore(wrap, view);
    var warning = main.querySelector(':scope > .alert-message');
    if (warning) wrap.insertBefore(warning, wrap.children[1]);
    var details = document.createElement('details'); details.id = 'c2k-original-details'; details.className = 'c2k-original-details';
    var summary = document.createElement('summary'); summary.textContent = '查看完整设备详情与原始状态信息';
    details.appendChild(summary); view.parentNode.insertBefore(details, view); details.appendChild(view);
    var heading = main.querySelector('h2[name="content"]'); if (heading) heading.hidden = true;
    update(); setInterval(update, 5000); startSpeed();
    return true;
  }
  var attempts = 0, timer = setInterval(function () { if (mount() || ++attempts > 60) clearInterval(timer); }, 500);
  if (document.readyState !== 'loading' && mount()) clearInterval(timer);
}());
