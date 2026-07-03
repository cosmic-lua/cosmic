--- Lightweight HTTP API framework.
--- Provides route registration, middleware chaining, and a poll-based server.
---
--- Example:
---   local httpapi = require("cosmic.httpapi")
---   local response = require("cosmic.httpapi.response")
---   local app = httpapi.new()
---   app:get("/", function(req) return response.json({ok = true}) end)
---   app:listen("0.0.0.0", 8080)
local net = require("cosmic.net")
local poll = require("cosmic.poll")
local request_mod = require("cosmic.httpapi.request")
local response_mod = require("cosmic.httpapi.response")
local router_mod = require("cosmic.httpapi.router")
local middleware_mod = require("cosmic.httpapi.middleware")
local types = require("cosmic.httpapi.types")

local type Request = request_mod.Request
local type Response = response_mod.Response
local type Handler = types.Handler
local type Middleware = types.Middleware
local type Next = Handler

--- Per-connection state for the poll-based server.
local record Conn
  sock: net.Socket
  buf: string
end

--- HTTP application with routing and middleware.
local record App
  --- Register a GET route.
  get: function(App, string, Handler)
  --- Register a POST route.
  post: function(App, string, Handler)
  --- Register a PUT route.
  put: function(App, string, Handler)
  --- Register a DELETE route.
  delete: function(App, string, Handler)
  --- Register a PATCH route.
  patch: function(App, string, Handler)
  --- Register a route with explicit method.
  route: function(App, string, string, Handler)
  --- Add middleware to the stack.
  use: function(App, Middleware)
  --- Handle a raw HTTP request string (for testing).
  --- @param raw string Raw HTTP request bytes
  --- @return Response
  handle: function(App, string): Response
  --- Start the server on the given address and port.
  --- @param host string Bind address
  --- @param port number Port number
  listen: function(App, string, number)
end

--- Build the 404 response for unmatched routes.
local function not_found(): Response
  return response_mod.json({error = "not found"}, 404)
end

--- Process a complete HTTP request buffer through the app pipeline.
local function process(
    app_router: router_mod.Router,
    middlewares: {Middleware},
    raw: string
  ): Response
  local req, err = request_mod.parse(raw)
  if not req then
    return response_mod.json({error = err or "bad request"}, 400)
  end
  local handler, params = app_router:match(req.method, req.path)
  if not handler then
    return not_found()
  end
  req.params = params
  local final = middleware_mod.chain(middlewares, handler)
  return final(req)
end

--- Check if buffer contains a complete HTTP request.
--- Returns true if we have headers + full body (per Content-Length).
local function request_complete(buf: string): boolean
  local header_end = buf:find("\r\n\r\n", 1, true)
  if not header_end then
    return false
  end
  local cl = buf:lower():match("content%-length:%s*(%d+)")
  if cl then
    local expected = tonumber(cl) as integer
    local body_start = header_end + 4
    return #buf >= body_start + expected - 1
  end
  return true
end

--- Create a new HTTP application.
--- @return App
local function new(): App
  local r = router_mod.new()
  local middlewares: {Middleware} = {}
  local app: App = {}

  app.get = function(self: App, pattern: string, handler: Handler)
    local _ = self
    r:add("GET", pattern, handler)
  end

  app.post = function(self: App, pattern: string, handler: Handler)
    local _ = self
    r:add("POST", pattern, handler)
  end

  app.put = function(self: App, pattern: string, handler: Handler)
    local _ = self
    r:add("PUT", pattern, handler)
  end

  app.delete = function(self: App, pattern: string, handler: Handler)
    local _ = self
    r:add("DELETE", pattern, handler)
  end

  app.patch = function(self: App, pattern: string, handler: Handler)
    local _ = self
    r:add("PATCH", pattern, handler)
  end

  app.route = function(self: App, method: string, pattern: string, handler: Handler)
    local _ = self
    r:add(method, pattern, handler)
  end

  app.use = function(self: App, mw: Middleware)
    local _ = self
    table.insert(middlewares, mw)
  end

  app.handle = function(self: App, raw: string): Response
    local _ = self
    return process(r, middlewares, raw)
  end

  app.listen = function(self: App, host: string, port: number)
    local _ = self
    local ip = net.parseip(host)
    local server, err = net.socket(net.AF_INET,
      net.SOCK_STREAM | net.SOCK_NONBLOCK)
    assert(server, "socket failed: " .. tostring(err))
    local ok: boolean
    ok, err = server:setsockopt(net.SOL_SOCKET, net.SO_REUSEADDR, true)
    assert(ok, "setsockopt failed: " .. tostring(err))
    ok, err = server:bind(ip, port as integer)
    assert(ok, "bind failed: " .. tostring(err))
    ok, err = server:listen(128)
    assert(ok, "listen failed: " .. tostring(err))
    local _, actual_port = server:getsockname()
    io.write("listening on " .. host .. ":" .. tostring(actual_port) .. "\n")
    local poller = poll.new()
    poller:add(server.fd, poll.POLLIN)
    local conns: {number: Conn} = {}
    while true do
      for fd, events in poller:wait(1000) do
        if fd == server.fd then
          if events.readable then
            local client, _, _, accept_err = server:accept(
              net.SOCK_NONBLOCK | net.SOCK_CLOEXEC)
            if client then
              poller:add(client.fd, poll.POLLIN)
              conns[client.fd] = {sock = client, buf = ""}
            else
              io.stderr:write("accept: " .. tostring(accept_err) .. "\n")
            end
          end
        else
          local conn = conns[fd]
          if not conn then
            poller:remove(fd)
          elseif events.readable then
            local data, recv_err = conn.sock:recv(8192)
            if not data or #data == 0 then
              local _ = recv_err
              conn.sock:close()
              poller:remove(fd)
              conns[fd] = nil
            else
              conn.buf = conn.buf .. data
              if request_complete(conn.buf) then
                local resp = process(r, middlewares, conn.buf)
                local raw_resp = response_mod.serialize(resp)
                conn.sock:send(raw_resp)
                conn.sock:close()
                poller:remove(fd)
                conns[fd] = nil
              end
            end
          elseif events.error or events.hangup then
            conn.sock:close()
            poller:remove(fd)
            conns[fd] = nil
          end
        end
      end
    end
  end

  return app
end

return {
  App = App,
  Request = Request,
  Response = Response,
  Handler = Handler,
  Middleware = Middleware,
  Next = Next,
  Conn = Conn,
  new = new,
}
