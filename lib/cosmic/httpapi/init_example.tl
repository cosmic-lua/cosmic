#!/usr/bin/env cosmic
--- Example: lightweight JSON API with routing and middleware.
local httpapi = require("cosmic.httpapi")
local response = require("cosmic.httpapi.response")
local net = require("cosmic.net")
local child = require("cosmic.child")

--- Example_hello demonstrates basic route handling and middleware.
--- Creates a server with JSON routes and a timing middleware,
--- then verifies responses via a real HTTP connection.
local function Example_hello()
  local app = httpapi.new()

  -- Middleware: add X-Powered-By header to every response
  app:use(function(_req: httpapi.Request, nxt: httpapi.Next): httpapi.Response
      local resp = nxt(_req)
      resp.headers["X-Powered-By"] = "cosmic"
      return resp
    end)

  -- Routes
  app:get("/", function(_req: httpapi.Request): httpapi.Response
      return response.json({message = "welcome to cosmic httpapi"})
    end)

  app:get("/users/{id}", function(req: httpapi.Request): httpapi.Response
      return response.json({user_id = req.params["id"]})
    end)

  app:post("/echo", function(req: httpapi.Request): httpapi.Response
      return response.text(req.body)
    end)

  -- Bind to ephemeral port
  local server, err = net.socket()
  assert(server ~= nil, "socket: " .. tostring(err))
  server:setsockopt(net.SOL_SOCKET, net.SO_REUSEADDR, true)
  server:bind(net.parseip("127.0.0.1"), 0)
  server:listen()
  local _, port = server:getsockname()

  -- Fork a child to serve 3 requests
  local pid = child.fork()
  if pid == 0 then
    for _ = 1, 3 do
      local client = server:accept()
      if client then
        local data = client:recv(4096)
        if data then
          local resp = app:handle(data)
          client:send(response.serialize(resp))
        end
        client:close()
      end
    end
    server:close()
    os.exit(0)
  end
  server:close()

  -- Request 1: GET /
  local c1 = net.socket()
  assert(c1 ~= nil)
  c1:connect(net.parseip("127.0.0.1"), port)
  c1:send("GET / HTTP/1.1\r\nHost: localhost\r\n\r\n")
  local r1 = c1:recv(4096)
  c1:close()
  assert(r1 and r1:find("welcome"), "expected welcome, got: " .. tostring(r1))
  assert(r1:find("X%-Powered%-By: cosmic"), "expected powered-by header")

  -- Request 2: GET /users/7
  local c2 = net.socket()
  assert(c2 ~= nil)
  c2:connect(net.parseip("127.0.0.1"), port)
  c2:send("GET /users/7 HTTP/1.1\r\nHost: localhost\r\n\r\n")
  local r2 = c2:recv(4096)
  c2:close()
  assert(r2 and r2:find('"7"'), "expected user_id 7, got: " .. tostring(r2))

  -- Request 3: POST /echo
  local body = "hello cosmic"
  local c3 = net.socket()
  assert(c3 ~= nil)
  c3:connect(net.parseip("127.0.0.1"), port)
  c3:send("POST /echo HTTP/1.1\r\nHost: localhost\r\n"
    .. "Content-Length: " .. tostring(#body) .. "\r\n\r\n" .. body)
  local r3 = c3:recv(4096)
  c3:close()
  assert(r3 and r3:find("hello cosmic"),
    "expected echo body, got: " .. tostring(r3))

  child.wait(pid)
end
Example_hello()
