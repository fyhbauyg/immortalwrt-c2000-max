(function () {
  'use strict';
  var rx = 107583100, tx = 21491720, count = 0;
  var calls = {
    'system.board': { hostname:'C2000MAX', model:'NRadio C2000-MAX', release:{ description:'OpenWrt C2000MAX V37.01' } },
    'system.info': { uptime:212403, memory:{ total:1073741824, available:611319808 } },
    'network.interface.dump': { interface:[{ interface:'eth2', up:true, device:'eth2', l3_device:'eth2', 'ipv4-address':[{address:'192.168.66.123'}] }, { interface:'lan', up:true, 'ipv4-address':[{address:'192.168.66.1'}] }] },
    'luci-rpc.getWirelessDevices': { radio0:{up:true},radio1:{up:true} },
    'c2000max.sim_status': {available:true,qmodem_section:'2_1',cpin:'READY',current_slot:'SIM 1',carrier:'中国移动'},
    'c2000max.hardware_status': {cpu_temp:52.4,hardware_offloading:true},
    'qmodem.overview_info': {modem_info:[{key:'name',value:'MT5700M-CN'},{key:'connect_status',value:'Yes'},{key:'network_mode',value:'NR5G-SA Mode'},{key:'RSRP',value:'-86'},{key:'RSRQ',value:'-10'},{key:'SINR',value:'23'},{key:'Band',value:'78'}]}
  };
  var rpc = { declare:function (desc) { return function () {
    var id = desc.object + '.' + desc.method;
    if (id === 'network.device.status') { count++; rx += 650000 + Math.sin(count/2)*370000; tx += 140000 + Math.cos(count/3)*60000; return Promise.resolve({statistics:{rx_bytes:rx,tx_bytes:tx}}); }
    return Promise.resolve(calls[id] || {});
  }; } };
  var poll = { add:function (fn) { fn(); setInterval(fn,1200); } };
  var L = { url:function () { return '#' + Array.prototype.join.call(arguments,'/'); }, bind:function (fn,self) { return fn.bind(self); } };
  fetch('../htdocs/luci-static/resources/view/cpeargon/home.js').then(function (r) { return r.text(); }).then(function (source) {
    var page = new Function('view','rpc','poll','L',source)({extend:function(x){return x;}},rpc,poll,L);
    return page.load().then(function(data){document.getElementById('view').appendChild(page.render(data));});
  }).catch(function (err) { document.getElementById('view').textContent = '预览加载失败：' + err.message; });
  var toggle=document.querySelector('.showSide'),side=document.querySelector('#mainmenu'),mask=document.querySelector('.darkMask');
  function close(){side.classList.remove('active');mask.classList.remove('active');}
  toggle.addEventListener('click',function(){side.classList.toggle('active');mask.classList.toggle('active');});
  mask.addEventListener('click',close);
}());
