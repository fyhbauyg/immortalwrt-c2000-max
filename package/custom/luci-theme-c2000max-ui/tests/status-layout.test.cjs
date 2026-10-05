const assert=require('node:assert/strict'),fs=require('node:fs'),path=require('node:path');
const {chromium}=require('playwright');
const fixture=require('./data.test.cjs');
const out=path.join(__dirname,'../build/preview/aligned-status-20261005');
fs.mkdirSync(out,{recursive:true});
(async()=>{
 const b=await chromium.launch({channel:process.env.PLAYWRIGHT_CHANNEL,headless:true});
 const p=await b.newPage(),errors=[];
 p.on('pageerror',e=>errors.push(e.message));
 try {
  await p.setViewportSize({width:1302,height:1089});
  await p.goto('http://127.0.0.1:4179/');
  await p.waitForFunction(()=>window.previewDashboard);
  await p.evaluate(f=>{
   C2000Theme.set('dark');
   previewDashboard.update(f);
   const updated={...f,metrics:{...f.metrics,cpu:{total:2000,idle:1330}}};
   previewDashboard.update(updated);
   previewDashboard.update({...updated,system:{...f.system}});
  },fixture);
  assert.equal(await p.locator('#cpu-usage-value').textContent(),'37%','unrelated updates must retain the CPU sample');
  assert.equal(await p.locator('#connections-value').textContent(),'666');
  assert.equal(await p.locator('#cpu-usage-ring').getAttribute('aria-valuenow'),'37');
  assert.equal(await p.locator('#connections-ring').getAttribute('aria-valuenow'),'2');
  const compact=await p.evaluate(()=>{
   const card=document.querySelector('.system-status-card'),previous=card.previousElementSibling;
   return {inMetrics:card.parentElement.classList.contains('metrics'),afterBand:previous.classList.contains('carrier-metric'),width:card.offsetWidth,height:card.offsetHeight,ring:document.querySelector('.status-ring').offsetWidth};
  });
  assert.ok(compact.inMetrics&&compact.afterBand,'gauges must follow band aggregation in the radio column');
  assert.ok(compact.width<=270&&compact.height<=160&&compact.ring<=60,'gauges must stay compact');
  assert.equal(await p.locator('#system-status-title .ui-badge').count(),0,'remove the realtime badge');
  for(const theme of ['light','dark'])for(const skin of ['max','788']){
   await p.evaluate(({theme,skin})=>{C2000Theme.set(theme);C2000Theme.setSkin(skin);},{theme,skin});
   for(const width of [861,1302,1484,1920]){
    await p.setViewportSize({width,height:1089});
    const layout=await p.evaluate(()=>{
     const cards=[...document.querySelectorAll('.metrics > .metric')];
     const wifi=document.querySelector('.quick-card').getBoundingClientRect();
     const style=e=>{const s=getComputedStyle(e);return {color:s.color,font:s.fontSize,weight:s.fontWeight,border:s.borderLeft,padding:s.paddingLeft};};
     const carrier=document.querySelector('.carrier-metric .radio-card-values');
     const system=document.querySelector('.system-status-grid');
     return {count:cards.length,top:cards[0].getBoundingClientRect().top,wifiTop:wifi.top,
      dividers:[carrier,system].map(e=>({x:e.children[1].getBoundingClientRect().x,...style(e.children[1])})),
      labels:[carrier,system].map(e=>style(e.querySelector('.stat-label'))),
      above:[...system.children].every(e=>e.querySelector('.stat-label').getBoundingClientRect().bottom<=e.querySelector('.status-ring').getBoundingClientRect().top),
      labelsAligned:[...system.children].every((e,i)=>Math.abs(e.querySelector('.stat-label').getBoundingClientRect().x-carrier.children[i].querySelector('.stat-label').getBoundingClientRect().x)<1),
      balanced:(()=>{const left=system.children[0].querySelector('.status-ring').getBoundingClientRect(),right=system.children[1].querySelector('.status-ring').getBoundingClientRect(),divider=system.children[1].getBoundingClientRect().x;return Math.abs((divider-left.x-left.width/2)-(right.x+right.width/2-divider))<1;})()};
    });
    assert.equal(layout.count,4);
    if(width>=1280)assert.ok(Math.abs(layout.top-layout.wifiTop)<1,'radio column must align with Wi-Fi at '+width);
    assert.deepEqual(layout.dividers[0],layout.dividers[1],'same divider position and style');
    assert.deepEqual(layout.labels[0],layout.labels[1],'same value label style');
    assert.ok(layout.above,'labels must appear above the gauges');
    assert.ok(layout.labelsAligned,'labels must stay left-aligned with the frequency card');
    assert.ok(layout.balanced,'gauges must have symmetric spacing around the divider');
   }
   const colors=[];
   for(const mnc of ['00','01','00']){
    await p.evaluate(({f,mnc})=>previewDashboard.update({...f,metrics:{...f.metrics,cpu:{total:2000,idle:1330}},modem:{...f.modem,sources:f.modem.sources.map(s=>({...s,entries:s.entries.map(e=>e.key==='MNC'?{...e,value:mnc}:e)}))}}),{f:fixture,mnc});
    colors.push(await p.locator('#network-generation').evaluate(e=>({text:e.textContent,color:getComputedStyle(e).color,background:getComputedStyle(e).backgroundColor})));
   }
   assert.equal(colors[0].text,'5G');assert.equal(colors[1].text,'5G-A');
   assert.notEqual(colors[0].color,colors[1].color,'5G-A must have a distinct text color');
   assert.notEqual(colors[0].background,colors[1].background,'5G-A must have a distinct background');
   assert.deepEqual(colors[0],colors[2],'normal 5G must restore its color after 5G-A');
  }
  await p.setViewportSize({width:1484,height:1089});
  await p.evaluate(f=>previewDashboard.update({...f,metrics:{...f.metrics,cpu:{total:3000,idle:1960}},modem:{...f.modem,sources:f.modem.sources.map(s=>({...s,entries:s.entries.map(e=>e.key==='MNC'?{...e,value:'01'}:e)}))}}),fixture);
  assert.equal(await p.locator('.modem-note').isVisible(),true,'missing SIM data must show the refresh hint');
  await p.screenshot({path:path.join(out,'dashboard-desktop.png'),fullPage:true});
  for(const width of [320,390,623,768]){
   await p.setViewportSize({width,height:844});
   assert.equal(await p.evaluate(()=>document.documentElement.scrollWidth>innerWidth+1),false,'gauge overflow at '+width);
   const boxes=await p.locator('.status-ring').evaluateAll(es=>es.map(e=>{const r=e.getBoundingClientRect();return {x:r.x,y:r.y,width:r.width,height:r.height}}));
   assert.ok(boxes[0].x+boxes[0].width<=boxes[1].x,'gauges overlap at '+width);
   if(width===390)await p.screenshot({path:path.join(out,'dashboard-mobile.png'),fullPage:true});
  }
  await p.evaluate(()=>previewDashboard.update({metrics:{}}));
  assert.equal(await p.locator('#cpu-usage-value').textContent(),'—');
  assert.equal(await p.locator('#connections-value').textContent(),'—');
  assert.equal(await p.locator('#cpu-usage-ring').getAttribute('aria-valuenow'),null);
  const credit='Bing 每日壁纸 · '+('南极洲的阿德利企鹅与远处的海冰、绵延山脉以及野生动物保护区 · ').repeat(12)+'(© Otto Plantema/Minden Pictures)';
  let layouts=0;
  for(const theme of ['light','dark'])for(const [width,height] of [[320,568],[390,844],[623,871],[844,390],[1440,1000]]){
   await p.setViewportSize({width,height});
   await p.goto('http://127.0.0.1:4179/login');
   await p.evaluate(({theme,credit})=>{
    C2000Theme.set(theme);
    const a=document.querySelector('.wallpaper-credit a');a.querySelector('.wallpaper-credit-text').textContent=credit;a.title=credit;
   },{theme,credit});
   const layout=await p.evaluate(()=>{
    const card=document.querySelector('.login-card').getBoundingClientRect();
    const footer=document.querySelector('.wallpaper-credit').getBoundingClientRect();
    const a=document.querySelector('.wallpaper-credit-text'),r=a.getBoundingClientRect(),s=getComputedStyle(a);
    return {overlap:footer.top<card.bottom,overflow:document.documentElement.scrollWidth>innerWidth+1,
     lines:(r.height-parseFloat(s.paddingTop)-parseFloat(s.paddingBottom))/parseFloat(s.lineHeight)};
   });
   assert.equal(layout.overlap,false,'long credit overlaps login '+width+'x'+height);
   assert.equal(layout.overflow,false,'long credit overflows viewport '+width);
   if(width<=700)assert.ok(layout.lines<=2.1,'phone credit exceeds two lines');
   if(theme==='dark'&&width===390)await p.screenshot({path:path.join(out,'login-mobile-long-credit.png'),fullPage:true});
   layouts++;
  }
  assert.deepEqual(errors,[]);
  console.log('PASS: aligned cards, left-aligned labels and symmetric gauges at four desktop/tablet widths in four appearances, 5G-A color transitions, live gauges, four mobile widths, and '+layouts+' long-credit login layouts');
 } finally {await b.close();}
})().catch(e=>{console.error(e);process.exit(1)});
