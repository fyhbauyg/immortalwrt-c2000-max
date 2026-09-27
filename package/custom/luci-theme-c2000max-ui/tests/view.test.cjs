const fs=require('node:fs'),assert=require('node:assert/strict'),path=require('node:path');
const {chromium}=require('../../template-extracted/node_modules/playwright');
(async()=>{
 const b=await chromium.launch({channel:'msedge',headless:true}),p=await b.newPage();
 const code=fs.readFileSync(path.join(__dirname,'../htdocs/luci-static/resources/view/c2000max/home.js'),'utf8');
 const html=fs.readFileSync(path.join(__dirname,'../htdocs/luci-static/c2000max-ui/dashboard.html'),'utf8');
 const fixture=JSON.parse(fs.readFileSync(path.join(__dirname,'../build/preview/fixture.json')));
 const errors=[];p.on('pageerror',e=>errors.push(e.message));
 await p.goto('http://127.0.0.1:4179/');await p.waitForFunction(()=>window.previewDashboard);
 const result=await p.evaluate(async({code,html,fixture})=>{
  const seen=[],callbacks=[];
  L.resource=s=>'/luci-static/resources/'+s;L.env.media='/luci-static/c2000max-ui';
  L.resolveDefault=(p,f)=>Promise.resolve(p).catch(()=>f);
  const data={'system.info':fixture.system,'network.interface.dump':fixture.network,'network.wireless.status':fixture.wireless,'c2000max.ui.clients':fixture.clients,'c2000max.ui.modem':fixture.modem};
  const rpc={declare:spec=>(...args)=>{
   const name=spec.object+'.'+spec.method;seen.push({name,args});
   if(name==='c2000max.hardware_status'||name==='qmodem.base_info')return new Promise(()=>{}); // one optional plugin hangs
   return Promise.resolve(data[name]);
  }};
  const uci={load:async()=>{},get:()=>fixture.config,sections:()=>[{'.name':'modem1',enabled:'1'}]};
  const poll={add:fn=>callbacks.push(fn),remove:()=>{}},request={get:async()=>({ok:true,text:()=>html})};
  const E=(tag,attrs)=>{const e=document.createElement(tag);Object.entries(attrs).forEach(([k,v])=>e.setAttribute(k,v));return e;};
  const view=new Function('view','rpc','uci','poll','request','E',code)({extend:o=>o},rpc,uci,poll,request,E);
  const root=view.render(await view.load());document.querySelector('#view').replaceChildren(root);
  await new Promise(r=>setTimeout(r,60));
  callbacks[0]();callbacks[0]();await new Promise(r=>setTimeout(r,60));
  return {seen,rsrp:root.querySelector('#nr-rsrp').textContent,ram:root.querySelector('#ram-percent').textContent,temperature:root.querySelector('#cpu-temperature').textContent,hasSave:view.handleSaveApply!==null};
 },{code,html,fixture});
 assert.equal(result.rsrp,'−82');assert.equal(result.ram,'32%');assert.equal(result.temperature,'—');assert.equal(result.hasSave,false);
 assert.equal(result.seen.filter(v=>v.name==='c2000max.hardware_status').length,1,'hung plugin must not queue repeated calls');
 assert.ok(result.seen.some(v=>v.name==='c2000max.ui.modem'&&v.args[0]==='modem1'));
 assert.ok(!result.seen.some(v=>/set|exec|cell_info/.test(v.name)),'home must not write');
 assert.equal(result.seen.filter(v=>v.name==='qmodem.base_info').length,1,'slow temperature query must not queue or block cached dashboard');
 assert.deepEqual(errors,[]);await b.close();
 console.log('PASS: deployed LuCI view loads, polls independently, uses selected modem and avoids duplicate hung requests');
})().catch(e=>{console.error(e);process.exit(1)});
