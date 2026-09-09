-- Runtime presentation for APP 3.2. Inputs are already-cached modem data.
-- Never calls core/cloud, an AT command, or a service-mutating operation.
local fs = require "nixio.fs"
local nixio = require "nixio"
local json = require "luci.jsonc"
local netstats = require "c2000max_app.netstats"
local uci = require("luci.model.uci").cursor()
local M = {}
local STATE_DIR = "/tmp/c2000max-app-runtime"
local CACHE = STATE_DIR .. "/sample.json"
local LOCK = "/var/lock/c2000max-app-runtime.lock"
local MAX_INTEGER = 9007199254740991

local function number(value)
	local n = tonumber(value)
	if n and n == n and n > -math.huge and n < math.huge then return n end
end
local function bytes(value)
	local n = number(value)
	if n and n >= 0 and n <= MAX_INTEGER and n == math.floor(n) then return n end
end
local function text(value)
	return type(value) == "string" and value or type(value) == "number" and tostring(value) or ""
end
local function table_or_empty(value) return type(value) == "table" and value or {} end
local function shallow_copy(value)
	local output = {}; for key, item in pairs(value) do output[key] = item end; return output
end
local function is_up(value) return value == true or value == 1 or value == "1" or value == "up" end
local function trim(value) return text(value):match("^%s*(.-)%s*$") end
local function percent(value) return math.floor(math.max(0, math.min(100, value)) * 10 + 0.5) / 10 end

local function temperature(value)
	local n
	if type(value) == "number" then n = number(value)
	elseif type(value) == "string" then
		local raw = trim(value):gsub("℃", "°C")
		local numeric = raw:match("^([+-]?%d+%.?%d*)%s*°C$") or raw:match("^([+-]?%d+%.?%d*)$")
		n = number(numeric)
	end
	-- Reject sentinel/out-of-range readings, but retain plausible cold and
	-- overheat readings rather than clamping them to a misleading normal value.
	if n and n >= -60 and n <= 150 then return n end
end

function M.memory_sample(raw)
	local values = {}
	for key, value in text(raw):gmatch("([A-Za-z_]+):%s*(%d+)%s+kB") do values[key] = tonumber(value) end
	local total, available = values.MemTotal, values.MemAvailable
	if not total or total <= 0 or not available or available < 0 or available > total then
		return 0, { available = false, source = "proc-meminfo-MemAvailable", reason = "memory sample unavailable" }
	end
	return percent((total - available) * 100 / total), {
		available = true, source = "proc-meminfo-MemAvailable", total_bytes = total * 1024,
		available_bytes = available * 1024
	}
end

