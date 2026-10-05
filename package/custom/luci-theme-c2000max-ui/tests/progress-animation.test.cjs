const assert=require('node:assert/strict'),fs=require('node:fs'),path=require('node:path');
const {chromium}=require('playwright');
const fixture=JSON.parse(fs.readFileSync(path.join(__dirname,'../build/preview/fixture.json')));
(async()=>{
 const browser=await chromium.launch({channel:process.env.PLAYWRIGHT_CHANNEL,headless:true});
 try{
  for(const motion of ['no-preference','reduce']){
   const p=await browser.newPage({reducedMotion:motion,viewport:{width:1440,height:1200}});
   await p.route('**/fixture.json',r=>r.fulfill({json:{}}));
   await p.goto('http://127.0.0.1:4179/');await p.waitForFunction(()=>window.previewDashboard);
   const widths=()=>p.locator('.resource-card .ui-progress > i').evaluateAll(items=>items.map(e=>e.getBoundingClientRect().width));
   assert.deepEqual(await widths(),[0,0,0,0]);
   await p.evaluate(()=>new Promise(resolve=>requestAnimationFrame(()=>requestAnimationFrame(resolve))));
   await p.evaluate(data=>previewDashboard.update(data),fixture);
   const background=await p.locator('#ram-bar').evaluate(e=>({color:getComputedStyle(e).backgroundColor,freeColor:getComputedStyle(document.querySelector('.legend-free')).backgroundColor,width:e.getBoundingClientRect().width}));
   assert.equal(background.color,background.freeColor,'free RAM is a static background');
   assert.equal(await p.locator('#ram-free-bar').count(),0,'free RAM has no animated fill');
   await p.waitForTimeout(100);
   const middle=await widths();
   await p.waitForTimeout(700);
   const final=await widths();
   assert.equal(await p.locator('#ram-bar').evaluate(e=>e.getBoundingClientRect().width),background.width,'the background is full width throughout the animation');
   final.forEach((v,i)=>assert.ok(v>0,'data fills bar '+i));
   if(motion==='reduce')assert.deepEqual(middle,final);
   else middle.forEach((v,i)=>assert.ok(v>0&&v<final[i],'initial fill animates '+i+' '+JSON.stringify({middle,final})));
   const updated=structuredClone(fixture);updated.system.root.used=updated.system.root.total*.8;
   await p.evaluate(data=>previewDashboard.update(data),updated);
   await p.waitForTimeout(100);
   const changed=await widths();
   await p.waitForTimeout(700);
   const end=await widths();
   if(motion==='no-preference')assert.ok(changed[2]>final[2]&&changed[2]<end[2]);
   else assert.equal(changed[2],end[2]);
   await p.close();
  }
  console.log('PASS: used RAM, rootfs and swap animate; free RAM stays a full-width background; reduced motion applies immediately');
 } finally {await browser.close();}
})().catch(e=>{console.error(e);process.exitCode=1;});
