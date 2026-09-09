-- Deterministic daemon tests: no network, filesystem or modem is contacted.
local root = assert(arg[1], "package root required")
local real_time, real_rename = os.time, os.rename
local function check(value, message) assert(value, message) end

local function cache_case(fail_rename)
 local now, tick, snapshots, pending, saved = 100, 1, {}, {}, nil
 local states = { false, true, false, true }
 local prewarms, written, renamed = 0, 0, 0
 local fs = {
  mkdirr = function() end, chmod = function() return true end,
  unlink = function(path) pending[path] = nil end,
  writefile = function(path, value)
   check(path:match("cache%.state%.tmp%.42$"), "state must be written to a private temporary path")
   pending[path] = value; written = written + 1; return true
  end
 }
 package.loaded["nixio.fs"] = fs
 package.loaded["nixio"] = {
  getpid = function() return 42 end,
  gettimeofday = function() return now, 0 end,
  nanosleep = function(seconds) now = now + seconds; tick = tick + 1 end
 }
 package.loaded["luci.jsonc"] = { stringify = function(value) return value end }
 package.loaded["c2000max_app.core"] = {
  local_enabled = function() return tick <= #states end,
  remote_enabled = function() return false end,
  cache_refresh_policy = function() return { warm = 2, idle = 30 } end,
  cache_active = function() return states[tick] end,
  prewarm = function()
   prewarms = prewarms + 1; now = now + 1
   if prewarms == 2 then error("synthetic modem error") end
   return { modems = 1 }
  end
 }
 os.time = function() return now end
 os.rename = function(source, target)
  check(target:match("cache%.state$"), "rename target must be cache state")
  if fail_rename then return nil, "synthetic rename failure" end
  saved = pending[source]; pending[source] = nil; renamed = renamed + 1
  snapshots[#snapshots + 1] = saved
  return true
 end
 assert(loadfile(root .. "/files/usr/sbin/c2000max-app-cache"))()
 check(prewarms == 3, "idle must not query the modem")
 check(written == 5, "four iterations plus terminal state")
 if fail_rename then
  check(saved == nil and next(pending) == nil and renamed == 0, "failed rename must clean temporary state")
 else
  check(snapshots[1].last_success == 101, "first successful prewarm time")
  check(snapshots[2].state == "error" and snapshots[2].last_success == 101, "failed prewarm must preserve prior success")
  check(snapshots[3].state == "error" and snapshots[3].active == false, "idle must not hide a previous failure")
  check(snapshots[3].last_success == 101 and snapshots[3].last_error ~= "", "idle must not advance successful freshness")
  check(snapshots[4].last_success > 101 and snapshots[4].last_error == "", "successful retry must recover metadata")
  check(snapshots[5].state == "stopped", "disabled service terminal state")
 end
end

local function reporter_case(config, limit, report_cost, wall_jump)
 local now, trace, closed = 0, { presence = {}, status = {}, reports = {} }, false
 package.loaded["nixio"] = {
  sysinfo = function() return { uptime = now } end,
  nanosleep = function(seconds)
   check(seconds >= 1, "reporter must not busy loop")
   now = now + seconds
  end
 }
 package.loaded["luci.model.uci"] = { cursor = function()
  return { get = function(_, _, _, name) return config[name] end }
 end }
 package.loaded["c2000max_app.core"] = { remote_enabled = function() return now <= limit end }
 local function mark(kind)
  trace[kind][#trace[kind] + 1] = now
  if kind == "reports" then now = now + (report_cost or 0) end
  return true
 end
 package.loaded["c2000max_app.cloud"] = {
  open_cpe_status_publisher = function() return { close = function() closed = true end } end,
  publish_cpe_status_stream = function() return mark("presence") end,
  publish_cpe_status = function() error("unexpected fallback publisher") end,
  publish_online_status = function() return mark("status") end,
  publish_reports = function() return mark("reports") end
 }
 os.time = function() return wall_jump and (now > 20 and now - 86400 or now + 90000) or now end
 assert(loadfile(root .. "/files/usr/sbin/c2000max-app-reporter"))()
 check(closed, "reporter must close persistent publisher")
 return trace
end

cache_case(false)
cache_case(true)
local slow_presence = reporter_case({ presence_interval = "60", status_interval = "10", report_interval = "60" }, 130)
check(#slow_presence.presence == 3 and #slow_presence.status == 13 and #slow_presence.reports == 3,
 "each configured cadence must have an independent deadline")
local defaults = reporter_case({}, 70, 0, true)
check(#defaults.presence == 31 and #defaults.status == 3 and #defaults.reports == 1,
 "default cadence must stay 2/30/300 seconds despite wall-time corrections")
local slow_calls = reporter_case({ presence_interval = "2", status_interval = "10", report_interval = "60" }, 150, 7)
for kind, list in pairs(slow_calls) do
 local minimum = kind == "presence" and 2 or kind == "status" and 10 or 67
 for index = 2, #list do check(list[index] - list[index - 1] >= minimum, "slow calls must not produce catch-up bursts") end
end
os.time, os.rename = real_time, real_rename
print("PASS: cache atomicity/freshness/idle/error recovery and reporter cadence/clock/cleanup")
