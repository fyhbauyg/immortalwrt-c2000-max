-- Production parser and handler; fragmented socket input and output only.
local root=assert(arg[1])
local handler, now, calls = nil, 100, 0
local socket={setopt=function()end,bind=function()return true end,listen=function()return true end}
package.loaded["nixio"]={
	socket=function()return socket end, sysinfo=function()return {uptime=now} end,
	poll_flags=function()return 1 end,
	poll=function(set,timeout) local c=set[1].fd; now=now+(c.delay or 0); return #c.fragments>0 and 1 or 0 end
}
package.loaded["luci.jsonc"]={stringify=function(value)return '{"code":"'..tostring(value.code or "0")..'"}' end}
package.loaded["c2000max_app.server"]={run=function(_,handle)handler=handle end}
package.loaded["c2000max_app.http"]={process=function(action,body,context)
	calls=calls+1
	assert(action=="signal" and body=='{"trans_id":"probe"}',"action and complete fragmented body")
	assert(context.cookie=="sysauth=fixture" and context.remote_addr=="192.168.66.2","explicit socket/header context")
	return {code="0"}
end}
assert(loadfile(root.."/files/usr/sbin/c2000max-app-httpd"))()
local function run(fragments,delay)
	now=100
	local output=""
	local client={fragments=fragments,delay=delay}
	function client:recv(length)
		local chunk=table.remove(self.fragments,1)
		if chunk and #chunk>length then table.insert(self.fragments,1,chunk:sub(length+1)); chunk=chunk:sub(1,length) end
		return chunk
	end
	function client:send(value) local n=math.min(#value,7); output=output..value:sub(1,n); return n end
	function client:getpeername() return "192.168.66.2" end
	function client:getsockname() return "192.168.66.1" end
	handler(client)
	return output
end
local header='POST /cgi-bin/luci/nradio/app/signal HTTP/1.1\r\nCookie: sysauth=fixture\r\nContent-Length: 20\r\n\r\n'
local fragments={}; local full=header..'{"trans_id":"probe"}'
for i=1,#full,3 do fragments[#fragments+1]=full:sub(i,i+2) end
assert(run(fragments):find("200 OK",1,true) and calls==1,"fragmented request succeeds and short sends preserve reply")
for _,length in ipairs({'1.5','-1','1e3','262145'}) do
	assert(run({'POST /cgi-bin/luci/nradio/app/signal HTTP/1.1\r\nContent-Length: '..length..'\r\n\r\n'}):find('400 Bad Request',1,true),'reject malformed/oversized body')
end
assert(run({'POST /cgi-bin/luci/nradio/app/signal HTTP/1.1\r\nContent-Length: 0\r\nContent-Length: 0\r\n\r\n'}):find('400 Bad Request',1,true),'duplicate framing rejected')
assert(run({'POST /cgi-bin/luci/nradio/app/signal HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n'}):find('400 Bad Request',1,true),'unsupported body framing rejected')
assert(run({header,'{' }):find('400 Bad Request',1,true),'incomplete body rejected')
assert(run({'GET /cgi-bin/luci/nradio/app/info HTTP/1.1\r\n\r\n'}):find('405 Method Not Allowed',1,true),'method gate retained')
assert(run({'POST /cgi-bin/luci/nradio/app/nope HTTP/1.1\r\n\r\n'}):find('404 Not Found',1,true),'action gate retained')
local reply=run({'OPTIONS /cgi-bin/luci/nradio/app/signal HTTP/1.1\r\n\r\n'})
assert(reply:find('Content-Length: 0',1,true) and reply:sub(-4)=='\r\n\r\n','204 response has no body')
assert(run({'P','O','S','T',' ','/'},1):find('400 Bad Request',1,true),'one total deadline bounds trickle input')
assert(calls==1,'only valid authenticated route invokes processing')
print('PASS: fragmented HTTP, partial sends, framing/size/method/action gates, 204 body and total read deadline')
