-- APP 3.2 LED management. No modem, network, boot environment or flash I/O.
local fs = require "nixio.fs"
local nixio = require "nixio"
local cursor = require("luci.model.uci").cursor
local sys = require "luci.sys"

local M = {}
local OPTIONS = { "enabled", "schedule_enabled", "schedule_start", "schedule_end" }
local LED_ROOT = "/sys/class/leds"
local LOCK = "/var/lock/c2000max-app-led.lock"
local WORKER_ERROR = "/var/run/c2000max-leds/error"

local function flag(value)
	if value == 0 or value == "0" then return "0" end
	if value == 1 or value == "1" then return "1" end
end

function M.parse_time(value)
	if type(value) ~= "string" then return nil end
	local hour, minute = value:match("^(%d%d?):(%d%d?)$")
	hour, minute = tonumber(hour), tonumber(minute)
	if not hour or hour > 23 or not minute or minute > 59 then return nil end
	return string.format("%02d:%02d", hour, minute), hour * 60 + minute
end

-- Equal boundaries are deliberately not an implicit all-day switch.
-- A manual off is available and has explicit precedence over the timer.
function M.schedule_active(enabled, start_time, end_time, timestamp)
	if flag(enabled) ~= "1" then return false, "disabled" end
	local _, first = M.parse_time(start_time)
	local _, last = M.parse_time(end_time)
	if not first or not last or first == last then return false, "invalid_schedule" end
	timestamp = tonumber(timestamp or os.time()) or 0
	if timestamp < 1704067200 then return false, "clock_not_ready" end
	local now = os.date("*t", timestamp)
	if type(now) ~= "table" or not now.hour or not now.min then
		return false, "clock_not_ready"
	end
	local current = now.hour * 60 + now.min
	if first < last then return current >= first and current < last, "ready" end
	return current >= first or current < last, "ready"
end

