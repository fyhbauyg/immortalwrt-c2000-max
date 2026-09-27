local file = '/tmp/c2000-leigod-ini.lua'
local content='[base]\nurl="https://example.test"\n\n[device]\n112233445566="7"\n\n[bind]\ntoken="preserve-me"\n'
local files={['/etc/config/accelerator.ini']=content}
package.preload['nixio.fs']=function()return {
 readfile=function(p)return files[p]end,
 writefile=function(p,s)files[p]=s;return true end,
 chmod=function()return true end,
 rename=function(a,b)files[b]=files[a];files[a]=nil;return true end
}end
local ini=dofile(file)
assert(ini.get('112233445566')=='7')
assert(ini.set('112233445566','5'))
assert(ini.get('112233445566')=='5')
assert(ini.set('aabbccddeeff','8'))
assert(ini.get('aabbccddeeff')=='8')
assert(files['/etc/config/accelerator.ini']:find('token="preserve%-me"'))
assert(not ini.set('badkey','5'))
assert(not ini.set('aabbccddeeff','5\ninjected=1'))
assert(select(2,files['/etc/config/accelerator.ini']:gsub('aabbccddeeff=',''))==1)
print('PASS: device INI read/write preserves unrelated config and rejects invalid input')
