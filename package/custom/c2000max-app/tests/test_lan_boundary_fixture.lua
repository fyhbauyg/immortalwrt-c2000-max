-- Pure local fixture: no sockets, files, ubus daemon or router are contacted.
local helper = assert(arg[1], "lan_boundary.lua path required")
local function clone(value)
	if type(value) ~= "table" then return value end
	local out = {}; for k, v in pairs(value) do out[k] = clone(v) end; return out
end
local function ipv4(value)
	if not value:match("^%d+%.%d+%.%d+%.%d+$") then return nil end
	local out = {}
	for token in value:gmatch("%d+") do
		local byte = tonumber(token); if byte > 255 then return nil end
		out[#out + 1] = byte
	end
	return out
end
local function ipv6(value)
	local v4 = value:match("([%d.]+)$")
	if v4 and v4:find(".", 1, true) then
		local bytes = ipv4(v4); if not bytes then return nil end
		value = value:sub(1, #value - #v4) .. string.format("%x:%x",
			bytes[1] * 256 + bytes[2], bytes[3] * 256 + bytes[4])
	end
	local left, right = value:match("^(.-)::(.-)$")
	if right and right:find("::", 1, true) then return nil end
	local function groups(part)
		local out = {}
		if part == "" then return out end
		if part:sub(1, 1) == ":" or part:sub(-1) == ":" then return nil end
		for token in part:gmatch("[^:]+") do
			if not token:match("^%x+$") or #token > 4 then return nil end
			out[#out + 1] = tonumber(token, 16)
		end
		return out
	end
	local words
	if left then
		local a, b = groups(left), groups(right)
		if not a or not b or #a + #b >= 8 then return nil end
		words = a
		for _ = 1, 8 - #a - #b do words[#words + 1] = 0 end
		for _, word in ipairs(b) do words[#words + 1] = word end
	else words = groups(value) end
	if not words or #words ~= 8 then return nil end
	local bytes = {}
	for _, word in ipairs(words) do
		bytes[#bytes + 1] = math.floor(word / 256); bytes[#bytes + 1] = word % 256
	end
	return bytes
end
local ip = {}
local methods = {}
function ip.new(value)
	if type(value) ~= "string" then return nil end
	local host, prefix = value:match("^([^/]+)/(%d+)$")
	host = host or value
	local bytes = ipv4(host) or ipv6(host)
	if not bytes then return nil end
	local bits = #bytes * 8
	local mask = prefix and tonumber(prefix) or bits
	if mask > bits then return nil end
	return setmetatable({ bytes = bytes, mask = mask, host = host }, { __index = methods })
end
function methods:is4() return #self.bytes == 4 end
function methods:is6() return #self.bytes == 16 end
function methods:is6mapped4()
	if not self:is6() then return false end
	for i = 1, 10 do if self.bytes[i] ~= 0 then return false end end
	return self.bytes[11] == 255 and self.bytes[12] == 255
end
function methods:contains(other)
	if #self.bytes ~= #other.bytes or self.mask > other.mask then return false end
	local left = self.mask
	for i = 1, #self.bytes do
		local use = math.min(left, 8)
		local divisor = 2 ^ (8 - use)
		if math.floor(self.bytes[i] / divisor) ~= math.floor(other.bytes[i] / divisor) then return false end
		left = left - use
		if left == 0 then return true end
	end
	return true
end
function methods:equal(other)
	return self.mask == other.mask and self:contains(other)
end
function methods:string() return self.host end

local baseline = {
	up = true, l3_device = "br-lan",
	["ipv4-address"] = { { address = "192.168.66.1", mask = 24 } },
	["ipv6-address"] = { { address = "fd12:3456:789a:1::1", mask = 64 } },
	["ipv6-prefix-assignment"] = {
		{ address = "2001:db8:ab00::", mask = 56,
			["local-address"] = { address = "2001:db8:ab00:2::1", mask = 64 } }
	}
}
local lan, route, ubus_fail, route_fail, ubus_calls, route_calls
local function reset()
	lan = clone(baseline)
	route = { type = 1, dev = "br-lan" }
	ubus_fail, route_fail, ubus_calls, route_calls = false, false, 0, 0
end
ip.route = function(destination, source)
	route_calls = route_calls + 1
	assert(ip.new(destination) and ip.new(source), "route requires parsed actual addresses")
	if route_fail then error("fixture netlink unavailable") end
	return clone(route)
end
package.loaded["luci.ip"] = ip
package.loaded["luci.util"] = { ubus = function(object, method, args)
	ubus_calls = ubus_calls + 1
	assert(object == "network.interface.lan" and method == "status" and next(args) == nil)
	if ubus_fail then error("fixture ubus unavailable") end
	return clone(lan)
end }
local boundary = dofile(helper)
local count = 0
local function check(name, expected, context)
	count = count + 1
	local ok, actual = pcall(boundary.allowed, context)
	assert(ok, name .. " must not throw")
	assert(actual == expected, name .. " expected " .. tostring(expected) .. " got " .. tostring(actual))
end
local function pair(peer, server)
	return { remote_addr = peer, server_addr = server or "192.168.66.1" }
end
reset()
check("wired or wireless current IPv4 LAN", true, pair("192.168.66.142"))
check("ULA LAN IPv6", true, pair("fd12:3456:789a:1::abc", "fd12:3456:789a:1::1"))
check("assigned global LAN IPv6", true, pair("2001:db8:ab00:2::abcd", "2001:db8:ab00:2::1"))
check("same delegated /56 but outside LAN /64", false, pair("2001:db8:ab00:3::abc", "2001:db8:ab00:2::1"))
check("out of subnet private WAN", false, pair("192.168.0.15"))
check("private guest segment", false, pair("192.168.67.15"))
check("public Internet source", false, pair("198.51.100.7"))
check("LAN source with WAN destination", false, pair("192.168.66.142", "192.168.0.2"))
check("LAN source with non-router LAN destination", false, pair("192.168.66.142", "192.168.66.99"))
check("mixed address families", false, pair("fd12:3456:789a:1::abc"))
local forged = pair("198.51.100.7")
forged["x-forwarded-for"] = "192.168.66.142"
forged.headers = { ["X-Forwarded-For"] = "192.168.66.142", ["X-Real-IP"] = "192.168.66.142" }
check("untrusted proxy headers do not replace peer", false, forged)
check("header-only context rejected", false, { headers = forged.headers })
check("no context", false, nil)
check("string context", false, "192.168.66.142")
for _, bad in ipairs({ "", "127.0.0.1", "0.0.0.0", "224.0.0.1", "255.255.255.255",
	"169.254.1.2", "::", "::1", "fe80::1", "fe80::1%br-lan", "ff02::1", "::ffff:192.168.66.142",
	"::ffff:127.0.0.1", "192.168.66.142/24", "192.168.66.142 ", " 192.168.66.142",
	"192.168.66.142\n", "192.168.66.142\0", "192.168.66.999", "192.168.66.142:80", "[::1]",
	"00:11:22:33:44:55", "localhost", "192.168.66.142, 198.51.100.7" }) do
	check("invalid or excluded source " .. bad, false, pair(bad))
end

lan["ipv4-address"] = { { address = "192.168.0.1", mask = 24 } }
check("new LAN addresses accepted without reload", true, pair("192.168.0.15", "192.168.0.1"))
check("old LAN addresses expire without reload", false, pair("192.168.66.142"))
assert(ubus_calls >= 10, "LAN status must not be permanently cached")
reset(); lan.up = false
check("down LAN", false, pair("192.168.66.142"))
reset(); lan.up = "true"
check("malformed LAN up value", false, pair("192.168.66.142"))
reset(); lan.l3_device = "lo"
check("loopback LAN device", false, pair("192.168.66.142"))
reset(); lan.l3_device = nil
check("missing LAN device", false, pair("192.168.66.142"))
reset(); lan.l3_device = "br-lan;invalid"
check("invalid LAN device", false, pair("192.168.66.142"))
for _, mask in ipairs({ -1, 0, 33, 23.5, "24", "255.255.255.0" }) do
	reset(); lan["ipv4-address"][1].mask = mask
	check("malformed IPv4 mask " .. tostring(mask), false, pair("192.168.66.142"))
end
reset(); lan["ipv4-address"][1].mask = nil
check("missing mask", false, pair("192.168.66.142"))
reset(); lan["ipv6-prefix-assignment"][1]["local-address"] = nil
check("delegated prefix alone grants no access", false, pair("2001:db8:ab00:2::abcd", "2001:db8:ab00:2::1"))
reset(); lan = nil
check("missing netifd reply", false, pair("192.168.66.142"))
reset(); ubus_fail = true
check("ubus exception fails closed", false, pair("192.168.66.142"))
reset(); route_fail = true
check("route exception fails closed", false, pair("192.168.66.142"))
reset(); route = nil
check("missing route fails closed", false, pair("192.168.66.142"))
reset(); route.type = 2; route.dev = "lo"
check("router self request rejected", false, pair("192.168.66.1"))
reset(); route.type = 7
check("unreachable route rejected", false, pair("192.168.66.142"))
reset(); route.dev = "eth1"
check("overlapping WAN prefix rejected by route device", false, pair("192.168.66.142"))
reset(); route.gw = "192.168.66.2"
check("routed source rather than direct LAN rejected", false, pair("192.168.66.142"))
reset(); route.type = "1"
check("malformed route rejected", false, pair("192.168.66.142"))
reset(); local real_new = ip.new; ip.new = function() error("fixture IP library failure") end
check("IP parse exception fails closed", false, pair("192.168.66.142"))
ip.new = real_new
reset(); local good_ip, good_util = package.loaded["luci.ip"], package.loaded["luci.util"]
package.loaded["luci.ip"] = true
local unavailable = dofile(helper)
count = count + 1; assert(unavailable.allowed(pair("192.168.66.142")) == false, "unavailable IP module")
package.loaded["luci.ip"] = good_ip; package.loaded["luci.util"] = true
unavailable = dofile(helper)
count = count + 1; assert(unavailable.allowed(pair("192.168.66.142")) == false, "unavailable util module")
package.loaded["luci.util"] = good_util
print("LAN boundary fixture PASS (" .. count .. " assertions)")
