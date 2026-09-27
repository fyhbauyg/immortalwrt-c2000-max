assert(loadfile('/tmp/c2000-acc-controller.lua'))
local files={['/tmp/acc/acc_core_conf.json']='{"acceleration":[{"PC":{"state":1}},{"Phone":{"state":3}}]}'}
package.preload['luci.util']=function()return {exec=function()return 'worker' end}end
package.preload['luci.model.uci']=function()return {cursor=function()return {}end}end
package.preload['nixio.fs']=function()return {readfile=function(p)return files[p]end}end
local response
luci={http={prepare_content=function()end,write_json=function(r)response=r end}}
dofile('/tmp/c2000-acc-controller.lua')
package.loaded['luci.controller.acc'].get_acc_status()
assert(response.state['电脑设备']=='已开始加速')
assert(response.state['手机设备']=='加速已暂停')
assert(response.state['游戏主机']=='未加速')
print('PASS: LuCI reads current engine acceleration status')
