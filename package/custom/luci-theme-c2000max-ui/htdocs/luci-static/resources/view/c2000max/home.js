'use strict';
'require view';
'require rpc';
'require uci';
'require poll';
'require request';

var systemInfo=rpc.declare({object:'system',method:'info',reject:true,nobatch:true});
var interfaceInfo=rpc.declare({object:'network.interface',method:'dump'});
var wirelessInfo=rpc.declare({object:'network.wireless',method:'status',reject:true});
var clientInfo=rpc.declare({object:'c2000max.ui',method:'clients',reject:true});
var hardwareInfo=rpc.declare({object:'c2000max',method:'hardware_status',nobatch:true});
var sensorsInfo=rpc.declare({object:'c2000max.ui',method:'sensors',reject:true,nobatch:true});
var metricsInfo=rpc.declare({object:'c2000max.ui',method:'metrics',reject:true,nobatch:true});
var simInfo=rpc.declare({object:'c2000max',method:'sim_status',reject:true,nobatch:true});
// Separate HTTP requests keep serial reads out of the fast dashboard batch.
// QModem owns its existing cache and shared AT transaction lock.
var modemBaseInfo=rpc.declare({object:'qmodem',method:'base_info',params:['config_section'],reject:true,nobatch:true});
var modemCellInfo=rpc.declare({object:'qmodem',method:'cell_info',params:['config_section'],reject:true,nobatch:true});
var modemInfo=rpc.declare({object:'c2000max.ui',method:'modem',params:['section'],reject:true,nobatch:true});

return view.extend({
 load: function() {
  // Shell and placeholders render immediately; optional plugins cannot block the view.
  return request.get(L.env.media+'/dashboard.html?v='+encodeURIComponent(L.env.resource_version||'1.0.22-r1'),{cache:true}).then(function(response) {
   if(!response.ok)throw new Error('Dashboard template unavailable');
   return response.text();
  });
 },
 render: function(html) {
  var root=E('div',{'class':'c2000-dashboard-root'});
  var template=document.createElement('template');template.innerHTML=html;
  root.appendChild(template.content.cloneNode(true));
  root.querySelectorAll('img[src^="assets/"]').forEach(function(img){img.src=L.env.media+'/'+img.getAttribute('src');});
  var dashboard=window.C2000Dashboard.mount(root,function(){return L.url.apply(L,arguments);});
  var lastSim=0, lastSensors=0;
  var state={}, stopped=false, started=false, busy={}, metricsPrimed=false, cacheAgain=false;
  var reads={modemCell:{fn:modemCellInfo,next:0,interval:15000},modemBase:{fn:modemBaseInfo,next:0,interval:30000}};
  var primeTimer;
  function active() {
   if(!root.isConnected){
    if(started&&!stopped){stopped=true;[refresh,refreshMetrics,refreshModem].forEach(poll.remove.bind(poll));document.removeEventListener('visibilitychange',onVisibility);window.clearTimeout(primeTimer);}
    return false;
   }
   started=true;
   return !stopped&&!document.hidden;
  }
  function updateDashboard() {
   state.system=window.C2000Data.systemSnapshot(state.system);
   dashboard.update(state);
  }
  // Prevent hung optional RPCs from queuing more calls. Successful groups update independently.
  function call(key,fn,done) {
   if(busy[key])return;
   busy[key]=true;
   Promise.resolve().then(fn).then(function(value) {
    if(stopped)return;
    if(key==='system')state.system=window.C2000Data.systemSnapshot(state.system,value??null);
    else if(key==='modem')state.modem=window.C2000Data.modemSnapshot(state.modem,value||{});
    else state[key]=key==='sim'?{...value,receivedAt:Date.now()}:value;
    updateDashboard();
    if(key==='metrics'&&!metricsPrimed){metricsPrimed=true;primeTimer=window.setTimeout(refreshMetrics,1000);}
   }).catch(function() {
    if(stopped)return;
    if(key==='system')state.system=window.C2000Data.systemSnapshot(state.system,null);
    else if(key!=='modem'&&key!=='sim')state[key]=key==='wireless'?null:{};
    updateDashboard();
   }).finally(function(){busy[key]=false;if(!stopped&&done)done();});
  }
  function refreshMetrics() {
   if(active())call('metrics',metricsInfo);
  }
  function refreshCache() {
   if(!active()||!state.section)return;
   if(busy.modem){cacheAgain=true;return;}
   call('modem',function(){return modemInfo(state.section);},function(){if(cacheAgain){cacheAgain=false;refreshCache();}});
  }
  function refreshModem() {
   if(!active()||!state.section)return;
   updateDashboard(); // Expire old fields even while a query is pending.
   refreshCache();
   if(Object.keys(reads).some(function(key){return busy[key];}))return;
   var key=Object.keys(reads).find(function(key){return Date.now()>=reads[key].next;});
   if(key){
    var read=reads[key];
    busy[key]=true;
    Promise.resolve().then(function(){return read.fn(state.section);}).then(function(){read.next=Date.now()+read.interval;})
     .catch(function(){read.next=Date.now()+5000;})
     .finally(function(){busy[key]=false;if(!stopped)refreshModem();});
   }
  }
  function refresh() {
   if(!active())return;
   updateDashboard();
   call('system',systemInfo);call('network',interfaceInfo);call('wireless',wirelessInfo);
   if(Date.now()-lastSensors>20000){lastSensors=Date.now();call('sensors',sensorsInfo);}
   if(Date.now()-lastSim>30000){lastSim=Date.now();call('sim',simInfo);}
   call('clients',clientInfo);call('hardware',hardwareInfo);
  }
  function onVisibility() {
   if(!document.hidden){refresh();refreshModem();refreshMetrics();}
  }
  // UCI access is read-only. Missing optional packages keep their cards unavailable.
  Promise.all([
   L.resolveDefault(uci.load('qmodem'),null),
   L.resolveDefault(uci.load('c2000max_ui'),null)
  ]).then(function(){
   state.config=uci.get('c2000max_ui','main')||{};
   var requested=state.config.modem_section;
   var sections=uci.sections('qmodem','modem-device').filter(function(s){return s.enabled!=='0'&&s.state!=='disabled';});
   state.section=requested&&requested!=='auto'?requested:sections[0]?.['.name'];
   refresh();refreshModem();
  }).catch(function(){});
  poll.add(refresh,10);
  poll.add(refreshMetrics,5);
  poll.add(refreshModem,5);
  document.addEventListener('visibilitychange',onVisibility);
  window.setTimeout(refresh,0);
  window.setTimeout(refreshMetrics,0);
  return root;
 },
 handleSaveApply:null,handleSave:null,handleReset:null
});
