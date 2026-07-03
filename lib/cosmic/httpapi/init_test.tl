#!/usr/bin/env cosmic
local httpapi = require("cosmic.httpapi")
local response = require("cosmic.httpapi.response")
local net = require("cosmic.net")
local child = require("cosmic.child")

local function test_app_creation()
  local app = httpapi.new()
  assert(app ~= nil, "expected app")
end
test_app_creation()

local function test_route_registration()
  local app = httpapi.new()
  app:get("/test", function(_req: httpapi.Request): httpapi.Response
      return response.text("ok")
    end)
  app:post("/data", function(_req: httpapi.Request): httpapi.Response
      return response.json({ok = true})
    end)
end
test_route_registration()

local function test_handle_request()
  local app = httpapi.new()
  app:get("/hello", function(_req: httpapi.Request): httpapi.Response
      return response.text("world")
    end)
  local raw = "GET /hello HTTP/1.1\r\nHost: localhost\r\n\r\n"
  local resp = app:handle(raw)
  assert(resp ~= nil, "expected response")
  assert(resp.status == 200, "expected 200, got " .. tostring(resp.status))
  assert(resp.body == "world", "expected world, got " .. tostring(resp.body))
end
test_handle_request()

local function test_handle_not_found()
  local app = httpapi.new()
  app:get("/exists", function(_req: httpapi.Request): httpapi.Response
      return response.text("yes")
    end)
  local raw = "GET /missing HTTP/1.1\r\nHost: localhost\r\n\r\n"
  local resp = app:handle(raw)
  assert(resp ~= nil, "expected response")
  assert(resp.status == 404, "expected 404, got " .. tostring(resp.status))
end
test_handle_not_found()

local function test_handle_with_params()
  local app = httpapi.new()
  app:get("/users/{id}", function(req: httpapi.Request): httpapi.Response
      return response.json({id = req.params["id"]})
    end)
  local raw = "GET /users/42 HTTP/1.1\r\nHost: localhost\r\n\r\n"
  local resp = app:handle(raw)
  assert(resp ~= nil, "expected response")
  assert(resp.status == 200, "expected 200")
  assert(resp.body:find('"42"') or resp.body:find('"id"'),
    "expected id in body, got " .. tostring(resp.body))
end
test_handle_with_params()

local function test_handle_with_middleware()
  local app = httpapi.new()
  app:use(function(_req: httpapi.Request, nxt: httpapi.Next): httpapi.Response
      local resp = nxt(_req)
      resp.headers["X-Powered-By"] = "cosmic"
      return resp
    end)
  app:get("/", function(_req: httpapi.Request): httpapi.Response
      return response.text("home")
    end)
  local raw = "GET / HTTP/1.1\r\nHost: localhost\r\n\r\n"
  local resp = app:handle(raw)
  assert(resp.status == 200, "expected 200")
  assert(resp.body == "home", "expected home body")
  assert(resp.headers["X-Powered-By"] == "cosmic",
    "expected powered-by header")
end
test_handle_with_middleware()

local function test_integration_server()
  -- Start server in a child process, make a real HTTP request
  local app = httpapi.new()
  app:get("/ping", function(_req: httpapi.Request): httpapi.Response
      return response.json({pong = true})
    end)

  -- Bind to ephemeral port to get the port number
  local server_sock, err = net.socket()
  assert(server_sock ~= nil, "socket failed: " .. tostring(err))
  local ok = server_sock:setsockopt(net.SOL_SOCKET, net.SO_REUSEADDR, true)
  assert(ok, "setsockopt failed")
  ok, err = server_sock:bind(net.parseip("127.0.0.1"), 0)
  assert(ok, "bind failed: " .. tostring(err))
  local _, port = server_sock:getsockname()
  assert(port > 0, "expected port")
  ok, err = server_sock:listen()
  assert(ok, "listen failed: " .. tostring(err))

  -- Fork: child accepts one connection and handles it
  local pid = child.fork()
  if pid == 0 then
    local client = server_sock:accept()
    if client then
      local data = client:recv(4096)
      if data then
        local resp = app:handle(data)
        if resp then
          local raw_resp = response.serialize(resp)
          client:send(raw_resp)
        end
      end
      client:close()
    end
    server_sock:close()
    os.exit(0)
  end

  -- Parent: connect and send request
  server_sock:close()
  local client = net.socket()
  assert(client ~= nil, "client socket failed")
  ok = client:connect(net.parseip("127.0.0.1"), port)
  assert(ok, "connect failed")
  client:send("GET /ping HTTP/1.1\r\nHost: localhost\r\n\r\n")
  local data = client:recv(4096)
  client:close()

  -- Wait for child
  child.wait(pid)

  -- Verify response
  assert(data ~= nil, "expected response data")
  assert(data:find("HTTP/1.1 200"), "expected 200 in response: " .. tostring(data))
  assert(data:find("pong"), "expected pong in response body")
end
test_integration_server()
