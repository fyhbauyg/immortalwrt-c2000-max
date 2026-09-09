local root = assert(arg[1], "package root required")
package.path = root .. "/files/usr/lib/lua/?.lua;" .. package.path
local rows, statuses, files, queried = {}, {}, {}, {}
local function row(package_name, name, kind, values)
	rows[package_name] = rows[package_name] or {}
	values = values or {}
	values[".name"], values[".type"] = name, kind
	rows[package_name][name] = values
end
local cursor = {}
function cursor:get(package_name, name, option)
	local value = rows[package_name] and rows[package_name][name]
	return value and value[option or ".type"] or nil
end
function cursor:get_all(package_name, name)
	return rows[package_name] and rows[package_name][name] or nil
end
function cursor:foreach(package_name, kind, callback)
	for _, value in pairs(rows[package_name] or {}) do
		if value[".type"] == kind then callback(value) end
	end
end
package.loaded["luci.model.uci"] = { cursor = function() return cursor end }
package.loaded["nixio.fs"] = { readfile = function(path)
	assert(not path:find("%.%./"), "must never traverse paths")
	local value = files[path]
	return type(value) == "function" and value() or value
end }
package.loaded["luci.util"] = { ubus = function(object, method)
	assert(method == "status" and object:match("^network%.interface%."), "no AT/QModem or unrelated service queries")
	queried[#queried + 1] = object
	return statuses[object:sub(#"network.interface." + 1)]
end }
package.loaded["nixio"] = {}
package.loaded["luci.jsonc"] = {}
package.loaded["luci.sys"] = {}
package.loaded["c2000max_app.identity"] = {}
local stats = require "c2000max_app.netstats"

local function device(name, tx, rx, index)
	local base = "/sys/class/net/" .. name .. "/"
	files[base .. "ifindex"] = tostring(index or 7) .. "\n"
	files[base .. "statistics/tx_bytes"] = tostring(tx) .. "\n"
	files[base .. "statistics/rx_bytes"] = tostring(rx) .. "\n"
	files[base .. "statistics/tx_packets"] = "300\n"
	files[base .. "statistics/rx_packets"] = "400\n"
end
local function available(name, expected_device, tx, rx)
	local value = stats.read(name)
	assert(value.available, name .. " must be available: " .. tostring(value.reason))
	assert(value.name == name and value.device == expected_device)
	assert(value.tx_bytes == tx and value.rx_bytes == rx, "preserve exact cumulative counters")
	assert(value.tx_packets == 300 and value.rx_packets == 400)
	assert(#value.list == 1 and value.list[1].name == name)
	assert(value.list[1].upload == tx and value.list[1].download == rx)
	return value
end
local function unavailable(name)
	local value = stats.read(name)
	assert(value.available == false and #value.list == 0 and value.reason)
	assert(value.tx_bytes == nil and value.rx_bytes == nil, "unavailable must not fabricate zero counters")
end

device("eth2", 123456789, 987654321)
device("br-lan", 800000, 500000)
available("eth2", "eth2", 123456789, 987654321)
row("network", "lan", "interface", { device = "br-lan" })
available("lan", "br-lan", 800000, 500000)
device("pppoe-uplink", 1024000, 8192000, 18)
row("network", "c2000_wan", "interface", { device = "eth2", proto = "pppoe" })
statuses.c2000_wan = { device = "eth2", l3_device = "pppoe-uplink", up = true }
row("c2000max", "ethernet", "ethernet", { wan4 = "c2000_wan" })
available("c2000_wan", "pppoe-uplink", 1024000, 8192000)
available("wan", "pppoe-uplink", 1024000, 8192000)
statuses.dynamic_uplink = { l3_device = "eth2", up = true }
available("dynamic_uplink", "eth2", 123456789, 987654321)

device("rmnet0", 222222222, 888888888, 30)
device("rmnet1", 333333333, 777777777, 31)
row("qmodem", "modem_a", "modem-device", { alias = "cell_a" })
row("qmodem", "modem_b", "modem-device", { alias = "cell_b" })
row("network", "cell_a", "interface", { modem_config = "modem_a" })
row("network", "cell_a6", "interface", { modem_config = "modem_a" })
row("network", "cell_b", "interface", { modem_config = "modem_b" })
statuses.cell_a = { l3_device = "rmnet0" }; statuses.cell_a6 = { l3_device = "rmnet0" }
statuses.cell_b = { l3_device = "rmnet1" }
available("modem_a", "rmnet0", 222222222, 888888888)
available("modem_b", "rmnet1", 333333333, 777777777)
unavailable("cpe1") -- Never assume cpe1 is the first configured modem.
statuses.cell_a6 = { l3_device = "rmnet1" }
unavailable("modem_a") -- Distinct owned interfaces must not be mixed.
statuses.cell_a6 = { l3_device = "rmnet0" }
rows.qmodem.modem_a.state = "disabled"
unavailable("modem_a")
rows.qmodem.modem_a.state = nil

row("qmodem", "explicit_modem", "modem-device", { network_interface = "rmnet1" })
available("explicit_modem", "rmnet1", 333333333, 777777777)
row("qmodem", "bad_alias", "modem-device", { alias = "cell_b" })
unavailable("bad_alias") -- Alias already owned by a different modem.
row("network", "multi", "interface", { ifname = "eth2 rmnet0" })
unavailable("multi")
unavailable("missing")
unavailable("../../etc/shadow")
unavailable({ "eth2" })
unavailable(1)
unavailable("")
unavailable(string.rep("a", 65))
files["/sys/class/net/eth2/statistics/rx_bytes"] = nil
unavailable("eth2")
files["/sys/class/net/eth2/statistics/rx_bytes"] = "9007199254740992"
unavailable("eth2") -- JS cannot safely subtract counters larger than 2^53-1.
files["/sys/class/net/eth2/statistics/rx_bytes"] = "invalid"
unavailable("eth2")
device("eth2", 0, 0)
available("eth2", "eth2", 0, 0) -- Real zero is valid, a failed read is not.
local reads = 0
files["/sys/class/net/eth2/ifindex"] = function() reads = reads + 1; return tostring(reads) end
unavailable("eth2") -- Hotplug replacement within the sample.
device("eth2", 123456789, 987654321)

-- Exercise actual core response wrapping, not just the helper's envelope.
local core = require "c2000max_app.core"
local response = core.handle("speed", { name = "c2000_wan", trans_id = "speed-fixture" })
assert(response.code == "0" and response.trans_id == "speed-fixture")
assert(response.result.list[1].name == "c2000_wan")
assert(response.result.tx_bytes == 1024000 and response.result.list[1].upload == 1024000)
local missing = core.handle("speed", { name = "not-present" })
assert(missing.code == "2" and missing.result.available == false)
assert(missing.result.rx_bytes == nil)
local legacy = core.handle("speed", {})
assert(legacy.code == "0" and legacy.result.name == "br-lan" and legacy.result.tx_bytes == 800000)
print("PASS: netstats exact counters, WAN/LAN/PPP/QModem mapping, no cross-modem sums, unavailable/overflow/hotplug, core envelopes")
