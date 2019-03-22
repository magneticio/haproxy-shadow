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
	-- Check whether the given backend exists.
	if core.backends[be] == nil then
		txn:Alert("Unknown shadow backend '" .. be .. "'")
		return
	end

	-- Check whether the given backend has servers that
	-- are not `DOWN`.
	local addr = nil
	for name, server in pairs(core.backends[be].servers) do
		local status = server:get_stats()['status']
		if status == "no check" or status:find("UP") == 1 then
			addr = server:get_addr()
			break
		end
	end
	if addr == nil then
		txn:Warning("No servers available for shadow backend: '" .. be .. "'")
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

	-- Make request to backend.
	local b, c, h = http.request {
		url = "http://" .. addr .. path,
		headers = headers,
		create = create_sock,
		-- Disable redirects, because DNS does not work here.
		redirect = false
	}
end, 1)