-- Queue
queue = {}

function queue.push(self, item)
	table.insert(self.list, item)
end

function queue.pop(self)
	return table.remove(self.list, 1)
end

function queue.is_empty(self)
	return #self.list == 0
end

function queue.len(self)
	return #self.list
end

function queue.new()
	return {
		list = {},
		push = queue.push,
		pop = queue.pop,
		is_empty = queue.is_empty,
		len = queue.len,
	}
end


local http = require("socket.http")

-- Monkey Patches around bugs in haproxy's Socket class
-- This function calls core.tcp(), fixes a few methods and
-- returns the resulting socket.
-- @return Socket
function create_sock()
	local sock = core.tcp()

	-- https://www.mail-archive.com/haproxy@formilux.org/msg28574.html
	sock.old_receive = sock.receive
	sock.receive = function(socket, pattern, prefix)
		local a, b
		if pattern == nil then pattern = "*l" end
		if prefix == nil then
			a, b = sock:old_receive(pattern)
		else
			a, b = sock:old_receive(pattern, prefix)
		end
		return a, b
	end

	-- https://www.mail-archive.com/haproxy@formilux.org/msg28604.html
	sock.old_settimeout = sock.settimeout
	sock.settimeout = function(socket, timeout)
		socket:old_settimeout(timeout)
		return 1
	end
	return sock
end

function get_path(txn)
	local path = txn.sf:path()
	local path_start = string.match(path, '([^/]+)')
	if path_start == nil then
	   return ""
	end
	return path_start
end

core.register_action("shadow", { "http-req" }, function(txn, be)
	local method = txn.f:method()
	if method ~= "GET" then
		return
	end
	-- Check whether the given backend exists.
	if core.backends[be] == nil then
		txn:Alert("Unknown shadow backend '" .. be .. "'")
		return
	end

	local path = get_path(txn)

	-- Transform table of request headers from haproxy's to
	-- socket.http's format.
	local headers = {}
	for header, values in pairs(txn.http:req_get_headers()) do
		for i, v in pairs(values) do
			if headers[header] == nil then
				headers[header] = v
			else
				headers[header] = headers[header] .. ", " .. v
			end
		end
	end
	headers["X-Shadow"] = "true"

	shadow_queue:push({
		be = be,
		path = path,
		headers = headers
	})
end, 1)

shadow_queue = queue.new()
function run_loop()
	while true do
		if not shadow_queue:is_empty() then
			req = shadow_queue:pop()
			-- Check whether the given backend has servers that
			-- are not `DOWN`.
			local addr = nil
			for name, server in pairs(core.backends[req.be].servers) do
				local status = server:get_stats()['status']
				if status == "no check" or status:find("UP") == 1 then
					addr = server:get_addr()
					break
				end
			end
			if addr == nil then
				core:Warning("No servers available for shadow backend: '" .. be .. "'")
				return
			end
			local b, c, h = http.request {
				url = "http://" .. addr .. req.path,
				headers = req.headers,
				create = create_sock,
				-- Disable redirects, because DNS does not work here.
				redirect = false
			}
		end
	end
end

core.register_task(run_loop)