const assert=require('node:assert/strict');
const fs=require('node:fs');
const path=require('node:path');
const vm=require('node:vm');
const D=require('../htdocs/luci-static/c2000max-ui/data.js');
const MiB=1048576;
const fixture={
 metrics:{cpu:{total:1000,idle:700},connections:{count:666,limit:32768}},
 system:{uptime:194460,memory:{total:512*MiB,free:287*MiB,available:350*MiB,cached:72*MiB,buffered:10*MiB},root:{total:128*1024,used:38.4*1024},swap:{total:256*MiB,free:244*MiB}},
 hardware:{cpu_temp:48000,cpu_sensor:'cpu-thermal',wifi_temps:[{milli_c:42000,phy:'phy0'}]},
 config:{cpu_warning:'80',cpu_critical:'90',wifi_warning:'80',wifi_critical:'90'},
 network:{interface:[{interface:'wwan',up:true,route:[{target:'0.0.0.0'}]}]},
 wireless:{radio0:{up:true,interfaces:[{config:{ssid:'C2000MAX_5G',disabled:'0'}}]}},
 clients:{available:true,count:3},
 modem:{section:'modem1',sources:[
  {kind:'base',age:12,entries:[{key:'name',value:'RM520N-GL'},{key:'revision',value:'RM520NGLAAR03A03M4G'},{key:'temperature',value:'46°C'}]},
  {kind:'cell',age:8,entries:[{key:'network_mode',value:'NR5G-SA Mode'},{key:'RSRP',value:'-82'},{key:'SINR',value:'24'},{key:'Band',value:'78'},{key:'Band (CA)',value:'78',extra_info:'CA-NR'},{key:'MCC',value:'460'},{key:'MNC',value:'00'}]},
  {kind:'sim',age:20,entries:[{key:'SIM Slot',value:'1'}]}
 ]}
};
const res=D.resources(fixture.system);
assert.equal(D.metrics(fixture.metrics).cpuPercent,null,'first CPU sample must not invent a utilization');
assert.equal(D.metrics({cpu:{total:2000,idle:1330}},fixture.metrics.cpu).cpuPercent,37);
assert.equal(D.metrics({cpu:{total:2000,idle:1700}},fixture.metrics.cpu).cpuPercent,0);
assert.equal(D.metrics({cpu:{total:900,idle:650}},fixture.metrics.cpu).cpuPercent,null,'reset counters must invalidate the sample');
assert.equal(D.metrics({cpu:{total:2000,idle:600}},fixture.metrics.cpu).cpuPercent,null,'negative idle delta must invalidate the sample');
assert.equal(D.metrics({connections:{count:0,limit:32768}}).connectionPercent,0);
assert.equal(D.metrics({connections:{count:40000,limit:32768}}).connectionPercent,100);
assert.equal(D.metrics({connections:{count:10,limit:0}}).connectionPercent,null);
assert.equal(D.metrics({connections:{count:null,limit:32768}}).count,null);
assert.equal(D.metrics({connections:{count:-1,limit:32768}}).count,null);
assert.deepEqual(res.memory,{total:512,active:143,cache:82,available:350});
assert.equal(D.resources({memory:{total:512}}).memory.available,null);
assert.equal(D.resources({memory:{total:512*MiB,available:150*MiB}}).memory.available,150);
assert.equal(D.resources({memory:{total:512,available:513}}).memory.available,null);
assert.equal(D.resources({memory:{total:512,available:-1}}).memory.available,null);
assert.equal(D.resources({memory:{total:512,available:0}}).memory.available,0);
assert.equal(res.flash.used,38.4);assert.equal(res.swap.used,12);
assert.equal(D.resources({swap:{total:0,free:0}}).swap.total,0);
assert.equal(D.resources({memory:{total:512}}).memory.active,null);
assert.equal(D.resources({memory:{total:10,free:11,cached:1,buffered:0}}).memory.cache,null);
assert.equal(D.measured('N/A'),null);assert.equal(D.measured(''),null);assert.equal(D.measured(false),null);assert.equal(D.measured('0 dB'),0);
assert.equal(D.hardware(fixture.hardware,fixture.config).status,'normal');
assert.equal(D.hardware(fixture.hardware).status,'normal');
assert.equal(D.hardware({...fixture.hardware,cpu_temp:83000}).status,'warning');
assert.equal(D.hardware({cpu_temp:0}).temperatures.cpu,null);
assert.equal(D.hardware({cpu_sensor:'sensor',cpu_temp:0}).temperatures.cpu,0);
assert.equal(D.hardware({...fixture.hardware,cpu_temp:93000},fixture.config).status,'critical');
assert.equal(D.hardware({}).status,'missing');
assert.equal(D.hardware(fixture.hardware,{cpu_warning:90,cpu_critical:80}).status,'unconfigured');
const radio=D.modem(fixture.modem);
assert.equal(radio.rsrp,-82);assert.equal(radio.band,'n78');assert.equal(radio.carriers,2);assert.equal(radio.chinaMobile,true);assert.equal(radio.temperature,46);
const nsa=D.modem({sources:[{kind:'cell',age:1,entries:[{key:'network_mode',value:'EN-DC Mode'},{key:'RSRP',value:'-65',extra_info:'LTE'},{key:'SINR',value:'0',extra_info:'NR'},{key:'RSRP',value:'-90',extra_info:'NR'},{key:'Band',value:'78',extra_info:'NR'}]}]});
assert.equal(nsa.rsrp,-90);assert.equal(nsa.sinr,0);assert.equal(nsa.carriers,1);
const stale=D.modem({sources:fixture.modem.sources.map(s=>({...s,age:999}))});
assert.equal(stale.model,'RM520N-GL');assert.equal(stale.rsrp,null);assert.equal(stale.temperature,null);assert.equal(stale.stale,true);
assert.equal(D.modem({sources:[{kind:'cell',age:0,entries:[{key:'network_mode',value:'LTE Mode'},{key:'RSRP',value:'-82'}]}]}).rsrp,-82);
assert.equal(D.modem({sources:[{kind:'cell',age:0,entries:[{key:'network_mode',value:'NR5G-SA Mode'},{key:'RSRP',value:'255'}]}]}).rsrp,null);
assert.equal(D.network(fixture.network,fixture.wireless,fixture.clients).ssid,'C2000MAX_5G');
assert.equal(D.network({interface:[]}).connected,false);assert.equal(D.network().connected,null);
assert.equal(D.uptime(0),'0 分钟');
const acl=JSON.parse(fs.readFileSync(path.join(__dirname,'../root/usr/share/rpcd/acl.d/luci-theme-c2000max-ui.json')));
assert.equal(acl['luci-theme-c2000max-ui'].write,undefined);
const menu=JSON.parse(fs.readFileSync(path.join(__dirname,'../root/usr/share/luci/menu.d/luci-theme-c2000max-ui.json')));
assert.equal(menu['admin/status/c2000max'].depends.uci.luci.main.mediaurlbase,'/luci-static/c2000max-ui');
for(const name of fs.readdirSync(path.join(__dirname,'../htdocs/luci-static/c2000max-ui')).filter(n=>n.endsWith('.js')))new vm.Script(fs.readFileSync(path.join(__dirname,'../htdocs/luci-static/c2000max-ui',name),'utf8'),{filename:name});
new Function(fs.readFileSync(path.join(__dirname,'../htdocs/luci-static/resources/view/c2000max/home.js'),'utf8'));
fs.mkdirSync(path.join(__dirname,'../build/preview'),{recursive:true});
fs.writeFileSync(path.join(__dirname,'../build/preview/fixture.json'),JSON.stringify(fixture));
console.log('PASS: resource units, invalid/missing data, thermal states, SA/NSA signals, stale cache, permissions and JS syntax');
module.exports=fixture;


