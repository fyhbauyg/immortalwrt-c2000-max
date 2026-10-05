-- Small bounded supervisor shared by the two local APP listeners. A slow
-- modem query or a client which connects without sending data must not hold
-- the listener and prevent another phone from probing/authenticating.
local nixio = require "nixio"
local process = require "c2000max_app.process"
local M = {}

local function clock()
	return nixio.sysinfo().uptime
end

function M.run(server, handle, options)
	options = options or {}
	local workers = {}
	local limit = options.workers or 8
	local timeout = options.timeout or 240
	local io_timeout = options.io_timeout or 5
	local incoming = {{ fd = server, events = nixio.poll_flags("in") }}
	server:setblocking(false)
	while true do
		local active = 0
		for pid, started in pairs(workers) do
			local exited = nixio.waitpid(pid, "nohang")
			if exited == pid or exited == nil then
				workers[pid] = nil
			elseif clock() - started >= timeout then
				-- Retain the slot until waitpid confirms exit: a killed process
				-- is not yet reaped and must not be replaced without a bound.
				nixio.kill(pid, nixio.const.SIGKILL)
				active = active + 1
			else
				active = active + 1
			end
		end
		if active >= limit then
			nixio.nanosleep(0, 50000000)
		else
			local ready = nixio.poll(incoming, 1000)
			local client = ready and ready > 0 and server:accept() or nil
			if client then
				local pid = process.fork()
				if pid == 0 then
					server:close()
					client:setblocking(true)
					client:setopt("socket", "rcvtimeo", io_timeout, 0)
					client:setopt("socket", "sndtimeo", io_timeout, 0)
					pcall(handle, client)
					client:close()
					os.exit(0)
				end
				client:close()
				if pid then workers[pid] = clock() end
			end
		end
	end
end

return M
