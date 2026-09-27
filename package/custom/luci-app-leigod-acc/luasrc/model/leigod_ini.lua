-- The current vendor engine stores device types in INI, not legacy UCI.
local fs = require "nixio.fs"
local M = {}
local path = "/etc/config/accelerator.ini"
function M.get(mac)
 if not mac:match("^%x+$") or #mac ~= 12 then return nil end
 local section
 for line in (fs.readfile(path) or ""):gmatch("[^\r\n]+") do
  local header = line:match("^%s*%[([^%]]+)%]")
  if header then section = header
  elseif section == "device" then
   local key, value = line:match('^%s*([%x]+)%s*=%s*"?(%d+)')
   if key == mac then return value end
  end
 end
end
function M.set(mac, value)
 if not mac:match("^%x+$") or #mac ~= 12 or not tostring(value):match("^%d+$") then return false end
 local lines, section, found = {}, nil, false
 local function append_missing()
  if section == "device" and not found then lines[#lines+1] = mac .. "=" .. value; found = true end
 end
 for line in ((fs.readfile(path) or "") .. "\n"):gmatch("([^\r\n]*)\r?\n") do
  local header = line:match("^%s*%[([^%]]+)%]")
  if header then append_missing(); section = header end
  if section == "device" and line:match("^%s*" .. mac .. "%s*=") then
   line = mac .. "=" .. value; found = true
  end
  lines[#lines+1] = line
 end
 append_missing()
 if not found then lines[#lines+1] = "[device]"; lines[#lines+1] = mac .. "=" .. value end
 local tmp = path .. ".luci.tmp"
 if not fs.writefile(tmp, table.concat(lines, "\n") .. "\n") then return false end
 fs.chmod(tmp, 384)
 return fs.rename(tmp, path)
end
return M
