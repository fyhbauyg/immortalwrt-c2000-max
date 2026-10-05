const {spawn,spawnSync}=require('node:child_process'),fs=require('node:fs'),path=require('node:path');
const root=path.join(__dirname,'..');
function run(file){
 const result=spawnSync(process.execPath,[file],{cwd:root,env:process.env,stdio:'inherit'});
 if(result.error)throw result.error;
 if(result.status!==0)throw new Error(file+' failed');
}
(async()=>{
 for(const name of ['dashboard.html','login.html'])if(!fs.existsSync(path.join(root,'build/preview',name)))throw new Error('Render templates with tools/validate-templates.sh first. See README.md.');
 run('tests/data.test.cjs');
 const server=spawn(process.execPath,['tools/preview.cjs'],{cwd:root,env:{...process.env,PREVIEW_FETCH_WALLPAPER:'0'},stdio:['ignore','pipe','inherit']});
 try {
  await new Promise((resolve,reject)=>{
   const timer=setTimeout(()=>reject(new Error('Preview server did not start')),10000);
   server.once('error',e=>{clearTimeout(timer);reject(e);});
   server.once('exit',code=>{clearTimeout(timer);reject(new Error('Preview server exited: '+code));});
   server.stdout.on('data',data=>{if(data.toString().includes('http://127.0.0.1:4179/')){clearTimeout(timer);resolve();}});
  });
  for(const file of ['browser','view','status-layout','resource-layout','wallpaper','progress-animation'])run('tests/'+file+'.test.cjs');
 } finally {server.kill();}
})().catch(e=>{console.error(e.message);process.exitCode=1;});
