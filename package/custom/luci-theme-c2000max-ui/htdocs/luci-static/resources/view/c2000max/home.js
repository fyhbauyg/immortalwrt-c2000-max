'use strict';
'require view';
'require rpc';
'require uci';
'require poll';
'require request';

var systemInfo=rpc.declare({object:'system',method:'info'});
var interfaceInfo=rpc.declare({object:'network.interface',method:'dump'});
var wirelessInfo=rpc.declare({object:'network.wireless',method:'status',reject:true});
var clientInfo=rpc.declare({object:'c2000max.ui',method:'clients',reject:true});
var hardwareInfo=rpc.declare({object:'c2000max',method:'hardware_status'});
var sensorsInfo=rpc.declare({object:'c2000max.ui',method:'sensors',reject:true});
var simInfo=rpc.declare({object:'c2000max',method:'sim_status',reject:true});
// Separate from initial rendering and cache reads; QModem owns AT locking.
var modemBaseInfo=rpc.declare({object:'qmodem',method:'base_info',params:['config_section'],reject:true,timeout:20000});
var modemInfo=rpc.declare({object:'c2000max.ui',method:'modem',params:['section']});

return view.extend({
 load: function() {
  // Shell and placeholders render immediately; optional plugins cannot block the view.
  return request.get(L.env.media+'/dashboard.html',{cache:true}).then(function(response) {
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
  var lastSim=0, lastSensors=0, lastModemBase=0;
  var state={}, stopped=false, started=false, busy={};
  // Prevent hung optional RPCs from queuing more calls. Successful groups update independently.
  function call(key,fn) {
   if(busy[key])return;
   busy[key]=true;
   Promise.resolve().then(fn).then(function(value) {
    if(stopped)return;
    state[key]=key==='modemBase'?{entries:value?.modem_info||[],receivedAt:Date.now()}:value;dashboard.update(state);
   }).catch(function() {
    if(stopped)return;
    state[key]=key==='wireless'?null:{};dashboard.update(state);
   }).finally(function(){busy[key]=false;});
  }
  function refresh() {
   if(!root.isConnected) { if(started){stopped=true;poll.remove(refresh);}return; }
   started=true;
   if(document.hidden)return;
   call('system',systemInfo);call('network',interfaceInfo);call('wireless',wirelessInfo);
   if(Date.now()-lastSensors>20000){lastSensors=Date.now();call('sensors',sensorsInfo);}
   if(Date.now()-lastSim>60000){lastSim=Date.now();call('sim',simInfo);}
   call('clients',clientInfo);call('hardware',hardwareInfo);
   if(state.section){
    call('modem',function(){return modemInfo(state.section);});
    if(Date.now()-lastModemBase>60000){lastModemBase=Date.now();call('modemBase',function(){return modemBaseInfo(state.section);});}
   }
  }
  // UCI access is read-only. Missing optional packages keep their cards unavailable.
  Promise.all([
   L.resolveDefault(uci.load('qmodem'),null),
   L.resolveDefault(uci.load('c2000max_ui'),null)
  ]).then(function(){
   state.config=uci.get('c2000max_ui','main')||{};
   var requested=state.config.modem_section;
   var sections=uci.sections('qmodem','modem-device').filter(function(s){return s.enabled!=='0';});
   state.section=requested&&requested!=='auto'?requested:sections[0]?.['.name'];
   refresh();
  }).catch(function(){});
  poll.add(refresh,10);
  window.setTimeout(refresh,0);
  return root;
 },
 handleSaveApply:null,handleSave:null,handleReset:null
});
