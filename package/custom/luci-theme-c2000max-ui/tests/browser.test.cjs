const fs=require('node:fs'),path=require('node:path'),assert=require('node:assert/strict');
const {chromium}=require('playwright');
const root=path.join(__dirname,'..'),out=path.join(root,'build/preview');
const shell=fs.readFileSync(path.join(out,'dashboard.html'),'utf8');
const form=`<div class="cbi-map"><h2>无线网络</h2><div class="cbi-map-descr">LuCI 标准组件的外观预览</div><ul class="cbi-tabmenu"><li class="cbi-tab"><a href="#settings">常规设置</a></li><li class="cbi-tab-disabled"><a href="#security">无线安全</a></li></ul><section class="cbi-section"><h3>接口配置</h3>
<div class="cbi-value"><label class="cbi-value-title" for="ssid">网络名称</label><div class="cbi-value-field"><input id="ssid" value="C2000MAX_5G"><div class="cbi-value-description">允许设备发现的无线名称</div></div></div>
<div class="cbi-value"><label class="cbi-value-title" for="encryption">加密方式</label><div class="cbi-value-field"><select id="encryption"><option>WPA2/WPA3 混合模式</option>WPA3-SAE</option></select></div></div>
<div class="cbi-value"><label class="cbi-value-title" for="enabled">启用无线网络</label><div class="cbi-value-field"><label><input id="enabled" type="checkbox" checked>启用</label></div></div>
<div class="cbi-value"><label class="cbi-value-title" for="dns">DNS 服务器</label><div class="cbi-value-field"><div class="cbi-dynlist"><div class="item"><span>223.5.5.5</span></div><div class="add-item"><input id="dns" placeholder="添加 DNS"><button class="cbi-button">添加</button></div></div></div></div>
<div class="cbi-value cbi-value-error"><label class="cbi-value-title" for="invalid">IP 地址</label><div class="cbi-value-field"><input id="invalid" class="cbi-input-invalid" value="192.168." aria-invalid="true"><div class="cbi-value-description">请输入有效的 IPv4 地址</div></div></div></section>
<section class="cbi-section"><h3>已连接设备</h3><div class="table"><div class="tr"><div class="th">主机名</div><div class="th">IPv4 地址</div><div class="th">MAC 地址</div><div class="th">操作</div></div><div class="tr"><div class="td">C2000MAX client</div><div class="td">192.168.1.100</div><div class="td">AA:BB:CC:DD:EE:FF</div><div class="td"><button class="cbi-button">编辑</button><button class="cbi-button cbi-button-remove">移除</button></div></div></div></section>
<div class="alert-message warning"><h4>尚未保存的更改</h4><p>主题沿用 LuCI 的保存、应用和回滚机制。</p></div>
<div class="cbi-page-actions"><button class="cbi-button cbi-button-apply">保存并应用</button><button class="cbi-button cbi-button-save">保存</button><button class="cbi-button cbi-button-reset">重置</button></div></div>`;
fs.writeFileSync(path.join(out,'forms.html'),shell.split('<div id="view">')[0]+'<div id="view">'+form+'</div>'+shell.slice(shell.lastIndexOf('</div>\n<footer')));
(async()=>{
 const browser=await chromium.launch({channel:process.env.PLAYWRIGHT_CHANNEL,headless:true});
 const page=await browser.newPage();
 const errors=[];page.on('pageerror',e=>errors.push(e.message));
 let checks=0;
 for(const theme of ['light','dark'])for(const width of [320,390,646,768,1350,1622]){
  await page.setViewportSize({width,height:1000});
  for(const route of ['/','/login','/forms']){
   await page.goto('http://127.0.0.1:4179'+route);
   await page.evaluate(t=>C2000Theme.set(t),theme);
   if(route==='/')await page.waitForFunction(()=>document.querySelector('#nr-rsrp')?.textContent==='−82');
   const overflow=await page.evaluate(()=>document.documentElement.scrollWidth>innerWidth+1);
   assert.equal(overflow,false,'overflow '+route+' '+theme+' '+width);
   if(route==='/'||route==='/login'){
    const credit=page.locator(route==='/'?'.theme-credit':'.login-footer a');
    assert.equal(await credit.getAttribute('href'),'https://github.com/jasonBrom/C2000MAX-UI');
    assert.equal(await credit.getAttribute('target'),'_blank');
    assert.match(await credit.getAttribute('rel'),/noopener/);
   }
   if(route==='/login'){
    assert.equal(await page.locator('form').getAttribute('method'),'post');
    const b=await page.locator('.login-card').boundingBox();
    assert.ok(Math.abs(b.x+b.width/2-width/2)<2,'login horizontal center');
    if(width>=768)assert.ok(Math.abs(b.y+b.height/2-500)<25,'login vertical center');
   }
   checks++;
  }
 }
 await page.setViewportSize({width:1350,height:1000});await page.goto('http://127.0.0.1:4179/');
 await page.waitForFunction(()=>window.previewDashboard);
 assert.ok((await page.locator('.quick-card').first().getAttribute('href')).endsWith('/admin/network/wireless'));
 assert.ok((await page.getByText('查看模组详情').getAttribute('href')).endsWith('/admin/modem/qmodem'));
 await page.getByRole('button',{name:'管理员菜单'}).click();await page.getByRole('button',{name:'退出登录',exact:true}).click();await page.waitForURL('**/admin/logout');
 await page.getByRole('button',{name:'显示密码'}).click();assert.equal(await page.locator('#luci_password').getAttribute('type'),'text');
 await page.getByRole('button',{name:'隐藏密码'}).click();
 await page.goto('http://127.0.0.1:4179/login-error');assert.equal(await page.locator('#luci_username').inputValue(),'"><script>alert(1)</script>');
 assert.ok(await page.getByRole('alert').count());
 await page.setViewportSize({width:390,height:844});await page.goto('http://127.0.0.1:4179/');
 await page.waitForFunction(()=>window.previewDashboard);
 await page.getByRole('button',{name:'打开完整菜单'}).click();assert.equal(await page.locator('#sidebar').getAttribute('aria-modal'),'true');
 await page.getByRole('searchbox',{name:'搜索菜单或插件'}).fill('QModem');assert.equal(await page.getByRole('link',{name:'QModem',exact:true}).isVisible(),false); // navigable child tree uses category
 assert.ok(await page.locator('.menu-category').filter({hasText:'QModem'}).isVisible());
 await page.keyboard.press('Escape'); // clear filter
 await page.keyboard.press('Escape');assert.equal(await page.locator('#sidebar').getAttribute('aria-modal'),null);
 await page.locator('[data-theme-toggle]').click();await page.getByRole('button',{name:'深色模式',exact:true}).click();assert.equal(await page.locator('html').getAttribute('data-theme'),'dark');
 await page.reload();assert.equal(await page.locator('html').getAttribute('data-theme'),'dark');
 await page.waitForFunction(()=>window.previewDashboard);await page.evaluate(()=>previewDashboard.update({}));
 assert.equal(await page.locator('#nr-rsrp').textContent(),'—');assert.equal(await page.locator('#modem-temperature').textContent(),'—');assert.equal(await page.locator('#thermal-status').textContent(),'未获取');assert.equal(await page.locator('#ram-percent').textContent(),'—');
 for(const item of [{route:'/',name:'dashboard-dark',width:1440,height:1100,theme:'dark'},{route:'/login',name:'login-dark',width:1440,height:1000,theme:'dark'},{route:'/login',name:'login-light',width:1440,height:1000,theme:'light'},{route:'/',name:'dashboard-mobile',width:390,height:844,theme:'dark'},{route:'/login',name:'login-mobile',width:390,height:844,theme:'light'},{route:'/forms',name:'forms-dark',width:1350,height:1100,theme:'dark'},{route:'/forms',name:'forms-mobile',width:390,height:844,theme:'light'}]){
  await page.setViewportSize({width:item.width,height:item.height});await page.goto('http://127.0.0.1:4179'+item.route);await page.evaluate(t=>C2000Theme.set(t),item.theme);
  if(item.route==='/')await page.waitForFunction(()=>window.previewDashboard);
  await page.screenshot({path:path.join(out,item.name+'.png'),fullPage:true});
 }
 assert.deepEqual(errors,[]);
 await browser.close();
 console.log('PASS: '+checks+' layouts; route links, login escaping, menu search/drawer, appearance persistence, empty plugin states; no browser errors.');
})().catch(e=>{console.error(e);process.exit(1);});
