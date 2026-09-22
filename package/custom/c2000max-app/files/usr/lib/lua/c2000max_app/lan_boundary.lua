-- The caller supplies socket/CGI addresses, never request fields or proxy headers.
-- This is an additional application check, not a replacement for WAN firewalling.
local ip_ok, ip = pcall(require, "luci.ip")
local util_ok, util = pcall(require, "luci.util")
local M = {}

local function address(value)
	if type(value) ~= "string" or #value == 0 or #value > 64 or
	   not value:match("^[%x:.]+$") then
		return nil
	end
	local parsed = ip.new(value)
	if not parsed or (not parsed:is4() and not parsed:is6()) then
		return nil
	end
	local excluded
	if parsed:is4() then
		excluded = { "0.0.0.0/8", "127.0.0.0/8", "169.254.0.0/16", "224.0.0.0/3" }
	else
		-- Scoped/link-local addresses cannot establish the input interface here.
		if parsed:is6mapped4() then return nil end
		excluded = { "::/128", "::1/128", "fe80::/10", "ff00::/8" }
	end
	for _, range in ipairs(excluded) do
		if ip.new(range):contains(parsed) then return nil end
	end
	return parsed
end

local function matches(entry, peer, server)
	if type(entry) ~= "table" or type(entry.mask) ~= "number" then return false end
	local local_ip = address(entry.address)
	if not local_ip or not local_ip:equal(server) then return false end
	local mask = entry.mask
	local bits = local_ip:is4() and 32 or 128
	if mask < 1 or mask > bits or mask ~= math.floor(mask) then return false end
	local network = ip.new(entry.address .. "/" .. tostring(mask))
	return network and network:contains(peer) or false
end

local function check(context)
	if not ip_ok or not util_ok or type(ip) ~= "table" or type(util) ~= "table" or
	   type(context) ~= "table" then return false end
	local peer = address(context.remote_addr)
	local server = address(context.server_addr)
	if not peer or not server or peer:is4() ~= server:is4() then return false end

	-- Read current netifd state for every request. Old LAN subnets must stop
	-- authorizing anonymous reads immediately after a LAN address change.
	local lan = util.ubus("network.interface.lan", "status", {})
	if type(lan) ~= "table" or lan.up ~= true or type(lan.l3_device) ~= "string" or
	   #lan.l3_device == 0 or #lan.l3_device > 64 or lan.l3_device == "lo" or
	   not lan.l3_device:match("^[%w_.:%-]+$") then return false end
	local matched = false
	for _, key in ipairs({ "ipv4-address", "ipv6-address" }) do
		if type(lan[key]) == "table" then
			for _, entry in ipairs(lan[key]) do
				if matches(entry, peer, server) then matched = true; break end
			end
		end
	end
	if not matched and type(lan["ipv6-prefix-assignment"]) == "table" then
		for _, entry in ipairs(lan["ipv6-prefix-assignment"]) do
			-- Match the actual LAN /64, not a larger delegated WAN /56.
			if type(entry) == "table" and matches(entry["local-address"], peer, server) then
				matched = true
				break
			end
		end
	end
	if not matched then return false end

	-- A subnet match alone is unsafe with overlapping WAN/LAN prefixes or
	-- policy routes. Require a direct unicast return path over the LAN device.
	local route = ip.route(peer:string(), server:string())
	return type(route) == "table" and route.type == 1 and
		route.dev == lan.l3_device and route.gw == nil
end

function M.allowed(context)
	local ok, allowed = pcall(check, context)
	return ok and allowed == true
end

return M
