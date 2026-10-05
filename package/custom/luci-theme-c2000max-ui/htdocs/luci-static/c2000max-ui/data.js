/* Read-only adapters for the V37.01 LuCI / QModem / c2000max interfaces.
   All capacities entering the view are MiB; temperatures are Celsius. */
(function(root, factory) {
 const api = factory();
 if (typeof module === 'object' && module.exports) module.exports = api;
 else root.C2000Data = api;
})(typeof globalThis === 'object' ? globalThis : this, function() {
'use strict';
const MiB=1024*1024;
function number(value) {
 if (typeof value !== 'number' && typeof value !== 'string') return null;
 if (typeof value === 'string' && !value.trim()) return null;
 const n=Number(value);
 return Number.isFinite(n) ? n : null;
}
function measured(value) {
 if (typeof value==='number') return number(value);
 const m=String(value ?? '').trim().match(/^([+-]?\d+(?:\.\d+)?)\s*(?:°?C|℃|dBm|dB)?$/i);
 return m ? number(m[1]) : null;
}
function bounded(value,low,high) { const n=measured(value); return n!==null && n>=low && n<=high ? n : null; }
function text(value) { return typeof value==='string' && value.trim() && !/^(unknown|n\/a|none|null|未发现|未知.*|-|error)$/i.test(value.trim()) ? value.trim() : null; }
function resources(info={}) {
 const m=info.memory||{}, s=info.swap||{}, r=info.root||{};
 const total=number(m.total), free=number(m.free), cached=number(m.cached), buffered=number(m.buffered);
 const cache=cached!==null && buffered!==null ? cached+buffered : null;
 const valid=total>0 && free!==null && cache!==null && free>=0 && cache>=0 && free+cache<=total;
 const available=number(m.available);
 const swTotal=number(s.total),swFree=number(s.free);
 const rootTotal=number(r.total),rootUsed=number(r.used);
 return {
  memory:{total:total>0?total/MiB:null, active:valid?(total-free-cache)/MiB:null,cache:valid?cache/MiB:null,available:total>0&&available!==null&&available>=0&&available<=total?available/MiB:null},
  flash:{total:rootTotal>0?rootTotal/1024:null,used:rootUsed!==null&&rootUsed>=0&&rootUsed<=rootTotal?rootUsed/1024:null},
  swap:{total:swTotal!==null&&swTotal>=0?swTotal/MiB:null,used:swTotal!==null&&swFree!==null&&swFree>=0&&swFree<=swTotal?(swTotal-swFree)/MiB:null}
 };
}
// Preserve valid system groups across short failures without refreshing their age.
function systemSnapshot(previous={},incoming,now=Date.now()) {
 const reply=incoming&&typeof incoming==='object'&&!Array.isArray(incoming)?incoming:{};
 const reboot=number(reply.uptime)!==null&&Number(reply.uptime)>=0&&number(previous.uptime)!==null&&Number(reply.uptime)<Number(previous.uptime);
 const old=reboot?{}:previous, samples={}, result={};
 const converted=resources(reply);
 const valid={
  uptime:number(reply.uptime)!==null&&Number(reply.uptime)>=0,
  memory:converted.memory.total>0&&converted.memory.active!==null&&converted.memory.cache!==null,
  root:converted.flash.total>0&&converted.flash.used!==null,
  swap:converted.swap.total===0||(converted.swap.total>0&&converted.swap.used!==null)
 };
 let incomplete=incoming===undefined?!!old.incomplete:false;
 for(const key of ['uptime','memory','root','swap']) {
  if(valid[key]) {
   result[key]=key==='uptime'?Number(reply[key]):{...reply[key]};samples[key]=now;
  } else {
   if(incoming!==undefined)incomplete=true;
   const stamp=number(old.samples?.[key]);
   if(stamp!==null&&now-stamp>=0&&now-stamp<=60000){result[key]=old[key];samples[key]=stamp;}
  }
 }
 const count=Object.keys(samples).length;
 const delayed=Object.values(samples).some(stamp=>now-stamp>30000);
 return {...result,samples,incomplete,cacheStatus:count===0?'missing':incomplete||count<4||delayed?'cached':'fresh'};
}
function hardware(raw={},config={}) {
 const cpu=raw.cpu_sensor ? bounded(number(raw.cpu_temp)===null?null:Number(raw.cpu_temp)/1000,-40,150) : null;
 const wifiValues=(Array.isArray(raw.wifi_temps)?raw.wifi_temps:[]).map(v=>bounded(number(v.milli_c)===null?null:Number(v.milli_c)/1000,-40,150)).filter(v=>v!==null);
 const temperatures={cpu,wifi:wifiValues.length?Math.max(...wifiValues):null}, limits={};
 ['cpu','wifi'].forEach(key=>{
  // UI advisory levels, not hardware throttling/shutdown limits. UCI may override both.
  const warning=bounded(config[key+'_warning']??80,0,150),critical=bounded(config[key+'_critical']??90,0,150);
  if(warning!==null && critical!==null && warning<critical) limits[key]={warning,critical};
 });
 const statuses=Object.entries(temperatures).map(([key,v])=>v===null?'missing':!limits[key]?'unconfigured':v>=limits[key].critical?'critical':v>=limits[key].warning?'warning':'normal');
 const status=['critical','warning','missing','unconfigured','normal'].find(v=>statuses.includes(v));
 return {temperatures,limits,status,allMissing:statuses.every(v=>v==='missing')};
}
function validModemEntry(entry) {
 if(!entry || typeof entry.key!=='string' || text(String(entry.value??''))===null)return false;
 const key=entry.key.toLowerCase();
 const limits={temperature:[-40,150],rsrp:[-156,-31],sinr:[-30,50],rsrq:[-43,20]};
 if(limits[key])return bounded(entry.value,...limits[key])!==null;
 if(/^band(?: \(ca\)| \d+)?$/.test(key))return /^(?:(?:NR|LTE)\s*(?:BAND)?\s*)?[nb]?\d{1,3}$/i.test(String(entry.value).trim());
 return true;
}
// Keep each last valid field's original sample time; repeated cache reads cannot
// extend its lifetime. A radio/serving-cell change invalidates old radio fields.
function modemSnapshot(previous={},incoming={},now=Date.now()) {
 const same=!previous.section||!incoming.section||previous.section===incoming.section;
 const result=[];
 const observed=(entry,source,raw)=>number(entry.observedAt)??((number(raw.receivedAt)??now)-Math.max(0,number(source.age)??121)*1000);
 for(const kind of ['base','cell','info','sim','network']) {
  const fields=new Map();
  const rows=raw=>(Array.isArray(raw.sources)?raw.sources:[]).filter(s=>s.kind===kind).flatMap(s=>{
   const occurrence={};
   return (Array.isArray(s.entries)?s.entries:[]).filter(validModemEntry).map(e=>{
    const id=e.key.toLowerCase()+'|'+String(e.extra_info||'').toLowerCase();
    return {id:id+'|'+(occurrence[id]=(occurrence[id]||0)+1),entry:{...e,observedAt:observed(e,s,raw),observedSample:number(e.observedSample)??number(s.sample)}};
   });
  });
  if(same)for(const row of rows(previous))fields.set(row.id,row.entry);
  const latest=Math.max(-Infinity,...[...fields.values()].map(e=>number(e.observedSample)??-Infinity));
  const current=rows(incoming).filter(row=>number(row.entry.observedSample)===null||row.entry.observedSample>=latest);
  if(kind==='cell') {
   const find=(list,pattern)=>list.find(e=>pattern.test(e.key))?.value;
   const old=[...fields.values()],next=current.map(r=>r.entry);
   const oldMode=find(old,/^network_mode$/i),newMode=find(next,/^network_mode$/i);
   const oldCell=find(old,/^cell ?id$/i),newCell=find(next,/^cell ?id$/i);
   if((newMode&&oldMode&&newMode!==oldMode)||(newCell&&oldCell&&newCell!==oldCell))fields.clear();
   // A new primary-band snapshot also replaces its secondary-carrier list.
   const newer=current.some(row=>number(row.entry.observedSample)!==null?row.entry.observedSample>latest:row.entry.observedAt>Math.max(-Infinity,...old.map(e=>e.observedAt)));
   if(newer&&next.some(e=>/^(Band|LTE_BAND|Freq band indicator)$/i.test(e.key)))
    for(const [id,e] of fields)if(/^(Band(?: \(CA\)| \d+)?|LTE_BAND|Freq band indicator)$/i.test(e.key))fields.delete(id);
  }
  for(const row of current) {
   const old=fields.get(row.id);
   if(old&&number(old.observedSample)!==null&&old.observedSample===row.entry.observedSample)row.entry.observedAt=Math.min(old.observedAt,row.entry.observedAt);
   if(!old||row.entry.observedAt>=old.observedAt)fields.set(row.id,row.entry);
  }
  const entries=[...fields.values()].filter(e=>/^(name|revision|ISP)$/i.test(e.key)||(now-e.observedAt>=0&&now-e.observedAt<=120000));
  if(entries.length)result.push({kind,age:Math.max(0,(now-Math.max(...entries.map(e=>e.observedAt)))/1000),entries});
 }
 return {section:incoming.section||previous.section,sources:result,receivedAt:now,cache_only:true};
}
function modem(raw={},simState={},liveBase={},now=Date.now()) {
 const sources=Array.isArray(raw.sources)?[...raw.sources]:[];
 const liveAge=number(liveBase.receivedAt)===null?null:(now-liveBase.receivedAt)/1000;
 if(liveAge!==null&&liveAge>=0&&liveAge<=120&&Array.isArray(liveBase.entries))
  sources.unshift({kind:'base',age:liveAge,entries:liveBase.entries});
 const elapsed=number(raw.receivedAt)===null?0:Math.max(0,(now-raw.receivedAt)/1000);
 const entryAge=(e,s)=>number(e.observedAt)!==null?(now-e.observedAt)/1000:(number(s.age)??Infinity)+elapsed;
 const fresh=sources.map(s=>({...s,entries:(Array.isArray(s.entries)?s.entries:[]).filter(e=>entryAge(e,s)>=0&&entryAge(e,s)<=120)})).filter(s=>s.entries.length);
 const all=sources.flatMap(s=>Array.isArray(s.entries)?s.entries:[]);
 const cellEntries=fresh.filter(s=>s.kind==='cell').flatMap(s=>s.entries);
 const find=(list,key)=>list.find(e=>key.test(e.key)&&validModemEntry(e))?.value;
 const cellMode=find(cellEntries,/^network_mode$/i),cellId=find(cellEntries,/^cell ?id$/i);
 const hasBand=cellEntries.some(e=>/^(Band|LTE_BAND|Freq band indicator)$/i.test(e.key)&&validModemEntry(e));
 const usable=fresh.map(s=>{
  if(s.kind!=='info')return s;
  const infoMode=find(s.entries,/^network_mode$/i),infoId=find(s.entries,/^cell ?id$/i);
  const sameCell=(!cellMode||infoMode===cellMode)&&(!cellId||!infoId||cellId===infoId);
  return {...s,entries:s.entries.filter(e=>{
   if(/^(name|revision|temperature|ISP)$/i.test(e.key))return true;
   if(!sameCell)return false;
   if(hasBand&&/^(Band(?: \(CA\)| \d+)?|LTE_BAND|Freq band indicator)$/i.test(e.key))return false;
   return !cellEntries.some(c=>c.key.toLowerCase()===e.key.toLowerCase()&&String(c.extra_info||'')===String(e.extra_info||'')&&validModemEntry(c));
  })};
 });
 const entries=usable.flatMap(s=>s.entries);
 const get=(key,list=entries)=>list.find(e=>String(e.key).toLowerCase()===key.toLowerCase() && e.value!=null && text(String(e.value))!==null)?.value;
 const mode=text(get('network_mode'));
 const nrMode=!!mode && /NR|5G|EN-DC/i.test(mode);
 const nsa=!!mode && /NSA|EN-DC/i.test(mode);
 const lteMode=!!mode && /LTE|4G/i.test(mode) && !nrMode;
 const radioEntries=entries.filter(e=>{
  const tag=String(e.extra_info||'');
  if(/CA/i.test(tag))return false;
  return nrMode ? (nsa?/^(NR|5G)/i.test(tag):!/LTE|4G/i.test(tag)) : lteMode&&!/NR|5G/i.test(tag);
 });
 const parseBand=value=>String(value??'').trim().match(nrMode?/^(?:NR\s*)?n?(\d{1,3})$/i:/^(?:LTE\s*(?:BAND)?\s*)?b?(\d{1,3})$/i);
 const band=['Band','LTE_BAND','Freq band indicator'].map(k=>parseBand(get(k,radioEntries))).find(Boolean);
 const ca=entries.filter(e=>/^(Band \(CA\)|Band [1-9]\d*)$/i.test(e.key||'') &&
  (nrMode?!/LTE|4G/i.test(e.extra_info||''):lteMode&&!/NR|5G/i.test(e.extra_info||'')) && parseBand(e.value));
 const nrEntries=radioEntries;
 const mcc=String(get('MCC',nrEntries)||get('MMC',nrEntries)||get('MCC')||get('MMC')||'');
 const mnc=String(get('MNC',nrEntries)||get('MNC')||'').padStart(2,'0');
 const carrier=text(simState.carrier)||text(get('ISP'));
 const mobile=mcc==='460'&&['00','02','04','07','08','13'].includes(mnc);
 const operator=carrier||(mobile?'中国移动':mcc==='460'&&['01','06','09'].includes(mnc)?'中国联通':mcc==='460'&&['03','05','11'].includes(mnc)?'中国电信':mcc==='460'&&mnc==='15'?'中国广电':null);
 const operatorId=/中国移动|china mobile|CMCC/i.test(operator||'')?'mobile':/中国联通|unicom/i.test(operator||'')?'unicom':/中国电信|telecom/i.test(operator||'')?'telecom':/中国广电|broadnet|CBN/i.test(operator||'')?'broadnet':null;
 const bands=band?[Number(band[1]),...ca.map(e=>Number(parseBand(e.value)[1]))]:[];
 const advanced=nrMode && ((['telecom','unicom'].includes(operatorId)&&bands.filter(b=>b===78).length>=2)||(['mobile','broadnet'].includes(operatorId)&&bands.filter(b=>b===41).length>=2&&bands.includes(79)));
 const slots={external1:'外置 SIM 1',external2:'外置 SIM 2',internal:'内置 SIM'};
 const ages=usable.filter(s=>s.kind==='cell'||s.kind==='info').flatMap(s=>s.entries.filter(e=>/^(network_mode|RSRP|SINR|RSRQ|Band)$/i.test(e.key)).map(e=>entryAge(e,s)));
 const simAge=number(simState.receivedAt)===null?0:(now-simState.receivedAt)/1000;
 return {
  model:text(get('name',all)), firmware:text(get('revision',all)),
  temperature:bounded(get('temperature'),-40,150),
  sim:simAge>=0&&simAge<=120?slots[simState.current_slot]||null:null, mode, nr:nrMode,
  rsrp:bounded(get('RSRP',radioEntries),-156,-31),sinr:bounded(get('SINR',radioEntries),-30,50),rsrq:bounded(get('RSRQ',radioEntries),-43,20),
  band:band?(nrMode?'n':'B')+band[1]:null,
  carriers:band?1+ca.length:null, operatorId, advanced,
  operator,chinaMobile:mobile||/中国移动|china mobile|CMCC/i.test(operator||''),
  status:mode ? (/No Service|SEARCH|NOCONN|未注册|无服务/i.test(mode)?'unregistered':'registered') : 'unknown',
  cached:sources.length>0,stale:sources.length>0&&!usable.some(s=>(s.kind==='cell'||s.kind==='info')&&s.entries.some(e=>/^network_mode$/i.test(e.key))),
  age:ages.length?Math.max(...ages):null,section:text(raw.section)
 };
}
function network(raw={},wireless=null,clients={}) {
 const interfaces=Array.isArray(raw.interface)?raw.interface:null;
 // A default route indicates an uplink, not verified Internet reachability.
 const uplinks=(interfaces||[]).filter(i=>i.interface!=='loopback' && i.up===true && (
  (Array.isArray(i.route)?i.route:[]).some(r=>r.target==='0.0.0.0'||r.target==='::') ||
  /^wan|^wwan|^modem|^cellular/i.test(i.interface||'')
 ));
 const names=[];
 const validWireless=wireless && typeof wireless==='object' && !Array.isArray(wireless);
 if(validWireless) Object.values(wireless).forEach(radio=>{
  if(!radio || radio.disabled===true || radio.disabled==='1' || radio.up===false) return;
  (radio.interfaces||[]).forEach(iface=>{const ssid=text(iface.config?.ssid),disabled=iface.config?.disabled; if(ssid && disabled!==true && disabled!==1 && disabled!=='1' && !names.includes(ssid)) names.push(ssid);});
 });
 return {connected:interfaces?uplinks.length>0:null,ssid:!validWireless||!Object.keys(wireless).length?null:names.length?names.join(' / '):'无线未启用',clients:clients.available===true?bounded(clients.count,0,100000):null};
}
function metrics(raw={},previous=null) {
 const total=number(raw?.cpu?.total),idle=number(raw?.cpu?.idle);
 const oldTotal=number(previous?.total),oldIdle=number(previous?.idle);
 const valid=total!==null&&idle!==null&&total>=0&&idle>=0&&idle<=total;
 const elapsed=valid&&oldTotal!==null?total-oldTotal:0;
 const idleDelta=valid&&oldIdle!==null?idle-oldIdle:-1;
 const cpuPercent=elapsed>0&&idleDelta>=0&&idleDelta<=elapsed?100*(elapsed-idleDelta)/elapsed:null;
 const count=number(raw?.connections?.count),limit=number(raw?.connections?.limit);
 const validCount=count!==null&&Number.isSafeInteger(count)&&count>=0?count:null;
 const validLimit=limit!==null&&Number.isSafeInteger(limit)&&limit>0?limit:null;
 return { cpuPercent, cpu:valid?{total,idle}:null, count:validCount, limit:validLimit,
  connectionPercent:validCount!==null&&validLimit!==null?Math.min(100,100*validCount/validLimit):null };
}
function uptime(seconds) {
 const n=number(seconds);
 if(n===null||n<0) return '—';
 const d=Math.floor(n/86400),h=Math.floor(n/3600)%24,m=Math.floor(n/60)%60;
 return (d?d+' 天 ':'')+(h?h+' 小时 ': '')+m+' 分钟';
}
return Object.freeze({number,measured,bounded,resources,systemSnapshot,hardware,modem,modemSnapshot,network,metrics,uptime});
});
