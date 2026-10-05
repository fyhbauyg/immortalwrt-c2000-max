const assert=require('node:assert/strict'),fs=require('node:fs'),path=require('node:path');
const {chromium}=require('playwright');
const out=path.join(__dirname,'../build/preview/resource-layout');
fs.mkdirSync(out,{recursive:true});
(async()=>{
 const browser=await chromium.launch({channel:process.env.PLAYWRIGHT_CHANNEL,headless:true});
 try{
  const p=await browser.newPage(),errors=[];
  p.on('pageerror',e=>errors.push(e.message));
  await p.goto('http://127.0.0.1:4179/');await p.waitForFunction(()=>window.previewDashboard);
  await p.evaluate(()=>C2000Theme.setSkin('max'));
  for(const theme of ['light','dark']){
   await p.evaluate(t=>C2000Theme.set(t),theme);
   for(const width of [320,390,412,623,700,701,768,820,861,1024,1100,1279,1280,1484]){
    await p.setViewportSize({width,height:1180});
    const layout=await p.evaluate(()=>{
     const rect=s=>document.querySelector(s).getBoundingClientRect();
     const style=e=>{const s=getComputedStyle(e);return {font:s.font,color:s.color,lineHeight:s.lineHeight};};
     const card=rect('.resource-card'),header=rect('.resource-header'),icon=rect('.resource-header .ui-icon-box'),title=rect('#resource-title');
     const modem=rect('.modem-card'),thermal=rect('.thermal-card');
     return {overflow:document.documentElement.scrollWidth>innerWidth+1,iconWidth:icon.width,iconHeight:icon.height,topGap:header.top-card.top,
      titleFits:title.right<=card.right&&title.top>=card.top,modem:{top:modem.top,height:modem.height},thermal:{top:thermal.top,height:thermal.height},
      labels:[...document.querySelectorAll('.carrier-metric .stat-label,.system-status-card .stat-label')].map(style)};
    });
    assert.equal(layout.overflow,false,`${theme} overflow at ${width}`);
    assert.ok(layout.iconWidth>0&&layout.iconHeight>0,'memory icon visible at '+width);
    assert.ok(layout.titleFits,'memory title stays inside card at '+width);
    if(width<=700)assert.ok(layout.topGap>=19,'phone header has comfortable top padding at '+width);
    layout.labels.forEach(label=>assert.deepEqual(label,layout.labels[0],'radio and system labels share typography at '+width));
    if(width>=701&&width<=1279){
     assert.ok(Math.abs(layout.modem.top-layout.thermal.top)<1,'tablet cards share a row at '+width);
     assert.ok(Math.abs(layout.modem.height-layout.thermal.height)<1,'tablet temperature card matches modem height at '+width);
    }
    if(theme==='dark'&&width===412)await p.locator('.resource-card').screenshot({path:path.join(out,'resource-mobile.png')});
    if(theme==='dark'&&width===820)await p.locator('.quick-access').screenshot({path:path.join(out,'quick-tablet.png')});
   }
  }
  assert.deepEqual(errors,[]);
  console.log('PASS: resource icon and phone spacing, shared metric typography, and equal tablet card heights across 28 layouts');
 }finally{await browser.close();}
})().catch(e=>{console.error(e);process.exitCode=1;});
