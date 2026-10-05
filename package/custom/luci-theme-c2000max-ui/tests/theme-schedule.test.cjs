const assert=require('node:assert/strict'),fs=require('node:fs'),path=require('node:path'),vm=require('node:vm');
const source=fs.readFileSync(path.join(__dirname,'../htdocs/luci-static/c2000max-ui/theme.js'),'utf8');
function boot(iso,storage=new Map()){
 let now=Date.parse(iso);const docEvents={},winEvents={},timers=[];
 class Clock extends Date {static now(){return now;}}
 const document={documentElement:{dataset:{}},querySelectorAll:()=>[],querySelector:()=>null,addEventListener:(n,f)=>docEvents[n]=f,dispatchEvent:()=>{},hidden:false};
 const window={addEventListener:(n,f)=>winEvents[n]=f};
 vm.runInNewContext(source,{Date:Clock,document,window,matchMedia:()=>({matches:false,addEventListener(){}}),localStorage:{getItem:k=>storage.get(k)??null,setItem:(k,v)=>storage.set(k,v)},setInterval:f=>timers.push(f),CustomEvent:class{constructor(n,o){this.type=n;this.detail=o.detail;}}});
 return {api:window.C2000Theme,storage,tick:iso=>{now=Date.parse(iso);timers.forEach(f=>f());},storageEvent:key=>winEvents.storage({key}),resume:iso=>{now=Date.parse(iso);docEvents.visibilitychange();}};
}
const key='c2000max-device-art',flag='c2000max-national-day-2026-override';
let map=new Map([[key,'mid-autumn']]),a=boot('2026-09-30T15:59:59Z',map);assert.equal(a.api.getSkin(),'mid-autumn');a.tick('2026-09-30T16:00:00Z');assert.equal(a.api.getSkin(),'national-day');assert.equal(map.get(key),'mid-autumn');assert.equal(map.has(flag),false);
a.tick('2026-10-03T15:59:59Z');assert.equal(a.api.getSkin(),'national-day');a.tick('2026-10-03T16:00:00Z');assert.equal(a.api.getSkin(),'mid-autumn');
a=boot('2026-10-02T00:00:00Z',map);a.api.setSkin('788');assert.equal(a.api.getSkin(),'788');assert.equal(map.get(flag),'1');a.tick('2026-10-03T00:00:00Z');assert.equal(a.api.getSkin(),'788');assert.equal(boot('2026-10-02T01:00:00Z',map).api.getSkin(),'788');assert.equal(boot('2026-10-04T00:00:00Z',map).api.getSkin(),'788');
a=boot('2026-09-30T10:00:00Z');a.api.setSkin('max');assert.equal(a.storage.has(flag),false);a.resume('2026-10-01T00:00:00Z');assert.equal(a.api.getSkin(),'national-day');a.api.set('dark');assert.equal(a.storage.has(flag),false);
a.storage.set(flag,'1');a.storage.set(key,'max');a.storageEvent(flag);assert.equal(a.api.getSkin(),'max');a.storage.clear();a.storageEvent(null);assert.equal(a.api.getSkin(),'national-day');assert.equal(boot('2027-10-01T00:00:00Z').api.getSkin(),'max');
console.log('PASS Beijing holiday boundaries, prior preference, manual override, reload, expiry, resumed tab, cross-tab and 2027 exclusion');