local function cpu_counters(raw)
	local line = text(raw):match("^cpu%s+([^\n]+)")
	if not line then return nil end
	local fields = {}
	for value in line:gmatch("%S+") do
		if not value:match("^%d+$") then return nil end
		local parsed = bytes(value)
		if not parsed then return nil end
		fields[#fields + 1] = parsed
	end
	if #fields < 4 then return nil end
	-- guest and guest_nice are already included in user/nice; do not count
	-- them twice. iowait is idle time, consistent with common CPU monitors.
	local total = 0
	for index = 1, math.min(#fields, 8) do total = total + fields[index] end
	if not bytes(total) then return nil end
	return { total = total, idle = fields[4] + (fields[5] or 0) }
end

local function read_cache()
	local raw = fs.readfile(CACHE)
	if type(raw) ~= "string" or #raw > 2048 then return nil end
	local ok, value = pcall(json.parse, raw)
	if not ok or type(value) ~= "table" then return nil end
	if not bytes(value.total) or not bytes(value.idle) or value.idle > value.total or
	   not number(value.uptime) or value.uptime < 0 or
	   type(value.boot) ~= "string" then return nil end
	return value
end

local function write_cache(value)
	local encoded = json.stringify(value)
	if type(encoded) ~= "string" or #encoded > 2048 then return false end
	local temp = CACHE .. ".tmp." .. tostring(nixio.getpid())
	if not fs.writefile(temp, encoded) then return false end
	if not fs.chmod(temp, "0600") then fs.unlink(temp); return false end
	if not fs.rename(temp, CACHE) then fs.unlink(temp); return false end
	return true
end

local function cpu_sample()
	local uptime = number(text(fs.readfile("/proc/uptime")):match("^(%d+%.?%d*)"))
	local boot = trim(fs.readfile("/proc/sys/kernel/random/boot_id"))
	local current = cpu_counters(fs.readfile("/proc/stat"))
	local meta = { available = false, source = "proc-stat-delta", reason = "CPU sample unavailable" }
	if not uptime or #boot < 8 or not current then return 0, meta end
	local state = fs.lstat(STATE_DIR)
	if not state then fs.mkdir(STATE_DIR, "0700"); state = fs.lstat(STATE_DIR) end
	if type(state) ~= "table" or state.type ~= "dir" or state.uid ~= 0 then
		meta.reason = "CPU cache directory is not a root-owned directory"; return 0, meta
	end
	if not number(state.modedec) or state.modedec % 512 ~= 448 then
		if not fs.chmod(STATE_DIR, "0700") then meta.reason = "CPU cache permissions unavailable"; return 0, meta end
	end
	local fd = nixio.open(LOCK, "a", "0600")
	if not fd then meta.reason = "CPU sampling lock unavailable"; return 0, meta end
	if not fd:lock("tlock") then fd:close(); meta.reason = "CPU sample busy"; return 0, meta end
	local ok, value, detail = pcall(function()
		local previous = read_cache()
		if previous and previous.boot == boot and uptime >= previous.uptime and uptime - previous.uptime < 1 then
			return percent(number(previous.percent) or 0), {
				available = previous.available == true, source = "proc-stat-delta", cached = true,
				age_seconds = uptime - previous.uptime, reason = previous.available and nil or "CPU sample warming up"
			}
		end
		local result, available, reason = 0, false, "CPU sample warming up"
		if previous and previous.boot == boot and uptime > previous.uptime then
			local dt, di = current.total - previous.total, current.idle - previous.idle
			if dt > 0 and di >= 0 and di <= dt then result, available, reason = percent((dt - di) * 100 / dt), true, nil
			else reason = "CPU counters reset or unchanged" end
		elseif previous then reason = "CPU sample reset after reboot or monotonic-clock rollback" end
		local saved = write_cache({ total = current.total, idle = current.idle, uptime = uptime,
			boot = boot, percent = result, available = available })
		return result, { available = available, source = "proc-stat-delta", reason = reason,
			cache_saved = saved, interval_seconds = available and uptime - previous.uptime or nil }
	end)
	fd:lock("ulock"); fd:close()
	if not ok then meta.reason = "CPU sampling failed"; return 0, meta end
	return value, detail
end

local function counters(name)
	local ok, stats = pcall(netstats.read, name)
	stats = ok and table_or_empty(stats) or {}
	local tx, rx = bytes(stats.tx_bytes), bytes(stats.rx_bytes)
	if stats.available == true and tx and rx then
		return tx, rx, { available = true, source = stats.source, device = stats.device,
			ifindex = stats.ifindex, unit = "bytes", scope = "interface-lifetime", updated = stats.updated }
	end
	return 0, 0, { available = false, source = stats.source or "sysfs-interface-counters",
		reason = stats.reason or "interface counters unavailable", unit = "bytes" }
end

local function runtime_modem(modem, index)
	local original = table_or_empty(modem.status)
	local value = {}
	for key, field in pairs(original) do value[key] = field end
	value.name = text(original.name) ~= "" and text(original.name) or text(modem.name)
	if value.name == "" then value.name = "cpe" .. tostring(index - 1) end
	value.cpeno = index
	value.mode, value.iccid = text(original.mode), text(original.iccid)
	value.simtype = original.simtype ~= nil and original.simtype or ""
	value.nrcap = tostring(original.nrcap or "0") == "1" and "1" or "0"
	local missing = {}
	for _, key in ipairs({ "rsrp", "rssi", "rsrq", "sinr", "rscp", "signal", "signalStrength" }) do
		value[key] = number(original[key])
		if value[key] == nil then value[key] = -999; missing[#missing + 1] = key end
	end
	local temp = temperature(original.model_temp)
	value.model_temp = temp or 0
	local tx, rx, accounting = counters(modem.name or value.name)
	local aggregate = bytes(tx + rx) or 0
	value.device_traffic, value.traffic = aggregate, aggregate
	-- Interface counters reset on reboot/device recreation and cannot stand
	-- in for per-SIM lifetime/monthly accounting. Preserve genuine counters
	-- if a cached modem provider has supplied them; otherwise label missing.
	value.sim_flow, value.sim_mon = bytes(original.sim_flow) or 0, bytes(original.sim_mon) or 0
	value.runtime_meta = {
		interface_traffic = accounting, temperature_available = temp ~= nil,
		missing_signal_fields = missing, source = "cached-modem-status",
		sim_flow = { available = bytes(original.sim_flow) ~= nil, unit = "bytes", source = "cached-modem-provider" },
		sim_mon = { available = bytes(original.sim_mon) ~= nil, unit = "bytes", source = "cached-modem-provider" }
	}
	return value, tx, rx, accounting
end

local function interface_owner(name)
	if type(name) ~= "string" or name == "" then return nil end
	local owner = uci:get("network", name, "modem_config")
	return type(owner) == "string" and owner ~= "" and owner or nil
end

local function modem_has_interface(modem_name, interface)
	if type(modem_name) ~= "string" or modem_name == "" or type(interface) ~= "string" or interface == "" then return false end
	local owner = interface_owner(interface)
	if owner then return owner == modem_name end
	local alias = uci:get("qmodem", modem_name, "alias")
	return interface == ((type(alias) == "string" and alias ~= "") and alias or modem_name)
end

local function modem_online_state(modem, item, port, modem_count)
	local cached = tonumber(item.status) == 0
	-- cellular_up is initialized to false even if no cellular_interface was
	-- configured for a WAN/balanced role. In normal LAN/5G mode it therefore
	-- is not evidence that the modem is offline.
	if port.cellular_up ~= nil and modem_has_interface(modem.name, port.cellular_interface) then
		return is_up(port.cellular_up), "board-selected-cellular-interface"
	end
	-- qmodem_interface names the first *online* modem's logical netifd
	-- interface (alias or modem section), not necessarily its kernel device.
	if is_up(port.qmodem_any_up) and modem_has_interface(modem.name, port.qmodem_interface) then
		return true, "board-online-modem-interface"
	end
	if modem_count == 1 and port.qmodem_any_up ~= nil then
		local owner = interface_owner(port.qmodem_interface)
		-- The global flag can describe the only cached modem, unless explicit
		-- network ownership proves it is instead another modem. Never promote
		-- every CPE in a multi-modem setup from this aggregate flag.
		if not owner or owner == modem.name then return is_up(port.qmodem_any_up), "board-single-modem-state" end
	end
	return cached, "cached-modem-status"
end

function M.read(basic_status, modems)
	local basic = table_or_empty(basic_status)
	local port, wan = table_or_empty(basic.port), table_or_empty(basic.wan)
	local cpu, cpu_meta = cpu_sample()
	local memory, mem_meta = M.memory_sample(fs.readfile("/proc/meminfo"))
	local result = {
		global = { uptime = number(basic.uptime) or 0, cpu_percent = cpu,
			mem_percent = memory, net_prefer = 0, runtime_meta = {
				cpu = cpu_meta, memory = mem_meta, net_prefer_available = false
			} },
		cpe = {}, wans = {}, link = {}
	}
	local ethernet_role = port.actual_role or port.role
	for index, modem in ipairs(table_or_empty(modems)) do
		if type(modem) == "table" then
			local item, tx, rx, accounting = runtime_modem(modem, index)
			result.cpe[#result.cpe + 1] = item
			local online, state_source = modem_online_state(modem, item, port, #modems)
			result.wans[#result.wans + 1] = {
				name = item.name, classname = "cpe", status = online and 0 or 1,
				pos = ethernet_role == "wan" and index or index - 1,
				-- luci.jsonc treats any repeated table pointer as a cycle and
				-- serializes the second reference as null, even across siblings.
				upload = tx, download = rx, runtime_meta = { accounting = shallow_copy(accounting), state_source = state_source }
			}
		end
	end
	if next(wan) or ethernet_role == "wan" then
		-- Keep the identity returned to APP /speed equal to the actual board
		-- WAN. A different existing network.wan must never steal its counters.
		local wan_name = text(uci:get("c2000max", "ethernet", "wan4"))
		if wan_name == "" then wan_name = text(wan.l3_device or wan.device) end
		local tx, rx, accounting = counters(wan_name)
		local route = table_or_empty(table_or_empty(wan.route)[1])
		result.wans[#result.wans + 1] = {
			name = wan_name, classname = "wan", status = is_up(wan.up) and 0 or 1,
			pos = ethernet_role == "wan" and 0 or #result.cpe,
			proto = text(wan.proto), device = text(wan.l3_device or wan.device),
			uptime = number(wan.uptime) or 0, gateway = text(route.nexthop or route.gateway),
			upload = tx, download = rx, runtime_meta = { accounting = accounting, state_source = "netifd-status" }
		}
	end
	if type(port.port) == "string" and port.port ~= "" then
		local linked = port.link == "up"
		local mbps = linked and number(port.speed) or nil
		result.link[1] = { name = port.port, mode = ethernet_role == "wan" and 1 or 0,
			status = linked and 0 or 1, speed = ({ [10] = 1, [100] = 2, [1000] = 3, [2500] = 4 })[mbps] or 0,
			runtime_meta = { source = "board-port-status", speed_mbps = mbps,
				mode_available = ethernet_role == "wan" or ethernet_role == "lan" } }
	end
	return result
end

return M
