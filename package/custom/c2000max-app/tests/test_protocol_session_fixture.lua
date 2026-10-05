-- Real protocol/session and http.process integration, without a LuCI bridge.
-- No router sockets, real filesystem, credentials or crypto subprocesses run.
local root = assert(arg[1], "package root required")
package.path = root .. "/files/usr/lib/lua/?.lua;" .. package.path

local function clone(value)
	if type(value) ~= "table" then return value end
	local output = {}; for key, item in pairs(value) do output[key] = clone(item) end
	return output
end
local encoded_values = {}
local function encode(value)
	if type(value) == "string" then return '"' .. value:gsub('\\', '\\\\'):gsub('"', '\\"'):gsub('\n', '\\n') .. '"' end
	if type(value) == "number" or type(value) == "boolean" then return tostring(value) end
	if type(value) ~= "table" then return "null" end
	local values, array = {}, #value > 0
	if array then for _, item in ipairs(value) do values[#values + 1] = encode(item) end
	else for key, item in pairs(value) do values[#values + 1] = encode(tostring(key)) .. ":" .. encode(item) end end
	return (array and "[" or "{") .. table.concat(values, ",") .. (array and "]" or "}")
end
local json = {
	stringify = function(value) local raw = encode(value); encoded_values[raw] = clone(value); return raw end,
	parse = function(raw) return clone(encoded_values[raw]) end
}
package.loaded["luci.jsonc"] = json

local files, des_plain = {}, nil
local real_rename = os.rename
os.rename = function(source, target)
	assert(source:find(".tmp.", 1, true), "sessions must use an atomic temporary file")
	assert(files[target] == nil or files[target]:match("^%d+ [a-z]+\n$"), "old session remains complete during write")
	files[target] = files[source]; files[source] = nil; return true
end
local session_dir = "/tmp/c2000max-app-sessions/"
local valid_token = string.rep("a", 32)
local password_token = string.rep("b", 32)
local expired_token = string.rep("c", 32)
files[session_dir .. valid_token] = tostring(os.time() + 300) .. " device\n"
files[session_dir .. password_token] = tostring(os.time() + 300) .. " password\n"
files[session_dir .. expired_token] = tostring(os.time() - 30) .. " device\n"
package.loaded["nixio.fs"] = {
	readfile = function(path) return files[path] end,
	writefile = function(path, value) files[path] = value; return true end,
	unlink = function(path) files[path] = nil; return true end,
	chmod = function() return true end,
	mkdirr = function() return true end
}
package.loaded["luci.util"] = { shellquote = function(value)
	assert(value:match("^[%w/%._%-]+$"), "fixture only accepts fixed safe crypto arguments")
	return value
end }
package.loaded["luci.sys"] = {
	uniqueid = function(size) return string.rep("d", size * 2) end,
	call = function(command)
		local input, output = command:match("des%-encrypt < (%S+) > (%S+)$")
		assert(input and output, "unexpected fixture crypto command")
		des_plain = json.parse(files[input])
		files[output] = "fixture-des-envelope\n"
		return 0
	end,
	user = { checkpasswd = function() error("password verification not used in this fixture") end }
}

-- These functions model the missing _G.L bridge: native calls must never use
-- any implicit LuCI accessor, even when no cookie or Authorization is supplied.
local allow_luci = false
local implicit_calls = 0
local luci_values = {}
local function implicit(name, key)
	implicit_calls = implicit_calls + 1
	assert(allow_luci, "native transport touched luci.http." .. name)
	return luci_values[name] and luci_values[name][key]
end
package.loaded["luci.http"] = {
	getenv = function(key) return implicit("getenv", key) end,
	getcookie = function(key) return implicit("getcookie", key) end,
	formvalue = function(key) return implicit("formvalue", key) end,
	content = function() return implicit("content", "body") end
}
package.loaded["c2000max_app.identity"] = { get = function()
	return { available = true, device_id = "001122334455" }
end }
local mode, enabled, permitted, require_password = "legacy", true, true, false
local business_calls = 0
package.loaded["c2000max_app.core"] = {
	local_protocol_mode = function() return mode end,
	note_activity = function() return true end,
	local_enabled = function() return enabled end,
	device_id = function() return "001122334455" end,
	management_password_configured = function() return require_password end,
	local_action_allowed = function() return permitted, "fixture permission denied" end,
	handle = function(action, data)
		business_calls = business_calls + 1
		return { code = action == "status" and 0 or "0", fixture_action = action,
			trans_id = tostring(data.trans_id or ""), signal = { { rsrp = -78 } } }
	end
}
local protocol = require "c2000max_app.protocol"
local app_http = require "c2000max_app.http"
local count = 0
local function eq(actual, expected, message)
	count = count + 1
	assert(actual == expected, message .. ": expected " .. tostring(expected) .. ", got " .. tostring(actual))
end
local function process(action, data, context)
	local ok, response = pcall(app_http.process, action, json.stringify(data or {}), context or {})
	eq(ok, true, "native " .. mode .. " /" .. action .. " must not throw" ..
		(not ok and (" (" .. tostring(response) .. ")") or ""))
	eq(type(response), "table", "native response is a table")
	return response
end

for _, selected in ipairs({ "legacy", "modern" }) do
	mode = selected
	local before = business_calls
	local probe = process("signal", { trans_id = "probe" })
	if mode == "legacy" then
		eq(probe.data, "fixture-des-envelope", "legacy discovery returns DES envelope")
		eq(des_plain.code, "1", "legacy discovery retains its auth-needed marker")
	else
		eq(probe.code, "0", "modern capability success marker")
		eq(probe.signal[1].mac, "001122334455", "modern discovery identity retained")
		eq(probe.signal[1].rsrp, nil, "anonymous probe is not private modem data")
		eq(probe.signal[1].iccid, nil, "anonymous probe has no SIM identity")
	end
	eq(business_calls, before, "anonymous discovery never dispatches modem business")
	for _, action in ipairs({ "info", "status", "speed" }) do
		eq(process(action, {}).code, "1", "anonymous business stays rejected")
	end
	eq(business_calls, before, "anonymous business never dispatched")

	local queries = {
		{ "signal", {}, { cookie = "unrelated=1; sysauth=" .. valid_token .. "; next=1" } },
		{ "status", {}, { authorization = "Bearer " .. valid_token } },
		{ "info", { token = valid_token }, {} }
	}
	for _, query in ipairs(queries) do
		local reply = process(query[1], query[2], query[3])
		eq(reply.fixture_action, query[1], "explicit native credentials reach business")
		eq(reply.signal[1].rsrp, -78, "authenticated signal remains available")
	end
end

eq(protocol.valid_session({}, { native_http = true }, false), false,
	"native direct session check with absent context headers denies safely")
eq(protocol.valid_session({}, { native_http = true, cookie = "sysauth=invalid" }, false), false,
	"malformed native cookie denies without LuCI fallback")
eq(protocol.valid_session({}, { native_http = true, cookie = "sysauth=" .. expired_token }, false), false,
	"expired native session remains rejected")
eq(files[session_dir .. expired_token], nil, "expired session cleanup retained")
eq(protocol.valid_session({ token = valid_token }, { native_http = true }, true), false,
	"password-required policy rejects device session")
eq(protocol.valid_session({ token = password_token }, { native_http = true }, true), true,
	"password-required policy accepts password session")
eq(implicit_calls, 0, "all native cases avoid every LuCI accessor")

enabled = false
eq(process("status", { token = valid_token }).code, "2", "master switch still rejects authenticated native query")
enabled, permitted = true, false
eq(process("signal", { token = valid_token }).code, "3", "signal permission still enforced")
permitted = true
eq(implicit_calls, 0, "native permission paths also avoid LuCI")

-- Real LuCI dispatch remains compatible with environment, cookie parser and
-- legacy form token fallback. Only the native transport may suppress these.
allow_luci = true
luci_values = { getenv = { HTTP_AUTHORIZATION = "Bearer " .. valid_token } }
eq(protocol.valid_session({}, {}, false), true, "LuCI Authorization environment fallback")
luci_values = { getenv = { HTTP_COOKIE = "sysauth=" .. valid_token } }
eq(protocol.valid_session({}, {}, false), true, "LuCI Cookie environment fallback")
luci_values = { getcookie = { sysauth = valid_token } }
eq(protocol.valid_session({}, {}, false), true, "LuCI cookie parser fallback")
luci_values = { formvalue = { token = valid_token } }
eq(protocol.valid_session({}, {}, false), true, "LuCI legacy form token fallback")
luci_values = {}
eq(protocol.valid_session({}, {}, false), false, "LuCI anonymous business remains rejected")
eq(implicit_calls > 0, true, "LuCI fallback accessors were actually exercised")

os.rename = real_rename
print("PASS: native HTTP real protocol/session and LuCI fallback " .. count .. " assertions")
