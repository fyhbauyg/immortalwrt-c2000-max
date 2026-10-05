-- Lua 5.1, offline: loads the actual staged public_signal.lua and http.lua.
-- Every identity/key/address is a synthetic fixture. No network or file writes.
local root = assert(arg[1], "usage: lua5.1 test_public_signal_fixture.lua /path/to/package-root-or-r5-work")
local module_root = root .. "/files/usr/lib/lua/c2000max_app"
local probe = io.open(module_root .. "/public_signal.lua", "r")
if probe then probe:close() else module_root = root end
local total = 0
local function eq(actual, expected, message)
  assert(actual == expected, (message or "not equal") .. " (" .. type(actual) .. "/" .. type(expected) .. ")")
end
local function copy(value)
  if type(value) ~= "table" then return value end
  local result = {}; for k, v in pairs(value) do result[k] = copy(v) end; return result
end
local function count(value) local n=0; for _ in pairs(value) do n=n+1 end; return n end
local function test(name, callback)
  callback(); total=total+1; print("PASS " .. name)
end
local state
local function reset()
  state = {
    local_enabled=true, mode="modern", signal_enabled=true, public_enabled=true,
    password=false, lan=true, action_allowed=true, session=false, plaintext=true,
    id="AA:BB:CC:DD:EE:02", calls={}, permissions={}, lan_calls=0,
    baseline={code="0", signal={{signal=-78, rsrp=-78, sinr=20, mode="NR SA", netlink=1,
      imsi="fixture-imsi", iccid="fixture-iccid", imei="fixture-imei", model="fixture-model", revision="fixture-revision",
      password="NEVER", key="NEVER", token="NEVER", server_secret="NEVER", command="NEVER", control={password="NEVER"},
      internal={key="NEVER"}, wifi={password="NEVER"}, apn="NEVER", rsrq=-999, rssi="-999", rscp=0,
      band1="41", DLBW1=20000, dl_mode1="NR SA", band9="NEVER", CQI=0,
      operator_name=string.rep("x",257), using=0, simcount=2, nrcap="1"}}},
    focused={code=0, at_signal={rsrp=-76,sinr=21,tac=201,pci=101,cell="fixture-cell",password="NEVER",iccid="NEVER",internal={key="NEVER"}}}
  }
