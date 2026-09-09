local root = assert(arg[1], "package root required")
package.path = root .. "/files/usr/lib/lua/?.lua;" .. package.path
local stored, pending, calls, commits, board, backing, led_names, changes, busy, commit_fail, stage_fail, reload_fail
local worker_source, worker_error, lock_opens
local now_hour, now_minute, now_stamp, locked = 12, 0, 1788912000, false
local raw_time, raw_date = os.time, os.date
os.time = function() return now_stamp end
os.date = function(fmt, timestamp)
	assert(fmt == "*t")
	return { hour = now_hour, min = now_minute, year = 2026, month = 9, day = 9 }
end
local function copy(t) local rv = {}; for k, v in pairs(t) do rv[k] = v end; return rv end
local function reset()
	stored = { enabled = "1", interval = "15", weak_rsrp = "-90", good_rsrp = "-80", fan_unrelated = "keep" }
	pending, calls, commits = {}, {}, 0
	board, backing = "nradio,c2000-max\n", "/mmcblk0p6\n"
	led_names = { "blue:sig1", "blue:sig2", "blue:sig3", "blue:status", "red:error" }
	changes, busy, commit_fail, stage_fail, reload_fail = {}, false, 0, false, 0
	now_hour, now_minute, now_stamp, locked = 12, 0, 1788912000, false
	worker_source, worker_error, lock_opens = "LED_POLICY_VERSION=2\n", nil, 0
