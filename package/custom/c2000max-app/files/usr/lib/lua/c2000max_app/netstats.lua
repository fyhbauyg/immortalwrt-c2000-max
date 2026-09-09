-- APP /speed is a cumulative-counter API, not a speed multiplier. Resolving
-- netifd/QModem names is read-only and must not trigger any modem AT query.
local fs = require "nixio.fs"
local uci = require("luci.model.uci").cursor()
local util = require "luci.util"
local M = {}
local MAX_EXACT_INTEGER = 9007199254740991

local function valid_name(value, maximum)
	return type(value) == "string" and #value <= (maximum or 64) and
		value:match("^[A-Za-z0-9_][A-Za-z0-9_.:%-]*$") ~= nil
end

local function scalar(value)
	return valid_name(value) and value or nil
end

local function netif_status(name)
	if not valid_name(name) then return {} end
	local ok, result = pcall(util.ubus, "network.interface." .. name, "status", {})
	return ok and type(result) == "table" and result or {}
end

local function netif_device(name)
	local status = netif_status(name)
	-- l3_device is essential for PPP/VLAN setups: lower-device traffic may
	-- include other logical interfaces and is not the requested WAN counter.
	local device = scalar(status.l3_device) or scalar(status.device)
	if not device and uci:get("network", name) == "interface" then
		device = scalar(uci:get("network", name, "device")) or
			scalar(uci:get("network", name, "ifname"))
	end
	if device and valid_name(device, 15) then return device end
	return nil
end

local function modem_device(name)
	if uci:get("qmodem", name) ~= "modem-device" then return nil, false end
	local section = uci:get_all("qmodem", name) or {}
	if section.state == "disabled" then return nil, true end
	local devices = {}
	local declared = false
	-- QModem writes modem_config onto its netifd sections. Use that explicit
	-- ownership rather than assuming that cpe1/wwan0 belongs to the first SIM.
	uci:foreach("network", "interface", function(network)
		if network.modem_config == name and valid_name(network[".name"]) then
			declared = true
			local device = netif_device(network[".name"])
			if device then devices[device] = true end
		end
	end)
	local device, count = nil, 0
	for candidate in pairs(devices) do device, count = candidate, count + 1 end
	if declared then
		-- IPv4/IPv6 may name the same device. Distinct data interfaces are not
		-- silently summed or arbitrarily selected for one APP modem.
		return count == 1 and device or nil, true
	end
	local alias = scalar(section.alias)
	if alias then
		local owner = uci:get("network", alias, "modem_config")
		if owner and owner ~= name then return nil, true end
		device = netif_device(alias)
		if device then return device, true end
	end
	device = scalar(section.network_interface) or scalar(section.interface)
	if device then
		if uci:get("network", device) == "interface" then
			local owner = uci:get("network", device, "modem_config")
			if owner and owner ~= name then return nil, true end
			return netif_device(device), true
		end
		return valid_name(device, 15) and device or nil, true
	end
	return nil, true
end

local function resolve(name)
	local device, modem = modem_device(name)
	if modem then return device end
	if uci:get("network", name) == "interface" then return netif_device(name) end
	if name == "wan" then
		local configured = scalar(uci:get("c2000max", "ethernet", "wan4"))
		if configured and uci:get("network", configured) == "interface" then
			return netif_device(configured)
		end
	end
	-- Also support netifd-created dynamic interfaces absent from UCI. Only
	-- their own reported l3/device is accepted; no guessed LAN/WAN fallback.
	device = netif_device(name)
	return device or (valid_name(name, 15) and name or nil)
end

local function read_integer(path)
	local raw = fs.readfile(path)
	if type(raw) ~= "string" then return nil end
	raw = raw:match("^%s*(%d+)%s*$")
	local value = raw and tonumber(raw) or nil
	if not value or value < 0 or value > MAX_EXACT_INTEGER or
	   value ~= math.floor(value) then return nil end
	return value
end

function M.read(name)
	local result = {
		name = type(name) == "string" and name or "",
		available = false,
		source = "sysfs-interface-counters",
		list = {}
	}
	if not valid_name(name) then
		result.reason = "invalid interface name"
		return result
	end
	local device = resolve(name)
	if not device then
		result.reason = "interface mapping unavailable or ambiguous"
		return result
	end
	local base = "/sys/class/net/" .. device .. "/"
	local ifindex = read_integer(base .. "ifindex")
	local counters = {}
	for _, field in ipairs({ "rx_bytes", "tx_bytes", "rx_packets", "tx_packets" }) do
		counters[field] = read_integer(base .. "statistics/" .. field)
		if counters[field] == nil then
			result.reason = "interface counters unavailable"
			return result
		end
	end
	if not ifindex or ifindex == 0 or ifindex ~= read_integer(base .. "ifindex") then
		result.reason = "interface changed during sample"
		return result
	end
	result.available = true
	result.device = device
	result.ifindex = ifindex
	result.updated = os.time()
	result.unit = "bytes"
	result.direction = "device-tx-rx"
	for key, value in pairs(counters) do result[key] = value end
	result.list = { {
		name = name,
		upload = counters.tx_bytes,
		download = counters.rx_bytes
	} }
	return result
end

return M
