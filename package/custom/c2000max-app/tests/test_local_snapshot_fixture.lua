-- Real core with an in-memory filesystem, UCI and modem backend.
local root = assert(arg[1])
package.path = root .. "/files/usr/lib/lua/?.lua;" .. package.path
local now, files, values, serial = 100, {}, {}, 0
local calls, lock_busy, root_password, mode = 0, false, "", "auto"
local public = "0"
local real_rename = os.rename
local function copy(value)
	if type(value) ~= "table" then return value end
	local output = {}; for k,v in pairs(value) do output[k] = copy(v) end; return output
end
local json = {
	stringify = function(value) serial=serial+1; local key="json"..serial; values[key]=copy(value); return key end,
	parse = function(raw) return copy(values[raw]) end
}
package.loaded["luci.jsonc"] = json
package.loaded["nixio.fs"] = {
	readfile=function(path) return files[path] end,
	writefile=function(path,value) files[path]=value; return true end,
	mkdirr=function() return true end, chmod=function() return true end,
	access=function() return false end, unlink=function(path) files[path]=nil end
}
os.rename=function(a,b) files[b]=files[a]; files[a]=nil; return true end
package.loaded["nixio"] = {
	gettimeofday=function() return now,0 end, getpid=function() return 42 end,
	nanosleep=function(sec,ns) now=now+sec+(ns or 0)/1000000000 end,
	open=function(path,flags,permissions)
		assert(type(permissions)=="string" and permissions:match("^[0-7][0-7][0-7][0-7]$"),"nixio permissions use an octal string, never a decimal numeric mode")
		return {lock=function() return not lock_busy end,close=function() end}
	end
}
package.loaded["luci.sys"] = { uptime=function() return now end,
	user={getpasswd=function() return root_password end} }
local cursor={
	get=function(_,config,section,option)
		if config=="c2000max_app" then
			if option=="local_protocol_mode" then return mode end
			if option=="local_signal_public_enable" then return public end
			if option=="local_enable" or option=="local_signal_enable" then return "1" end
			if option=="local_client_enable" or option=="local_wifi_enable" then return "0" end
		elseif config=="qmodem" and option=="at_port" then return "/dev/fake" end
		return nil,"Entry not found"
	end,
	foreach=function(_,config,kind,callback)
		if config=="qmodem" and kind=="modem-device" then callback({[".name"]="modem0",model="MT5700",manufacturer="huawei"}) end
	end
}
package.loaded["luci.model.uci"]={cursor=function() return cursor end}
local fail_backend=false
package.loaded["luci.util"]={
	shellquote=function(value) return "'"..value.."'" end,
	ubus=function(object,method,args)
		if object=="qmodem" then
			calls=calls+1
			if fail_backend then return {} end
			if method=="info" then return {model="MT5700",rsrp="-72"} end
			if method=="network_info" then return {netlink="1"} end
			if method=="sim_info" then return {sim_status="ready"} end
			if method=="at" then return {at_cfg={status="1",res="^MONSC: NR,460,00,504990,1,C248F7002,380,143076,-70,-11,12\r\nOK"}} end
		end
		if object=="c2000max" and method=="sim_status" then return {current_slot="external2"} end
		return {}
	end
}
package.loaded["c2000max_app.identity"]={get=function() return {device_id="001122334455"} end}
local cache="/var/run/c2000max-app/cache/"
local function seed(name,value,updated) files[cache..name..".json"]=json.stringify({value=value,updated=updated}) end
local modem={name="modem0",model="MT5700",manufacturer="huawei",selector={current_slot="external2"},status={rsrp="-81",netlink="1"}}
seed("modems",{modem},80)
seed("selector",modem.selector,80)
seed("fast_modem0",{rsrp="-75",sinr="12"},80)
local core=require "c2000max_app.core"
assert(core.cache_refresh_policy().modem==10,"missing UCI values with a second error return still use refresh defaults")
assert(core.local_protocol_mode()=="legacy","auto without a password authenticates locally")
root_password="fixture-hash"
assert(core.local_protocol_mode()=="modern","auto with password preserves AES password authentication")
root_password=""; public="1"
assert(core.local_protocol_mode()=="modern","explicit public-signal opt-in preserves its AES route")
public="0"; mode="modern"
assert(core.local_protocol_mode()=="modern","manual AES is preserved")
mode="legacy"; root_password="fixture-hash"
assert(core.local_protocol_mode()=="legacy","manual protocol selection remains explicit")
root_password=""
local result=core.handle("signal",{}, {source="local"})
assert(result.signal[1].rsrp=="-75" and calls==0,"local ordinary signal reuses bounded shared snapshots without AT")
result=core.handle("info",{}, {source="local"})
assert(result.result.basic.modem_cnt==1 and calls==0,"local info uses bounded snapshot")
seed("fast_modem0",{rsrp="-68"},101); now=102
result=core.handle("signal",{}, {source="local"})
assert(result.signal[1].rsrp=="-68" and calls==0,"newer background publication replaces process-local radio cache")
lock_busy=true; now=120
result=core.modems()
assert(result[1].name=="modem0" and calls==0,"another refresh owner returns bounded stale snapshot without duplicate work")
lock_busy=false; fail_backend=true
result=core.modems()
assert(result[1].status.rsrp=="-81","temporary backend failure retains complete snapshot")
local cached=json.parse(files[cache.."modems.json"])
assert(cached.updated==80,"a failed refresh never makes old data newly fresh")
now=141
local before=calls
core.handle("info",{}, {source="local"})
assert(calls>before,"snapshots older than sixty seconds cannot stay on fast path")
fail_backend=false
result=core.modems(true)
assert(result[1] and json.parse(files[cache.."modems.json"]).updated==141,"successful refresh recovers atomic cache")
before=calls
core.handle("signal",{at_signal=1,index=1},{source="local"})
assert(calls>before,"focused signal still samples fresh serialized AT")
os.rename=real_rename
print("PASS: auto/password/manual policies, bounded snapshots, shared freshness, lock contention, failed-refresh retention, focused sampling")
