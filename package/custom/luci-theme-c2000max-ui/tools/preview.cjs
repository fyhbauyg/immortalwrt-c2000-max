const http=require('node:http'),fs=require('node:fs/promises'),path=require('node:path');
const root=path.join(__dirname,'..'),preview=path.join(root,'build/preview');
const types={'.css':'text/css; charset=utf-8','.js':'text/javascript; charset=utf-8','.json':'application/json','.png':'image/png','.jpg':'image/jpeg','.svg':'image/svg+xml','.html':'text/html; charset=utf-8'};
let bing=null;
async function wallpaper(){
 try {
  const res=await fetch('https://www.bing.com/HPImageArchive.aspx?format=js&idx=0&n=1&mkt=zh-CN',{signal:AbortSignal.timeout(10000)});
  const item=(await res.json()).images[0];
  if(!item.url.startsWith('/th?id=OHR.'))throw Error('Unexpected Bing URL');
  const image=await fetch('https://www.bing.com'+item.url,{signal:AbortSignal.timeout(20000)});
  const data=Buffer.from(await image.arrayBuffer());
  await fs.writeFile(path.join(preview,'bing.jpg'),data);
  bing=item;console.log('Bing wallpaper loaded: '+item.startdate);
 } catch(e){console.log('Wallpaper fallback: '+e.message);}
}
const esc=s=>String(s).replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
http.createServer(async(req,res)=>{
 const url=new URL(req.url,'http://127.0.0.1');
 if(req.method!=='GET'&&req.method!=='HEAD'){res.writeHead(405).end('Preview is read only');return;}
 try {
  let relative=decodeURIComponent(url.pathname),file;
  if(relative==='/'||relative==='/cgi-bin/luci/admin/status/c2000max')file=path.join(preview,'dashboard.html');
  else if(relative==='/login'||relative==='/cgi-bin/luci/admin/logout')file=path.join(preview,'login.html');
  else if(relative==='/login-error')file=path.join(preview,'login-error.html');
  else if(relative==='/preview-runtime.js')file=path.join(root,'tests/preview-runtime.js');
  else if(relative==='/fixture.json')file=path.join(preview,'fixture.json');
  else if(relative==='/bing.jpg')file=path.join(preview,'bing.jpg');
  else if(relative.startsWith('/luci-static/bootstrap/'))file=path.join(preview,'bootstrap',relative.slice(23));
  else if(relative.startsWith('/luci-static/c2000max-ui/'))file=path.join(root,'htdocs',relative);
  else if(relative==='/luci-static/resources/cbi.js'||relative.startsWith('/cgi-bin/luci/admin/translations/')) {res.writeHead(200,{'Content-Type':'text/javascript'}).end('/* preview runtime */');return;}
  else if(relative==='/forms')file=path.join(preview,'forms.html');
  else if(relative.startsWith('/cgi-bin/luci/')){
   res.writeHead(200,{'Content-Type':'text/html; charset=utf-8'}).end('<meta name="viewport" content="width=device-width"><title>LuCI 页面入口</title><body style="font:16px/1.8 system-ui;padding:40px;max-width:720px;margin:auto"><h1>'+esc(relative.includes('wireless')?'无线':relative.includes('qmodem')?'QModem 模组详情':'LuCI 页面')+'</h1><p>主题已跳转到设备上的实际 LuCI 路径：</p><code>'+esc(relative)+'</code><p>安装到路由器后，此处显示该页面或插件的实际内容。</p><a href="/">返回首页预览</a></body>');return;
  } else {res.writeHead(404).end();return;}
  file=path.resolve(file);
  if(!file.startsWith(path.resolve(root)+path.sep)){res.writeHead(403).end();return;}
  let data=await fs.readFile(file);
  if(file.endsWith('login.html')||file.endsWith('login-error.html')){
   let html=data.toString();
   if(bing)html=html.replace('<body class="login-page">','<body class="login-page"><img class="login-wallpaper" src="/bing.jpg" alt="">')
    .replace('<span>C2000MAX · Always Connected</span>','<span>Bing 每日壁纸 · '+esc(bing.copyright)+'</span>');
   html=html.replace('</body>','<script>document.querySelector("form").addEventListener("submit",e=>{e.preventDefault(); let p=document.querySelector(".preview-login-note");if(!p){p=document.createElement("p");p.className="login-error preview-login-note";p.setAttribute("role","status");e.target.append(p);}p.textContent="这是外观预览，登录请在设备上操作。";});</script></body>');
   data=Buffer.from(html);
  }
  res.writeHead(200,{'Content-Type':types[path.extname(file)]||'application/octet-stream','Cache-Control':'no-store'});
  res.end(req.method==='HEAD'?undefined:data);
 }catch(e){res.writeHead(404).end('Not found');}
}).listen(4179,'127.0.0.1',()=>{console.log('C2000MAX theme preview http://127.0.0.1:4179/ — login /login');if(process.env.PREVIEW_FETCH_WALLPAPER!=='0')wallpaper();});
