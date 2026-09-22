-- Explicit, default-off APP 3.2 plaintext signal compatibility. This is not
-- an authentication bypass for general APP actions or a generic core proxy.
local M = {}
local core = require "c2000max_app.core"

local fields = {}
for name in ("signal mode netlink net_type nrcap sim simno simtype simcount " ..
	"switchmode isp operator_name imsi iccid imei model revision band band_count " ..
	"DLBW ULBW dlbw ulbw earfcn pci dl_pci dl_fcn ul_fcn rsrp rsrq sinr rssi " ..
	"rscp lac tac cellid cell CQI NR5G_AMBR_DL NR5G_AMBR_UL using cpeno"):gmatch("%S+") do
	fields[name] = true
end
for index = 1, 8 do
	for name in ("band DLBW earfcn dl_fcn pci dl_pci dl_mode"):gmatch("%S+") do
		fields[name .. index] = true
	end
end
local measured = {}
for name in ("signal rsrp rsrq sinr rssi rscp tac TAC pci PCI cell cellid mode band earfcn"):gmatch("%S+") do
	measured[name] = true
end
local quality = { signal=true, rsrp=true, rsrq=true, sinr=true, rssi=true, rscp=true }

local function project(source, allowed)
	local result = {}
	if type(source) ~= "table" then return result end
	for name in pairs(allowed) do
		local value = source[name]
		local kind = type(value)
		local scalar = kind == "boolean" or
			(kind == "string" and #value <= 256) or
			(kind == "number" and value == value and value ~= math.huge and value ~= -math.huge)
		-- Preserve genuine zero measurements, but not the internal missing-data
		-- sentinel, which the APP otherwise renders as an actual -999 dBm.
		if scalar and not (quality[name] and tonumber(value) == -999) then
			result[name] = value
		end
	end
	return result
end

function M.response(data, context)
	if not core.local_enabled() or core.local_protocol_mode() ~= "modern" or
	   not core.feature_enabled("local_signal_enable") or
	   not core.feature_enabled("local_signal_public_enable") or
	   core.management_password_configured() then
		return nil
	end
	-- Native uni.request does not require browser CORS. Never disclose this
	-- opt-in data to a browser-origin request (including opaque/null origins).
	-- Existing authenticated API calls remain available to browser clients.
	if type(context) ~= "table" or context.plaintext ~= true or
	   (context.origin ~= nil and context.origin ~= "") or
	   not require("c2000max_app.lan_boundary").allowed(context) then
		return nil
	end
	data = type(data) == "table" and data or {}
	if data.index ~= nil and type(data.index) ~= "number" and
	   type(data.index) ~= "string" then return nil end
	local index = data.index == nil and 1 or tonumber(data.index)
	if not index or index % 1 ~= 0 or index < 1 or index > 8 then return nil end
	-- Only read arguments cross this boundary, never user-supplied commands,
	-- paths, modes, actions, credentials or arbitrary nested values.
	local query = { index = index }
	local focused = tonumber(data.at_signal) == 1
	if not core.local_action_allowed("signal", query) then return nil end
	local ok, raw = pcall(core.handle, "signal", query, { source = "local" })
	if not ok or type(raw) ~= "table" or tostring(raw.code) ~= "0" then return nil end
	local device_id = core.device_id()
	if type(device_id) ~= "string" or device_id == "" or #device_id > 64 then return nil end
	local result = { code = "0", signal = {} }
	if type(data.trans_id) == "string" and #data.trans_id <= 128 then
		result.trans_id = data.trans_id
	end
	for i = 1, 8 do
		local item = type(raw.signal) == "table" and raw.signal[i] or nil
		if type(item) ~= "table" then break end
		result.signal[i] = project(item, fields)
	end
	result.signal[1] = result.signal[1] or {}
	result.signal[1].mac = device_id
	result.signal[1].id = device_id
	if focused then
		query.at_signal = 1
		if core.local_action_allowed("signal", query) then
			local measured_ok, sample = pcall(core.handle, "signal", query, { source = "local" })
			if measured_ok and type(sample) == "table" and tostring(sample.code) == "0" then
				result.at_signal = project(sample.at_signal, measured)
			end
		end
	end
	-- Even focused measurements retain signal[0].mac/id: APP re-probes AES
	-- capability for this path before merging the top-level at_signal object.
	return result
end

return M
