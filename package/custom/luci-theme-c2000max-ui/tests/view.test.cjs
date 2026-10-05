const fs=require('node:fs'),assert=require('node:assert/strict'),path=require('node:path');
const {chromium}=require('playwright');
(async()=>{
 const b=await chromium.launch({channel:process.env.PLAYWRIGHT_CHANNEL,headless:true}),p=await b.newPage();
 const code=fs.readFileSync(path.join(__dirname,'../htdocs/luci-static/resources/view/c2000max/home.js'),'utf8');
 const html=fs.readFileSync(path.join(__dirname,'../htdocs/luci-static/c2000max-ui/dashboard.html'),'utf8');
 const fixture=JSON.parse(fs.readFileSync(path.join(__dirname,'../build/preview/fixture.json')));
 const errors=[];p.on('pageerror',e=>errors.push(e.message));
 await p.goto('http://127.0.0.1:4179/');await p.waitForFunction(()=>window.previewDashboard);
 const result=await p.evaluate(async({code,html,fixture})=>{
  const seen=[],callbacks=[],declarations=[],systemReadings=[];
  let systemReply=fixture.system;
  L.resource=s=>'/luci-static/resources/'+s;L.env.media='/luci-static/c2000max-ui';L.env.resource_version='theme-updated';
  L.resolveDefault=(p,f)=>Promise.resolve(p).catch(()=>f);
  const data={'system.info':fixture.system,'network.interface.dump':fixture.network,'network.wireless.status':fixture.wireless,'c2000max.ui.clients':fixture.clients,'c2000max.ui.modem':fixture.modem};
  const rpc={declare:spec=>{declarations.push(spec);return (...args)=>{
   const name=spec.object+'.'+spec.method;seen.push({name,args});
   if(name==='system.info')return systemReply instanceof Error?Promise.reject(systemReply):Promise.resolve(systemReply);
   if(name==='c2000max.hardware_status'||name==='qmodem.base_info')return new Promise(()=>{}); // one optional plugin hangs
   if(name==='c2000max.ui.modem'&&seen.filter(v=>v.name===name).length>1)return Promise.reject(new Error('intermittent cache read failure'));
   return Promise.resolve(data[name]);
  };}};
  const uci={load:async()=>{},get:()=>fixture.config,sections:()=>[{'.name':'modem1',enabled:'1'}]};
  const poll={add:fn=>callbacks.push(fn),remove:()=>{}},request={get:async url=>{assertUrl=url;return {ok:true,text:()=>html};}};
  let assertUrl;
  const E=(tag,attrs)=>{const e=document.createElement(tag);Object.entries(attrs).forEach(([k,v])=>e.setAttribute(k,v));return e;};
  const view=new Function('view','rpc','uci','poll','request','E',code)({extend:o=>o},rpc,uci,poll,request,E);
  const root=view.render(await view.load());document.querySelector('#view').replaceChildren(root);
  await new Promise(r=>setTimeout(r,60));
  callbacks[0]();callbacks[0]();callbacks[2]();callbacks[2]();await new Promise(r=>setTimeout(r,60));
  const reading=()=>({ram:root.querySelector('#ram-percent').textContent,uptime:root.querySelector('#uptime-value').textContent,flash:root.querySelector('#flash-label').textContent,note:root.querySelector('#resource-note').textContent});
  const baseline=reading();
  for(const reply of [new Error('RPC timeout'),7,{}, {root:{...fixture.system.root,used:fixture.system.root.total*.6}}]){
   systemReply=reply;callbacks[0]();await new Promise(r=>setTimeout(r,30));systemReadings.push(reading());
  }
  systemReply={...fixture.system,uptime:fixture.system.uptime+120,memory:{...fixture.system.memory,available:200*1048576}};
  callbacks[0]();await new Promise(r=>setTimeout(r,30));
  return {seen,declarations,baseline,systemReadings,recovered:reading(),templateUrl:assertUrl,rsrp:root.querySelector('#nr-rsrp').textContent,ram:baseline.ram,temperature:root.querySelector('#cpu-temperature').textContent,hasSave:view.handleSaveApply!==null};
 },{code,html,fixture});
 assert.equal(result.rsrp,'−82');assert.equal(result.ram,'32%');assert.equal(result.temperature,'—');assert.equal(result.hasSave,false);
 for(const reading of result.systemReadings){
  assert.equal(reading.ram,result.baseline.ram,'system failure must preserve RAM');
  assert.equal(reading.uptime,result.baseline.uptime,'system failure must preserve uptime');
  assert.ok(reading.note.includes('最近有效读数'),'retained readings must indicate a delayed update');
 }
 assert.notEqual(result.systemReadings[3].flash,result.baseline.flash,'valid storage groups still update in partial replies');
 assert.equal(result.recovered.ram,'61%');
 assert.notEqual(result.recovered.uptime,result.baseline.uptime);
 assert.equal(result.recovered.note,'');
 const systemDecl=result.declarations.find(v=>v.object==='system'&&v.method==='info');
 assert.equal(systemDecl.nobatch,true);assert.equal(systemDecl.reject,true);
 assert.equal(result.templateUrl,'/luci-static/c2000max-ui/dashboard.html?v=theme-updated','template cache must follow the LuCI package version');
 assert.equal(result.seen.filter(v=>v.name==='c2000max.hardware_status').length,1,'hung plugin must not queue repeated calls');
 assert.ok(result.seen.some(v=>v.name==='c2000max.ui.modem'&&v.args[0]==='modem1'));
 assert.ok(result.seen.filter(v=>v.name==='c2000max.ui.modem').length>1,'test must exercise a failed refresh while retaining the earlier signal');
 assert.ok(!result.seen.some(v=>/set|exec|switch|dial|send_at/.test(v.name)),'home must not write');
 assert.equal(result.seen.filter(v=>v.name==='qmodem.cell_info').length,1,'concurrent polls must not duplicate serial reads');
 for(const spec of result.declarations.filter(v=>v.object==='qmodem'||v.method==='modem'||v.method==='metrics'))assert.equal(spec.nobatch,true,'modem work and CPU sampling must not block the fast RPC batch');
 assert.equal(result.seen.filter(v=>v.name==='qmodem.base_info').length,1,'slow temperature query must not queue or block cached dashboard');
 assert.deepEqual(errors,[]);await b.close();
 console.log('PASS: deployed LuCI view loads, polls independently, uses selected modem and avoids duplicate hung requests');
})().catch(e=>{console.error(e);process.exit(1)});
