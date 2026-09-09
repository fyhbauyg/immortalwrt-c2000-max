local root = assert(arg[1], "package root required")
package.path = root .. "/files/usr/lib/lua/?.lua;" .. package.path
local function stub(name, value) package.loaded[name] = value end
local settings = { local_enable = "1", local_device_enable = "1", device_report_enable = "1" }
local cursor = { get = function(_, config, section, option)
  if config == "c2000max_app" and section == "main" then return settings[option] end
end }
stub("nixio.fs", {})
stub("nixio", {})
stub("luci.jsonc", { stringify = function(v) return v end })
stub("luci.sys", { user = { getpasswd = function() return nil end } })
stub("luci.util", {})
stub("luci.model.uci", { cursor = function() return cursor end })
stub("c2000max_app.identity", {})
stub("c2000max_app.rweb", {})
local calls, last, broken = 0, nil, false
stub("c2000max_app.led", { handle = function(value)
  calls, last = calls + 1, value
  if broken then error("simulated LED backend failure") end
  return { code = "0", led = value.led or 1, schedule = value.schedule or 0,
    start_time = value.start_time or "22:00", end_time = value.end_time or "07:00",
    trans_id = "must-not-replace-request" }
end })
local valid, request, wire = false, { trans_id = "LED123" }, "aes"
stub("c2000max_app.protocol", {
  decode = function() return request, { encrypted = true, wire = wire } end,
  valid_session = function() return valid end,
  encode = function(value, context) value.test_wire = context.wire; return value end
})
local core = require "c2000max_app.core"
local http = require "c2000max_app.http"
local cloud = require "c2000max_app.cloud"
local assertions = 0
local function eq(a, b, name)
  assertions = assertions + 1
  assert(a == b, name .. ": " .. tostring(a) .. " != " .. tostring(b))
end
eq(core.feature_enabled("local_led_enable"), true, "old local permission inherited")
eq(core.feature_enabled("remote_led_enable"), true, "old remote permission inherited")
eq(core.feature_enabled("upgrade_enable"), false, "upgrade remains unavailable")
for _, mode in ipairs({ "aes", "des-current", "plain-session" }) do
  wire, valid = mode, false
  local result = http.process("led", "request", {})
  eq(result.code, "1", "unauthenticated LED denied")
  eq(calls, 0, "unauthenticated LED not dispatched")
  eq(result.test_wire, mode, "denial preserves response envelope")
end
valid = true
settings.local_enable = "0"
eq(http.process("led", "request", {}).code, "2", "local master gate")
settings.local_enable, settings.local_led_enable = "1", "0"
eq(http.process("led", "request", {}).code, "3", "explicit LED permission denial")
eq(calls, 0, "permission denial not dispatched")
settings.local_led_enable = "1"
for _, mode in ipairs({ "aes", "des-current", "plain-session" }) do
  wire = mode
  local result = http.process("led", "request", {})
  eq(result.code, "0", "authenticated LED response")
  eq(result.trans_id, "LED123", "request transaction preserved")
  eq(result.test_wire, mode, "success preserves response envelope")
end
broken = true
eq(http.process("led", "request", {}).code, "2", "backend exception fails closed")
broken = false
settings.remote_led_enable = "0"
local before = calls
local response, event = cloud.handle("led", {})
eq(response.code, "3", "remote explicit deny")
eq(event, "led", "remote denial reply topic")
eq(calls, before, "remote denied without hardware action")
settings.remote_led_enable = "1"
response, event = cloud.handle("led", { led = 0, schedule = 1,
  startTime = "22:0", endTime = "7:0", trans_id = "remote-1" })
eq(event, "led", "observed remote event")
eq(response.errcode, "0", "cloud success code")
eq(last.led, 0, "zero LED value preserved")
eq(last.start_time, "22:0", "cloud start mapped")
eq(last.end_time, "7:0", "cloud end mapped")
eq(response.trans_id, "remote-1", "cloud transaction preserved")
eq(response.led, 0, "flat cloud settings reply")
response = cloud.handle("led", { led = 1, schedule = 0, start_time = "21:30", end_time = "08:00" })
eq(last.schedule, 0, "disabled schedule retained")
eq(last.start_time, "21:30", "snake-case cloud time accepted")
response = cloud.handle("led", {})
eq(last.led, nil, "query does not become a write")
eq(last.schedule, nil, "query does not rewrite schedule")
eq(response.errcode, "0", "remote query response")
print("PASS: LED routing/auth/envelope " .. assertions .. " assertions")
