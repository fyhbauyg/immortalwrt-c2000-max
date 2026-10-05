const assert=require('node:assert/strict'),fs=require('node:fs'),path=require('node:path'),http=require('node:http');
const {chromium}=require('playwright');
const root=path.join(__dirname,'..'),asset=path.join(root,'htdocs/luci-static/c2000max-ui');
let mode='offline',metadataCalls=0;
const server=http.createServer((req,res)=>{
 const url=new URL(req.url,'http://localhost');
 if(url.pathname==='/cgi-bin/c2000max-wallpaper'){
  if(url.search==='?info'){
   metadataCalls++;
   if(mode==='offline'){res.writeHead(503).end();return;}
   res.writeHead(200,{'Content-Type':'application/json'}).end(JSON.stringify({date:mode==='broken'?'20260928':'20260927',copyright:'Test credit <script>unsafe</script>'}));return;
  }
  if(mode==='broken'){res.writeHead(502).end();return;}
  res.writeHead(200,{'Content-Type':'image/jpeg'}).end(fs.readFileSync(path.join(asset,'wallpaper/default.jpg')));return;
 }
 if(url.pathname==='/'){
  res.writeHead(200,{'Content-Type':'text/html; charset=utf-8'}).end(fs.readFileSync(path.join(root,'build/preview/login.html')));return;
 }
 if(url.pathname.startsWith('/luci-static/c2000max-ui/')){
  const file=path.join(asset,url.pathname.slice('/luci-static/c2000max-ui/'.length));
  const type={'.js':'application/javascript','.css':'text/css','.jpg':'image/jpeg'}[path.extname(file)]||'application/octet-stream';
  res.writeHead(200,{'Content-Type':type}).end(fs.readFileSync(file));return;
 }
 res.writeHead(404).end();
});
(async()=>{
 await new Promise(r=>server.listen(0,'127.0.0.1',r));
 const browser=await chromium.launch({channel:process.env.PLAYWRIGHT_CHANNEL,headless:true});
 try{
  const p=await browser.newPage({viewport:{width:1440,height:900}}),errors=[];
  p.on('pageerror',e=>errors.push(e.message));
  await p.goto('http://127.0.0.1:'+server.address().port);
  await p.waitForFunction(()=>document.querySelector('.login-wallpaper')?.naturalWidth===1920);
  assert.equal(await p.locator('.login-wallpaper').count(),1);
  assert.match(await p.locator('.login-wallpaper').getAttribute('src'),/default.jpg$/);
  await p.locator('#luci_password').fill('test-unsent-password');
  await p.screenshot({path:path.join(root,'build/preview/wallpaper-offline.png')});
  mode='online';
  await p.evaluate(()=>window.dispatchEvent(new Event('online')));
  await p.waitForFunction(()=>document.querySelector('.login-wallpaper').dataset.date==='20260927');
  assert.equal(await p.locator('#luci_password').inputValue(),'test-unsent-password');
  assert.equal(await p.locator('.wallpaper-credit script').count(),0);
  assert.match(await p.locator('.wallpaper-credit').textContent(),/<script>unsafe<\/script>/);
  const before=await p.locator('.login-wallpaper').getAttribute('src');
  mode='broken';
  await p.evaluate(()=>window.dispatchEvent(new Event('online')));
  await p.waitForTimeout(200);
  assert.equal(await p.locator('.login-wallpaper').getAttribute('src'),before,'failed refresh retains loaded image');
  assert.equal(await p.locator('.login-wallpaper').evaluate(e=>e.naturalWidth),1920);
  assert.deepEqual(errors,[]);
  assert.ok(metadataCalls>=3);
  console.log('PASS: bundled wallpaper with WAN unavailable, reconnect refresh, failed refresh preserves image, credits escaped, login input preserved');
 } finally {await browser.close();server.close();}
})().catch(e=>{console.error(e);server.close();process.exitCode=1;});