local function available_leds()
	local names, iterator = {}, fs.dir(LED_ROOT)
	if iterator then
		for name in iterator do
			if name ~= "." and name ~= ".." and fs.access(LED_ROOT .. "/" .. name .. "/brightness", "w") then
				names[#names + 1] = name
			end
		end
	end
	table.sort(names)
	return names
end

local function read_config(uci)
	local first = uci:get("c2000max", "led", "schedule_start") or "22:00"
	local last = uci:get("c2000max", "led", "schedule_end") or "07:00"
	return {
		enabled = uci:get("c2000max", "led", "enabled") == "0" and "0" or "1",
		schedule_enabled = uci:get("c2000max", "led", "schedule_enabled") == "1" and "1" or "0",
		schedule_start = M.parse_time(first) or first,
		schedule_end = M.parse_time(last) or last
	}
end

local function status(config)
	local names = available_leds()
	local scheduled, clock = M.schedule_active(config.schedule_enabled,
		config.schedule_start, config.schedule_end)
	local effective = config.enabled == "1" and not scheduled
	-- The worker writes a short newline-terminated diagnostic here. Absence
	-- of an error is not proof of physical output: reads remain read-only and
	-- do not start the worker, retry writes or infer success from UCI alone.
	local worker_error = fs.readfile(WORKER_ERROR) or ""
	worker_error = worker_error:gsub("[\r\n]+$", ""):sub(1, 512)
	return {
		code = "0",
		-- APP's switch describes the persistent user's choice, not a timer's
		-- temporary output. Otherwise viewing the page can defeat the timer.
		led = #names > 0 and tonumber(config.enabled) or -1,
		schedule = tonumber(config.schedule_enabled),
		start_time = config.schedule_start,
		end_time = config.schedule_end,
		effective_led = effective and 1 or 0,
		effective_led_source = "policy",
		actual_led = -1,
		actual_led_state = "unknown",
		worker_error = worker_error,
		off_reason = config.enabled == "0" and "manual" or scheduled and "schedule" or "none",
		schedule_status = clock,
		controllable_leds = names,
		control_scope = "linux_led_class"
	}
end

function M.get_status()
	return status(read_config(cursor()))
end

local function failure(message)
	return { code = "2", message = message }
end

local function safe_tf_system()
	local board = (fs.readfile("/tmp/sysinfo/board_name") or ""):gsub("%s+$", "")
	local backing = (fs.readfile("/sys/block/loop0/loop/backing_file") or ""):gsub("%s+$", "")
	return board == "nradio,c2000-max" and backing:match("^/?mmcblk0p6$") ~= nil
end

local function restore_options(uci, old)
	for _, name in ipairs(OPTIONS) do
		if old[name] == nil then uci:delete("c2000max", "led", name)
		else uci:set("c2000max", "led", name, old[name]) end
	end
	return uci:commit("c2000max")
end

local function update(data)
	if not safe_tf_system() then return failure("LED writes require the C2000MAX TF-card system") end
	local worker = fs.readfile("/usr/sbin/c2000max-leds") or ""
	if #worker > 65536 or not ("\n" .. worker .. "\n"):match("\nLED_POLICY_VERSION=2\r?\n") then
		return failure("Matching LED policy worker is not installed; update the companion LED files first")
	end
	if #available_leds() == 0 then return failure("No safely controllable indicator LEDs") end
	local uci = cursor()
	-- Do not commit another LuCI request's staged changes as part of an APP
	-- write. Each APP transaction is serialized, rereads UCI, and only owns
	-- these four options. LuCI itself does not share this advisory lock.
	if type(uci.changes) == "function" then
		local changes = uci:changes("c2000max")
		if type(changes) == "table" and next(changes) then
			return failure("Unapplied board settings exist; apply or discard them first")
		end
	end
	if uci:get("c2000max", "led") ~= "led" then return failure("Board LED configuration is missing") end
	local proposed, old = read_config(uci), {}
	for _, name in ipairs(OPTIONS) do old[name] = uci:get("c2000max", "led", name) end
	for field, name in pairs({ led = "enabled", schedule = "schedule_enabled" }) do
		if data[field] ~= nil then
			local value = flag(data[field])
			if not value then return failure("Invalid " .. field .. "; expected 0 or 1") end
			proposed[name] = value
		end
	end
	for field, name in pairs({ start_time = "schedule_start", end_time = "schedule_end" }) do
		if data[field] ~= nil then
			local value = M.parse_time(data[field])
			if not value then return failure("Invalid " .. field .. "; expected H:M or HH:MM") end
			proposed[name] = value
		end
	end
	if not M.parse_time(proposed.schedule_start) or not M.parse_time(proposed.schedule_end) then
		return failure("Stored LED schedule is invalid; supply valid start_time and end_time")
	end
	if proposed.schedule_enabled == "1" and proposed.schedule_start == proposed.schedule_end then
		return failure("Scheduled off start and end must be different; use the LED switch for all-day off")
	end
	local changed = false
	for _, name in ipairs(OPTIONS) do
		if tostring(old[name] or "") ~= proposed[name] then changed = true end
	end
	if not changed then return status(proposed) end
	for _, name in ipairs(OPTIONS) do
		if not uci:set("c2000max", "led", name, proposed[name]) then
			uci:revert("c2000max")
			return failure("Failed to stage LED configuration")
		end
	end
	if not uci:commit("c2000max") then
		-- A failed commit can leave a partially replaced file on some UCI
		-- backends. Restore the prior owned options, not unrelated settings.
		uci:revert("c2000max")
		uci:unload("c2000max")
		local recovered = restore_options(uci, old)
		return failure(recovered and "Failed to save LED configuration; previous settings restored" or
			"Failed to save and restore LED configuration; check TF-card storage")
	end
	if sys.call("/etc/init.d/c2000max-leds reload >/dev/null 2>&1") ~= 0 then
		uci:unload("c2000max")
		local recovered = restore_options(uci, old)
		if recovered then sys.call("/etc/init.d/c2000max-leds reload >/dev/null 2>&1") end
		return failure(recovered and "LED service reload failed; previous settings restored" or
			"LED service reload and configuration rollback failed")
	end
	return status(proposed)
end

function M.handle(data)
	if type(data) ~= "table" then return failure("Invalid LED request") end
	local setting = data.led ~= nil or data.schedule ~= nil or data.start_time ~= nil or data.end_time ~= nil
	if not setting then return M.get_status() end
	local fd = nixio.open(LOCK, "w", "0600")
	if not fd then return failure("Cannot open LED transaction lock") end
	if not fd:lock("tlock") then fd:close(); return failure("LED configuration is busy; retry shortly") end
	local ok, result = pcall(update, data)
	fd:lock("ulock")
	fd:close()
	return ok and result or failure("LED configuration transaction failed")
end

return M
