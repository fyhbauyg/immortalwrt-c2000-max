import { readfile, writefile, mkdir } from 'fs';
const base = ARGV[0];
const out = ARGV[1];
function encode(value) {
 return replace(''+(value ?? ''), /[&<>"']/g, c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
}
let scope = {
 media:'/luci-static/c2000max-ui',resource:'/luci-static/resources',
 dispatcher:{lang:'zh-CN',build_url:(...path)=>'/cgi-bin/luci/'+join('/',path)},
 http:{prepare_content:()=>{},getenv:(name)=>name=='REQUEST_URI'?'/cgi-bin/luci/admin/status/c2000max':null},
 ubus:{call:()=>({hostname:'C2000MAX',rootfs_type:'squashfs',release:{description:'ImmortalWrt 25.12-SNAPSHOT by inst.'}})},uci:{get:()=>[]},
 entityencode:encode,_:v=>v,node:{title:'C2000MAX 首页'},css:null,blank_page:false,
 ctx:{authsession:'test',request_path:['admin','status','c2000max']},
 version:{distname:'ImmortalWrt',distversion:'25.12-SNAPSHOT',luciname:'LuCI c2000max-v37.01 branch',luciversion:'26.248.12024~e9cdc0a'},duser:'root',fuser:null,auth_message:null
};
scope.include = function(name) { print(render(base+'/ucode/template/'+name+'.ut',scope)); };
let header=render(base+'/ucode/template/themes/c2000max-ui/header.ut',scope);
let footer=render(base+'/ucode/template/themes/c2000max-ui/footer.ut',scope);
const harness='<script src="/preview-runtime.js"></script>';
writefile(out+'/dashboard.html',replace(header,'</head>',harness+'</head>')+
'<div id="view">'+replace(readfile(base+'/htdocs/luci-static/c2000max-ui/dashboard.html'),'src="assets/','src="/luci-static/c2000max-ui/assets/')+'</div>'+footer);
writefile(out+'/login.html',render(base+'/ucode/template/themes/c2000max-ui/sysauth.ut',scope));
scope.fuser='root';scope.duser='"><script>alert(1)</script>';scope.auth_message='<bad>';
writefile(out+'/login-error.html',render(base+'/ucode/template/themes/c2000max-ui/sysauth.ut',scope));
print('Rendered header, footer, includes and login templates with the target ucode version.\n');