end
local core = {
  local_enabled=function() return state.local_enabled end,
  local_protocol_mode=function() return state.mode end,
  note_activity=function() return true end,
  feature_enabled=function(name)
    if name=="local_signal_enable" then return state.signal_enabled end
    if name=="local_signal_public_enable" then return state.public_enabled end
    error("unexpected permission name")
  end,
  management_password_configured=function() return state.password end,
  local_action_allowed=function(action, data)
    state.permissions[#state.permissions+1]={action=action,data=copy(data)}
    return state.action_allowed, "fixture denied"
  end,
  handle=function(action,data,context)
    state.calls[#state.calls+1]={action=action,data=copy(data),context=copy(context)}
    if state.throw then error("fixture core failure") end
    if data.at_signal==1 then
      if state.focus_throw then error("fixture focus failure") end
      return copy(state.focused)
    end
    if action~="signal" then return {code="0",action=action} end
    return copy(state.baseline)
  end,
  device_id=function() return state.id end,
  cache_refresh_policy=function() return {} end,
  signal_refresh_policy=function() return {} end
}
package.loaded["c2000max_app.core"] = core
package.loaded["c2000max_app.lan_boundary"] = {
  allowed=function(context)
    state.lan_calls=state.lan_calls+1
    if state.lan_throw then error("fixture LAN lookup failure") end
    return state.lan and context.remote_addr=="192.0.2.2" and context.server_addr=="192.0.2.1"
  end
}
local public = assert(loadfile(module_root .. "/public_signal.lua"))()
package.loaded["c2000max_app.public_signal"] = public
local context={plaintext=true,remote_addr="192.0.2.2",server_addr="192.0.2.1"}

test("actual public module projects SIM/model fields and excludes all secret/control/nested extras",function()
  reset(); local result=assert(public.response({},context)); local item=result.signal[1]
  for _,key in ipairs({"imsi","iccid","imei","model","revision"}) do eq(item[key],state.baseline.signal[1][key],key) end
  for _,key in ipairs({"password","key","token","server_secret","command","control","internal","wifi","apn","band9","operator_name"}) do eq(item[key],nil,key) end
  eq(item.band1,"41");eq(item.DLBW1,20000);eq(item.dl_mode1,"NR SA")
  eq(item.mac,state.id);eq(item.id,state.id);eq(result.code,"0");eq(count(state.calls),1)
end)
test("missing-data sentinels and non-scalars disappear but true zero and unknown strings remain",function()
  reset(); local item=state.baseline.signal[1]
  item.sinr=0;item.signal="-999.0";item.rsrp=0/0;item.mode={secret="NEVER"};item.DLBW=math.huge;item.pci=-math.huge;item.lac="";item.tac="none";item.sim=false
  item=assert(public.response({},context)).signal[1]
  for _,key in ipairs({"rsrq","rssi","signal","rsrp","mode","DLBW","pci"}) do eq(item[key],nil,key) end
  eq(item.sinr,0);eq(item.rscp,0);eq(item.CQI,0);eq(item.lac,"");eq(item.tac,"none");eq(item.sim,false)
end)
test("raw fields cannot spoof device identity, arrays bounded, missing modem retains identity only",function()
  reset();state.baseline.signal[1].mac="NEVER";state.baseline.signal[1].id="NEVER"
  for i=2,10 do state.baseline.signal[i]={signal=-80,password="NEVER"} end
  local result=assert(public.response({},context));eq(#result.signal,8);eq(result.signal[1].mac,state.id);eq(result.signal[1].id,state.id)
  state.baseline.signal={};result=assert(public.response({},context));eq(count(result.signal[1]),2);eq(result.signal[1].signal,nil)
end)
test("focus retains ordinary signal/mac/id, projects measurements and limits forwarded query",function()
  reset();local result=assert(public.response({index="2",at_signal="1",trans_id="fixture-trans",cmd="reboot",action="set",path="/etc/shadow",password="NEVER",token="NEVER",remote_addr="evil",nested={index=8}},context))
  eq(result.signal[1].rsrp,-78);eq(result.signal[1].mac,state.id);eq(result.signal[1].id,state.id);eq(result.at_signal.rsrp,-76);eq(result.at_signal.sinr,21)
  eq(result.at_signal.password,nil);eq(result.at_signal.iccid,nil);eq(result.at_signal.internal,nil);eq(result.trans_id,"fixture-trans")
  eq(#state.calls,2);eq(count(state.calls[1].data),1);eq(state.calls[1].data.index,2)
  eq(count(state.calls[2].data),2);eq(state.calls[2].data.index,2);eq(state.calls[2].data.at_signal,1)
  for _,call in ipairs(state.calls) do eq(call.action,"signal");eq(call.context.source,"local") end
end)
test("non-focus queries and trans_id respect explicit bounds",function()
  for _,at in ipairs({0,2,"true","invalid"}) do reset();local r=assert(public.response({at_signal=at,trans_id=string.rep("x",129)},context));eq(r.at_signal,nil);eq(r.trans_id,nil);eq(#state.calls,1) end
  reset();eq(assert(public.response({trans_id=17},context)).trans_id,nil)
end)
test("invalid index rejected before core access",function()
  for _,index in ipairs({0,-1,9,1.5,"abc","",math.huge,-math.huge,false,{}}) do reset();local ok,result=pcall(public.response,{index=index},context);assert(not ok or result==nil,"invalid index accepted: " .. type(index) .. " " .. tostring(index));eq(#state.calls,0) end
  reset();assert(public.response({index=8},context));eq(state.calls[1].data.index,8)
end)
test("default-off/permission/password/protocol/master and transport gates never query core",function()
  for _,gate in ipairs({"local_enabled","signal_enabled","public_enabled"}) do reset();state[gate]=false;eq(public.response({},context),nil);eq(#state.calls,0) end
  reset();state.public_enabled=nil;eq(public.response({},context),nil);eq(#state.calls,0)
  reset();state.password=true;eq(public.response({},context),nil);eq(#state.calls,0)
  for _,mode in ipairs({"legacy","auto","invalid"}) do reset();state.mode=mode;eq(public.response({},context),nil);eq(#state.calls,0) end
  for _,ctx in ipairs({{plaintext=false},{plaintext="true"},{plaintext=true,remote_addr="203.0.113.2",server_addr="192.0.2.1"},{}}) do reset();eq(public.response({},ctx),nil);eq(#state.calls,0) end
  reset();eq(public.response({},nil),nil);eq(#state.calls,0)
  reset();state.lan=false;eq(public.response({},context),nil);eq(#state.calls,0)
  reset();state.action_allowed=false;eq(public.response({},context),nil);eq(#state.calls,0)
end)

test("public module rejects every nonempty Origin before LAN/core access but allows native no-Origin",function()
  for _,origin in ipairs({"null","http://192.0.2.1","https://fixture.invalid"," ",false,0,{}}) do
    reset();local request=copy(context);request.origin=origin
    eq(public.response({},request),nil);eq(#state.calls,0);eq(state.lan_calls,0)
  end
  reset();local request=copy(context);request.origin=""
  eq(assert(public.response({},request)).signal[1].rsrp,-78);eq(#state.calls,1)
  reset();eq(assert(public.response({},context)).signal[1].rsrp,-78);eq(#state.calls,1)
end)
test("ordinary core service failures fail closed and invalid identity never leaks payload",function()
  for _,bad in ipairs({false,"invalid",{code="1"},{code="3"},{signal={}}}) do reset();state.baseline=bad;eq(public.response({},context),nil) end
  reset();state.throw=true;eq(public.response({},context),nil)
  for _,id in ipairs({"",false,string.rep("x",65)}) do reset();state.id=id;eq(public.response({},context),nil) end
end)
test("focus failure keeps only separately successful baseline, no invented measurements",function()
  for _,bad in ipairs({false,"invalid",{code=1}}) do reset();state.focused=bad;local result=assert(public.response({at_signal=1},context));eq(result.signal[1].rsrp,-78);eq(result.at_signal,nil) end
  reset();state.focus_throw=true;eq(assert(public.response({at_signal=1},context)).at_signal,nil)
end)

-- Actual http.process integration; encode/decode/session checks are controlled
-- transport stubs, not cryptography tests. The staged public module remains real.
local protocol={
  decode=function(body) return copy(body),{plaintext=state.plaintext,encrypted=not state.plaintext,origin=state.decoded_origin} end,
  encode=function(value,ctx) state.encoded_context=copy(ctx);return value end,
  valid_session=function() return state.session end,
  current_des_response_context=function(ctx) return {encrypted=true,cipher="des"} end,
  verify_auth=function() return false end,
  new_session=function() return nil end
}
package.loaded["c2000max_app.protocol"]=protocol
package.loaded["c2000max_app.identity"]={get=function() return {available=true} end}
package.loaded["luci.sys"]={user={checkpasswd=function() return false end}}
package.loaded["c2000max_app.http"]=nil
assert(loadfile(module_root .. "/http.lua"))()
local http=assert(package.loaded["c2000max_app.http"])
local headers={remote_addr="192.0.2.2",server_addr="192.0.2.1",authorization="",cookie=""}
test("actual http.process allows only eligible anonymous plaintext signal with native socket context",function()
  reset();local result=http.process("signal",{index=1,cmd="reboot",key="NEVER"},headers)
  eq(result.signal[1].imsi,"fixture-imsi");eq(result.signal[1].password,nil);eq(#state.calls,1);eq(state.calls[1].action,"signal")
  eq(state.encoded_context.remote_addr,headers.remote_addr);eq(state.encoded_context.server_addr,headers.server_addr);eq(state.encoded_context.native_http,true)
end)
test("actual http.process denies anonymous business/control actions even with public signal on",function()
  for _,action in ipairs({"cmd","client","wifi","wifiauth","led","info","status","speed","sms","apn","cpesel","reboot"}) do
    reset();local result=http.process(action,{cmd="reboot",action="set",password="NEVER"},headers);eq(result.code,"1",action);eq(#state.calls,0,action)
  end
end)
test("encrypted anonymous signal never takes public path",function()
  reset();state.plaintext=false;eq(http.process("signal",{},headers).code,"1");eq(#state.calls,0);eq(state.lan_calls,0)
end)
test("disabled/WAN/password/boundary/core failures return identity probe only through http",function()
  for _,failure in ipairs({"public_off","wan","password","boundary_error","core_error"}) do
    reset();local request=copy(headers)
    if failure=="public_off" then state.public_enabled=false elseif failure=="wan" then request.remote_addr="203.0.113.2" elseif failure=="password" then state.password=true elseif failure=="boundary_error" then state.lan_throw=true else state.throw=true end
    local result=http.process("signal",{remote_addr="192.0.2.2",server_addr="192.0.2.1"},request)
    eq(count(result.signal[1]),2,failure);eq(result.signal[1].mac,state.id);eq(result.signal[1].imsi,nil,failure)
  end
end)

test("HTTP Origin denies anonymous signal including same-origin and null; body cannot erase header",function()
  for _,origin in ipairs({"null","http://192.0.2.1","https://fixture.invalid"," "}) do
    for _,body in ipairs({{}, {origin=""}, {origin=false}, {origin="http://192.0.2.1",context={origin=""}}}) do
      reset();local request=copy(headers);request.origin=origin;state.decoded_origin=""
      local result=http.process("signal",body,request)
      eq(count(result.signal[1]),2);eq(result.signal[1].imsi,nil);eq(result.signal[1].mac,state.id)
      eq(#state.calls,0);eq(state.lan_calls,0);eq(state.encoded_context.origin,origin)
    end
  end
end)

test("HTTP native no-Origin still works and body/decoded payload cannot select transport Origin",function()
  for _,origin in ipairs({"",false}) do
    reset();local request=copy(headers);if origin=="" then request.origin="" end
    state.decoded_origin="https://fixture.invalid"
    local result=http.process("signal",{origin="https://fixture.invalid",context={origin="null"}},request)
    eq(result.signal[1].imsi,"fixture-imsi");eq(#state.calls,1);eq(state.encoded_context.origin,"")
    eq(count(state.calls[1].data),1);eq(state.calls[1].data.index,1)
  end
end)
test("authenticated requests retain original authorization and core dispatch",function()
  reset();state.session=true;state.public_enabled=false;local result=http.process("cmd",{cmd="fixture-read"},headers);eq(result.code,"0");eq(#state.calls,1);eq(state.calls[1].action,"cmd")
  reset();state.session=true;state.action_allowed=false;eq(http.process("cmd",{},headers).code,"3");eq(#state.calls,0)
  reset();state.session=true;local request=copy(headers);request.origin="http://192.0.2.1"
  eq(http.process("cmd",{cmd="fixture-read"},request).code,"0");eq(#state.calls,1)
  reset();eq(http.process("cmd",{cmd="fixture-read"},request).code,"1");eq(#state.calls,0)
end)
print("TOTAL_PASS " .. total)
print("BOUNDARY: real staged public_signal/http; core/LAN/protocol stubs; no sockets, real credentials or file writes")
