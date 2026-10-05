// Fixture-only runtime for desktop review. Not installed on the router.
window._=s=>s;
const menu={children:{admin:{children:{
 status:{title:'状态',name:'status',order:10,children:{c2000max:{title:'C2000MAX 首页',name:'c2000max'},overview:{title:'概览',name:'overview'}}},
 system:{title:'系统',name:'system',order:20,children:{system:{title:'系统',name:'system'},admin:{title:'管理权',name:'admin'},flash:{title:'备份与升级',name:'flash'},software:{title:'软件包',name:'software'}}},
 modem:{title:'调制解调器',name:'modem',order:30,children:{qmodem:{title:'QModem',name:'qmodem',children:{overview:{title:'模组信息',name:'overview'},sms:{title:'短信',name:'sms'}}}}},
 services:{title:'服务',name:'services',order:40,children:{openclash:{title:'OpenClash',name:'openclash'}}},
 network:{title:'网络',name:'network',order:50,children:{network:{title:'接口',name:'network'},wireless:{title:'无线',name:'wireless'},firewall:{title:'防火墙',name:'firewall'}}},
 statistics:{title:'统计',name:'statistics',order:60,children:{graph:{title:'图表',name:'graph'}}}
}}}};
window.L={url:(...p)=>'/cgi-bin/luci/'+p.join('/'),env:{dispatchpath:['admin','status','c2000max']},require:async()=>({menu:{load:async()=>menu,getChildren:n=>Object.values(n?.children||{}).sort((a,b)=>(a.order||0)-(b.order||0))}})};
document.addEventListener('DOMContentLoaded',async()=>{
 const root=document.querySelector('.dashboard');
 if(!root)return;
 root.querySelectorAll('img[src^="assets/"]').forEach(img=>img.src='/luci-static/c2000max-ui/'+img.getAttribute('src'));
 const dashboard=C2000Dashboard.mount(root,L.url);
 const fixture=await fetch('/fixture.json').then(r=>r.json());
 dashboard.update(fixture);
 window.previewDashboard=dashboard;
});
