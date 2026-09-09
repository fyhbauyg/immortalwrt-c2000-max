local root = assert(arg[1], "package root required")
package.path = root .. "/files/usr/lib/lua/?.lua;" .. package.path
local files, cache, encoded_values, write_count, lock_busy = {}, nil, {}, 0, false
local fail_chmod, rename_count = false, 0
local STATE = "/tmp/c2000max-app-runtime"
local CACHE = STATE .. "/sample.json"
local function clone(value)
	if type(value) ~= "table" then return value end
	local output = {}; for k, v in pairs(value) do output[k] = clone(v) end; return output
end
local function encode(value)
	if type(value) == "string" then return '"' .. value:gsub('\\','\\\\'):gsub('"','\\"'):gsub('\n','\\n') .. '"' end
	if type(value) == "number" or type(value) == "boolean" then return tostring(value) end
	if type(value) ~= "table" then return "null" end
	local values, array = {}, #value > 0
	if array then for _, item in ipairs(value) do values[#values + 1] = encode(item) end
	else for key, item in pairs(value) do values[#values + 1] = encode(tostring(key)) .. ":" .. encode(item) end end
	return (array and "[" or "{") .. table.concat(values, ",") .. (array and "]" or "}")
end
package.preload["luci.jsonc"] = function() return {
	stringify = function(value) local raw = encode(value); encoded_values[raw] = clone(value); return raw end,
	parse = function(raw) return clone(encoded_values[raw]) end
} end
package.preload["nixio.fs"] = function() return {
	readfile = function(path)
		if path == CACHE then return cache end
		assert(path == "/proc/stat" or path == "/proc/uptime" or path == "/proc/meminfo" or path == "/proc/sys/kernel/random/boot_id", path)
		return files[path]
	end,
	mkdir = function(path, mode) assert(path == STATE and mode == "0700"); return true end,
	lstat = function(path) assert(path == STATE); return { type = "dir", uid = 0, modedec = 448 } end,
	chmod = function(path, mode) assert(mode == "0600" or mode == "0700"); return not fail_chmod end,
	writefile = function(path, raw) assert(path == CACHE .. ".tmp.123"); files[path] = raw; write_count = write_count + 1; return true end,
	rename = function(from, to) assert(from == CACHE .. ".tmp.123" and to == CACHE); rename_count = rename_count + 1; cache = files[from]; files[from] = nil; return true end,
	unlink = function(path) files[path] = nil end
} end
package.preload["nixio"] = function() return {
	getpid = function() return 123 end,
	open = function(path, mode, permissions)
		assert(path == "/var/lock/c2000max-app-runtime.lock" and mode == "a" and permissions == "0600")
		return { lock = function(_, op) return op == "ulock" or not lock_busy end, close = function() return true end }
	end
} end
local counter_available = true
local wan_name = "c2000_wan"
local owners = { eth2 = "modemA", other_cell = "modemB" }
local aliases = { modemA = "eth2", modemB = "other_cell", ["2_1"] = "eth2" }
package.preload["luci.model.uci"] = function() return {
	cursor = function() return { get = function(_, package, section, name)
		if package == "c2000max" and section == "ethernet" and name == "wan4" then return wan_name end
		if package == "network" and name == "modem_config" then return owners[section] end
		if package == "qmodem" and name == "alias" then return aliases[section] end
		error("unapproved UCI lookup")
	end } end
} end
package.preload["c2000max_app.netstats"] = function() return {
	read = function(name)
		assert(name == "modemA" or name == "modemB" or name == "2_1" or name == "c2000_wan" or name == "eth1", "must resolve the exact modem/wan name")
		return counter_available and { available = true, name = name, device = name ~= "modemA" and "eth1" or "eth2",
			source = "sysfs-interface-counters", tx_bytes = 100, rx_bytes = 200, ifindex = 3, updated = 1788950000 } or
			{ available = false, reason = "missing interface", source = "sysfs-interface-counters" }
	end
} end
local runtime = require "c2000max_app.runtime"
local count = 0
local function eq(actual, expected, label)
	if actual ~= expected then error((label or "value") .. ": expected " .. tostring(expected) .. ", got " .. tostring(actual)) end
	count = count + 1
end
files["/proc/stat"] = "cpu 100 20 30 400 10 5 15 0 100 20\ncpu0 0 0 0 0\n"
files["/proc/uptime"] = "100.00 123.00\n"
files["/proc/sys/kernel/random/boot_id"] = "fixture-boot-0001\n"
files["/proc/meminfo"] = "MemTotal: 512000 kB\nMemFree: 10000 kB\nMemAvailable: 256000 kB\nCached: 240000 kB\n"
local basic = { uptime = 100, wan = { up = true, device = "eth1", proto = "dhcp", uptime = 90 },
	port = { role = "wan", actual_role = "wan", port = "eth1", link = "up", speed = "2500",
		cellular_modem = "modemA", cellular_interface = "eth2", cellular_up = false } }
local modems = { { name = "modemA", interface = "eth2", status = {
	name = "modemA", mode = "NR SA", iccid = "fixture-iccid", simtype = "1", nrcap = 1,
	rsrp = "-78", rssi = "-55", rsrq = "-9", sinr = "17", model_temp = "44", status = 0
} } }
local result = runtime.read(basic, modems)
eq(result.global.cpu_percent, 0); eq(result.global.runtime_meta.cpu.available, false)
eq(write_count, 1); eq(result.global.mem_percent, 50); eq(result.global.runtime_meta.memory.available, true)
eq(result.cpe[1].nrcap, "1"); eq(result.cpe[1].rsrp, -78); eq(result.cpe[1].model_temp, 44)
eq(result.cpe[1].sim_flow, 0); eq(result.cpe[1].runtime_meta.sim_flow.available, false)
eq(result.cpe[1].sim_mon, 0); eq(result.cpe[1].runtime_meta.sim_mon.available, false)
eq(result.cpe[1].device_traffic, 300); eq(result.cpe[1].runtime_meta.interface_traffic.scope, "interface-lifetime")
eq(result.wans[1].classname, "cpe"); eq(result.wans[1].status, 1, "board offline state overrides cached modem inference")
eq(result.wans[1].pos, 1); eq(result.wans[1].upload, 100); eq(result.wans[1].download, 200)
eq(result.wans[1].runtime_meta.accounting == result.cpe[1].runtime_meta.interface_traffic, false,
	"jsonc cannot serialize repeated table references")
eq(result.wans[2].name, "c2000_wan"); eq(result.wans[2].status, 0); eq(result.wans[2].pos, 0)
eq(result.link[1].mode, 1); eq(result.link[1].status, 0); eq(result.link[1].speed, 4)
eq(modems[1].status.nrcap, 1, "input cache is never mutated")
files["/proc/uptime"] = "100.25 0\n"
files["/proc/stat"] = "cpu 140 30 50 430 10 5 15 0 140 30\n"
result = runtime.read(basic, modems)
eq(result.global.cpu_percent, 0); eq(write_count, 1, "subsecond calls reuse cache")
files["/proc/uptime"] = "101.00 0\n"
result = runtime.read(basic, modems)
eq(result.global.cpu_percent, 70, "guest times not counted twice")
eq(result.global.runtime_meta.cpu.available, true); eq(write_count, 2)
files["/proc/uptime"] = "101.50 0\n"
result = runtime.read(basic, modems)
eq(result.global.cpu_percent, 70); eq(write_count, 2); eq(result.global.runtime_meta.cpu.cached, true)
files["/proc/uptime"] = "102.00 0\n"
files["/proc/stat"] = "cpu 1 1 1 1 1 1 1 0\n"
result = runtime.read(basic, modems)
eq(result.global.cpu_percent, 0); eq(result.global.runtime_meta.cpu.available, false)
files["/proc/uptime"] = "1.00 0\n"
files["/proc/sys/kernel/random/boot_id"] = "fixture-boot-0002\n"
result = runtime.read(basic, modems)
eq(result.global.runtime_meta.cpu.available, false)
eq(result.global.runtime_meta.cpu.reason:find("reboot", 1, true) ~= nil, true)
lock_busy = true
result = runtime.read(basic, modems)
eq(result.global.runtime_meta.cpu.available, false); eq(result.global.runtime_meta.cpu.reason, "CPU sample busy")
lock_busy = false
for _, raw in ipairs({ "", "MemTotal: 1 kB\n", "MemTotal: 0 kB\nMemAvailable: 0 kB\n", "MemTotal: 10 kB\nMemAvailable: 11 kB\n" }) do
	local value, metadata = runtime.memory_sample(raw); eq(value, 0); eq(metadata.available, false)
end
files["/proc/stat"] = "cpu 999999999999999999999 1 1 1\n"
result = runtime.read(basic, modems); eq(result.global.runtime_meta.cpu.available, false)
basic.port.link = "down"; basic.port.speed = "2500"
result = runtime.read(basic, modems); eq(result.link[1].status, 1); eq(result.link[1].speed, 0)
basic.port.link = "up"; basic.port.speed = "5000"
result = runtime.read(basic, modems); eq(result.link[1].speed, 0); eq(result.link[1].runtime_meta.speed_mbps, 5000)
basic.port.role, basic.port.actual_role = "lan", "lan"
basic.port.speed = "2500"; basic.port.cellular_up = true; basic.wan.up = false
modems[1].status.sim_flow, modems[1].status.sim_mon = "1024", "256"
result = runtime.read(basic, modems)
eq(result.link[1].mode, 0); eq(result.wans[1].status, 0); eq(result.wans[1].pos, 0)
eq(result.cpe[1].sim_flow, 1024); eq(result.cpe[1].sim_mon, 256)
eq(result.cpe[1].runtime_meta.sim_mon.available, true)
counter_available = false
result = runtime.read(basic, modems)
eq(result.wans[1].upload, 0); eq(result.wans[1].runtime_meta.accounting.available, false)
eq(result.wans[2].download, 0); eq(result.wans[2].runtime_meta.accounting.available, false)
counter_available = true
files["/proc/stat"] = "cpu 100 20 30 400 10 5 15 0 100 20\n"
files["/proc/uptime"] = "10.00 0\n"
result = runtime.read(basic, modems)
for _, sample in ipairs({ { "57 °C", 57 }, { "57℃", 57 }, { "57.5 °C", 57.5 }, { "-20°C", -20 }, { "44", 44 }, { 44.5, 44.5 } }) do
	modems[1].status.model_temp = sample[1]
	local value = runtime.read(basic, modems)
	eq(value.cpe[1].model_temp, sample[2]); eq(value.cpe[1].runtime_meta.temperature_available, true)
end
for _, invalid in ipairs({ "57 °C trailing", "NaN", "inf", "151 °C", "-999", "57 F", "1e2", {} }) do
	modems[1].status.model_temp = invalid
	local value = runtime.read(basic, modems)
	eq(value.cpe[1].model_temp, 0); eq(value.cpe[1].runtime_meta.temperature_available, false)
end
modems[1].status.model_temp = "57 °C"
local previous_cache, previous_renames = cache, rename_count
files["/proc/uptime"] = "11.00 0\n"; fail_chmod = true
result = runtime.read(basic, modems)
eq(result.global.runtime_meta.cpu.cache_saved, false)
eq(rename_count, previous_renames, "failed chmod cannot publish insecure cache")
eq(cache, previous_cache, "previous cache preserved after chmod failure")
eq(files[CACHE .. ".tmp.123"], nil, "failed cache temporary removed")
fail_chmod = false
result = runtime.read(basic, modems)
wan_name = nil
result = runtime.read(basic, modems)
eq(result.wans[2].name, "eth1", "missing logical configuration uses the actual reported device")
wan_name = "c2000_wan"
result = runtime.read(basic, modems)
-- Exact sanitized live regression: LAN/5G has no selected cellular_interface
-- but the only QModem interface is online. cellular_up=false is only a default.
local real_basic = { uptime = 100, wan = {}, port = { role = "lan", actual_role = "lan", port = "eth1", link = "up", speed = "2500",
	cellular_up = false, cellular_interface = "", qmodem_any_up = true, qmodem_interface = "eth2", cellular_modem = "auto" } }
local real_modems = { { name = "2_1", status = clone(modems[1].status) } }
real_modems[1].status.name = "2_1"; real_modems[1].status.status = 0; real_modems[1].status.mode = "NR SA"
owners.eth2 = "2_1"
local real_result = runtime.read(real_basic, real_modems)
eq(real_result.wans[1].name, "2_1"); eq(real_result.wans[1].status, 0, "real LAN/5G interface stays online")
eq(real_result.wans[1].runtime_meta.state_source, "board-online-modem-interface")
eq(type(real_result.wans[1].runtime_meta.accounting), "table")
eq(real_result.wans[1].runtime_meta.accounting.available, true)
-- Reject duplicate table pointers just as real luci.jsonc does (without
-- depending on object traversal order).
local seen = {}
local function unique_tables(value)
	if type(value) ~= "table" then return end
	assert(not seen[value], "reused table would become null in luci.jsonc")
	seen[value] = true
	for _, child in pairs(value) do unique_tables(child) end
end
unique_tables(real_result); count = count + 1
owners.eth2 = "modemA"
local two_modems = { clone(modems[1]), { name = "modemB", status = { name = "modemB", status = 1, mode = "LTE" } } }
two_modems[1].status.status = 1
local multi_result = runtime.read(real_basic, two_modems)
eq(multi_result.wans[1].status, 0, "only matching online interface is promoted")
eq(multi_result.wans[2].status, 1, "any_up does not promote another modem")
real_basic.port.qmodem_interface = "unmapped_if"
multi_result = runtime.read(real_basic, two_modems)
eq(multi_result.wans[1].status, 1, "ambiguous aggregate cannot override multi-modem cache")
eq(multi_result.wans[2].status, 1)
real_basic.port.qmodem_interface = "other_cell"
multi_result = runtime.read(real_basic, { two_modems[1] })
eq(multi_result.wans[1].status, 1, "explicit foreign interface owner blocks single-cache promotion")
real_basic.port.cellular_interface = "eth2"; real_basic.port.cellular_up = false
two_modems[1].status.status = 0
multi_result = runtime.read(real_basic, two_modems)
eq(multi_result.wans[1].status, 1, "explicit matching selected interface offline is authoritative")
eq(multi_result.wans[2].status, 0, "another positively observed modem can still be online")
if arg[4] then local file = assert(io.open(arg[4], "w")); file:write(encode({ code = 0, result = real_result })); file:close() end
if arg[2] then local file = assert(io.open(arg[2], "w")); file:write(encode({ code = 0, result = result })); file:close() end
if arg[3] then
	basic.port.role, basic.port.actual_role, basic.wan.up = "wan", "wan", true
	result = runtime.read(basic, modems)
	local file = assert(io.open(arg[3], "w")); file:write(encode({ code = 0, result = result })); file:close()
end
print("APP runtime fixture passed: " .. count .. " assertions")