const cell=entries=>({sources:[{kind:'cell',age:0,entries:[{key:'network_mode',value:'NR5G-SA Mode'},...entries]}]});
const entry=(key,value,extra_info)=>({key,value,extra_info});
assert.equal(D.modem(cell([entry('MMC','460'),entry('MNC','01'),entry('Band','1')])).operator,'中国联通');
assert.equal(D.modem(cell([entry('Band','1')])).carriers,1);
assert.equal(D.modem(cell([entry('MCC','460'),entry('MNC','01'),entry('Band','78'),entry('Band (CA)','78','CA-NR')])).advanced,true);
assert.equal(D.modem(cell([entry('MCC','460'),entry('MNC','00'),entry('Band','41'),entry('Band (CA)','41','CA-NR'),entry('Band (CA)','79','CA-NR')])).advanced,true);
assert.equal(D.modem(cell([entry('MCC','460'),entry('MNC','00'),entry('Band','78'),entry('Band (CA)','78','CA-NR')])).advanced,false);
assert.equal(D.modem({}, {current_slot:'external1'}).sim,'外置 SIM 1');
assert.equal(D.modem({}, {current_slot:'unknown'}).sim,null);
assert.equal(D.network({},2).ssid,null);
assert.equal(D.network({}, {a:{up:false,interfaces:[{config:{ssid:'off'}}]},b:{up:true,interfaces:[{config:{ssid:'on'}}]}}).ssid,'on');
assert.equal(D.network({}, {a:{up:true,interfaces:[{config:{ssid:'off',disabled:'1'}}]}}).ssid,'无线未启用');
console.log('PASS: MMC alias, SIM slots, 1 CA, operator-specific 5G-A, multi-SSID and RPC failure');

const lteEntries=[entry('network_mode','LTE Mode'),entry('Band',''),entry('Band','3'),entry('Band 1','7'),entry('RSRP','-95','LTE'),entry('RSRQ','-12','LTE'),entry('RSRP','-70','NR')];
const lte=D.modem({sources:[{kind:'cell',age:0,entries:lteEntries}]});
assert.equal(lte.rsrp,-95);assert.equal(lte.sinr,null);assert.equal(lte.rsrq,-12);assert.equal(lte.band,'B3');assert.equal(lte.carriers,2);assert.equal(lte.advanced,false);
assert.equal(D.network({},null,{onlineusers:9}).clients,null);
assert.equal(D.network({},null,{available:true,count:0}).clients,0);
console.log('PASS: LTE band aliases, secondary carriers, signal selection and truthful unavailable clients');