end
package.preload["nixio.fs"] = function() return {
	readfile = function(path)
		if path == "/tmp/sysinfo/board_name" then return board end
		if path == "/sys/block/loop0/loop/backing_file" then return backing end
		if path == "/usr/sbin/c2000max-leds" then return worker_source end
		if path == "/var/run/c2000max-leds/error" then return worker_error end
		error("unapproved file read: " .. path)
	end,
	dir = function(path)
		assert(path == "/sys/class/leds")
		local index = 0
		return function() index = index + 1; return led_names[index] end
	end,
	access = function(path, mode) assert(mode == "w" and path:match("^/sys/class/leds/[^/]+/brightness$")); return true end
} end
package.preload["nixio"] = function() return {
	open = function(path, mode, permissions)
		assert(path == "/var/lock/c2000max-app-led.lock" and mode == "w" and permissions == "0600")
		lock_opens = lock_opens + 1
		return {
			lock = function(_, op)
				if op == "tlock" then if busy or locked then return false end; locked = true; return true end
				assert(op == "ulock"); locked = false; return true
			end,
			close = function() return true end
		}
	end
} end
package.preload["luci.model.uci"] = function() return {
	cursor = function()
		return {
			get = function(_, package, section, name)
				assert(package == "c2000max" and section == "led")
				if name == nil then return "led" end
				return stored[name]
			end,
			set = function(_, package, section, name, value)
				assert(package == "c2000max" and section == "led" and locked)
				if stage_fail then return false end
				pending[name] = value; return true
			end,
			delete = function(_, package, section, name) pending[name] = false; return true end,
			commit = function(_, package)
				assert(package == "c2000max" and locked)
				commits = commits + 1
				for k, v in pairs(pending) do stored[k] = v or nil end
				pending = {}
				if commit_fail > 0 then commit_fail = commit_fail - 1; return false end
				return true
			end,
			revert = function() pending = {}; return true end,
			unload = function() return true end,
			changes = function() return changes end
		}
	end
} end
package.preload["luci.sys"] = function() return {
	call = function(command)
		assert(command == "/etc/init.d/c2000max-leds reload >/dev/null 2>&1")
		calls[#calls + 1] = command
		if reload_fail > 0 then reload_fail = reload_fail - 1; return 1 end
		return 0
	end
} end
local led = require "c2000max_app.led"
local count = 0
local function eq(actual, expected, label)
	if actual ~= expected then error((label or "value") .. ": expected " .. tostring(expected) .. ", got " .. tostring(actual)) end
	count = count + 1
end
reset()
local response = led.handle({ trans_id = "query" })
eq(response.led, 1, "legacy manual switch default")
eq(response.schedule, 0, "timer is opt-in")
eq(response.start_time, "22:00"); eq(response.end_time, "07:00")
eq(#response.controllable_leds, 5); eq(commits, 0); eq(#calls, 0)
eq(response.effective_led, 1); eq(response.effective_led_source, "policy")
eq(response.actual_led, -1); eq(response.actual_led_state, "unknown")
eq(response.worker_error, ""); eq(lock_opens, 0, "query never opens the write lock")
worker_error = "Some LED states could not be restored; snapshots retained for retry\n"
response = led.handle({ trans_id = "read-error" })
eq(response.led, 1); eq(response.effective_led, 1, "compatibility field remains desired policy")
eq(response.effective_led_source, "policy"); eq(response.actual_led, -1)
eq(response.actual_led_state, "unknown")
eq(response.worker_error, "Some LED states could not be restored; snapshots retained for retry")
eq(commits, 0); eq(#calls, 0); eq(lock_opens, 0, "error query must not retry hardware or write configuration")
worker_error = string.rep("x", 1000) .. "\r\n"
eq(#led.get_status().worker_error, 512, "worker diagnostic is bounded")
worker_error = nil
eq(led.get_status().actual_led, -1, "no error file does not prove physical success")
for _, source in ipairs({ "LED_POLICY_VERSION=20\n", "# LED_POLICY_VERSION=2\n", "echo LED_POLICY_VERSION=2\n", "OTHER_LED_POLICY_VERSION=2\n" }) do
	reset(); worker_source = source
	response = led.handle({ led = 0 })
	eq(response.code, "2", "only exact worker policy version 2 is accepted")
	eq(commits, 0); eq(#calls, 0)
end
for _, source in ipairs({ "LED_POLICY_VERSION=2", "#!/bin/sh\nLED_POLICY_VERSION=2\n", "#!/bin/sh\r\nLED_POLICY_VERSION=2\r\n" }) do
	reset(); worker_source = source
	eq(led.handle({ led = 0 }).code, "0", "standalone version line supports LF/CRLF")
end
reset()
for input, expected in pairs({ ["22:0"] = "22:00", ["7:0"] = "07:00", ["0:5"] = "00:05", ["23:59"] = "23:59" }) do
	eq(led.parse_time(input), expected, "APP time normalization")
end
for _, bad in ipairs({ "24:00", "12:60", "-1:00", "0:000", "000:0", "2:4;reboot", " 2:4", "2:4\n", "", "12", "12:3:4" }) do
	eq(led.parse_time(bad), nil, "invalid time")
end
for _, bad in ipairs({ -1, 2, "yes", true, {}, "1;reboot" }) do
	reset(); eq(led.handle({ led = bad }).code, "2"); eq(commits, 0); eq(locked, false)
end
reset()
now_hour, now_minute = 23, 0
response = led.handle({ led = 1, schedule = 1, start_time = "22:0", end_time = "7:0" })
eq(response.code, "0"); eq(response.led, 1, "timer never changes persistent switch")
eq(response.effective_led, 0); eq(response.off_reason, "schedule")
eq(stored.enabled, "1"); eq(stored.schedule_start, "22:00"); eq(stored.schedule_end, "07:00")
eq(stored.interval, "15"); eq(stored.fan_unrelated, "keep"); eq(commits, 1); eq(#calls, 1)
response = led.handle({ led = "1", schedule = "1", start_time = "22:00", end_time = "07:00" })
eq(response.code, "0"); eq(commits, 1, "idempotent save does not wear TF storage")
for _, sample in ipairs({ { 21, 59, false }, { 22, 0, true }, { 23, 59, true }, { 0, 0, true }, { 6, 59, true }, { 7, 0, false } }) do
	now_hour, now_minute = sample[1], sample[2]
	eq(led.schedule_active(1, "22:00", "07:00"), sample[3], "overnight boundary")
end
for _, sample in ipairs({ { 7, 59, false }, { 8, 0, true }, { 12, 0, true }, { 18, 0, false } }) do
	now_hour, now_minute = sample[1], sample[2]
	eq(led.schedule_active(1, "08:00", "18:00"), sample[3], "same-day boundary")
end
now_hour, now_minute = 23, 0
eq(led.schedule_active(0, "22:00", "07:00"), false)
eq(led.schedule_active(1, "22:00", "22:00"), false)
eq(led.schedule_active(1, "bad", "07:00"), false)
eq(led.schedule_active(1, "22:00", "07:00", 0), false, "boot clock not ready")
now_stamp = 0
response = led.get_status(); eq(response.effective_led, 1); eq(response.schedule_status, "clock_not_ready")
now_stamp = 1788912000
response = led.get_status(); eq(response.effective_led, 0, "clock synchronization applies saved rule")
response = led.handle({ led = 0, schedule = 0 })
eq(response.led, 0); eq(response.effective_led, 0); eq(response.off_reason, "manual")
eq(stored.schedule_start, "22:00", "disabling schedule preserves saved times")
eq(stored.schedule_end, "07:00")
now_stamp = 0; eq(led.get_status().effective_led, 0, "manual off independent of clock")
reset(); response = led.handle({ led = 1, schedule = 1, start_time = "7:0", end_time = "07:00" })
eq(response.code, "2"); eq(commits, 0, "equal boundaries rejected atomically")
reset(); board = "official,system"; eq(led.handle({ led = 0 }).code, "2"); eq(commits, 0)
reset(); backing = "/dev/mtdblock7"; eq(led.handle({ led = 0 }).code, "2"); eq(commits, 0)
reset(); busy = true; eq(led.handle({ led = 0 }).code, "2"); eq(commits, 0); eq(locked, false)
reset(); changes = { c2000max = { unrelated = {} } }; eq(led.handle({ led = 0 }).code, "2"); eq(commits, 0)
reset(); stage_fail = true; eq(led.handle({ led = 0 }).code, "2"); eq(commits, 0); eq(stored.enabled, "1")
reset(); commit_fail = 1; response = led.handle({ led = 0, schedule = 1 })
eq(response.code, "2"); eq(commits, 2); eq(stored.enabled, "1"); eq(stored.schedule_enabled, nil)
eq(stored.fan_unrelated, "keep"); eq(#calls, 0); eq(locked, false)
reset(); reload_fail = 1; response = led.handle({ led = 0 })
eq(response.code, "2"); eq(commits, 2); eq(stored.enabled, "1"); eq(stored.schedule_enabled, nil); eq(#calls, 2)
reset(); commit_fail = 2; response = led.handle({ led = 0 })
eq(response.code, "2"); eq(response.message:match("check TF%-card storage") ~= nil, true); eq(locked, false)
reset(); led_names = {}; response = led.get_status()
eq(response.led, -1); eq(led.handle({ led = 0 }).code, "2"); eq(commits, 0)
reset(); stored.schedule_enabled = "1"; stored.schedule_start = "oops"
response = led.get_status(); eq(response.effective_led, 1); eq(response.schedule_status, "invalid_schedule")
eq(led.handle({ schedule = 1 }).code, "2"); eq(commits, 0)
eq(led.handle({ schedule = 1, start_time = "22:0", end_time = "7:0" }).code, "0")
os.time, os.date = raw_time, raw_date
print("LED APP fixture passed: " .. count .. " assertions")
