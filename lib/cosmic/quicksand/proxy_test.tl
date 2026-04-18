#!/usr/bin/env cosmic
local proxy = require("cosmic.quicksand.proxy")
local quicksand = require("cosmic.quicksand")
local net = require("cosmic.net")

local function test_module_exports()
  assert(type(proxy.start) == "function")
end
test_module_exports()

-- start() forks a child; exercise the full lifecycle on Linux and
-- verify stop() kills + reaps idempotently. Skip on non-Linux since
-- the raw cosmo.sandbox.proxy is Linux-only.
local function test_start_stop_lifecycle()
  local c = quicksand.capabilities()
  if not c.linux then return end

  local handle, err = proxy.start({
      bind_ip = 0x7f000001, -- 127.0.0.1
      bind_port = 0, -- ephemeral
      allowed_hosts = {
        ["api.example.com:443"] = {},
      },
      log_level = "quiet",
    })
  assert(handle, "proxy.start failed: " .. tostring(err))
  assert(type(handle.pid) == "number" and handle.pid > 0, "pid should be positive")
  assert(type(handle.port) == "number" and handle.port > 0, "port should be positive")

  -- Connecting to the proxy and immediately closing should at least
  -- establish a TCP connection — verify by opening a client socket.
  local sock = net.connect_tcp(0x7f000001, handle.port)
  assert(sock, "failed to connect to proxy on port " .. tostring(handle.port))
  sock:close()

  handle:stop()
  assert(handle.pid == 0, "stop() should zero the pid")
  -- Second call must be a no-op.
  handle:stop()
end
test_start_stop_lifecycle()

-- Deny-by-default: a client request for a host not in the allowlist
-- should get 403 back. Run an HTTP request through the proxy for a
-- disallowed host and assert we see a 403.
local function test_deny_unknown_host()
  local c = quicksand.capabilities()
  if not c.linux then return end

  local handle = assert(proxy.start({
        bind_ip = 0x7f000001,
        bind_port = 0,
        allowed_hosts = {
          ["allowed.example.com:80"] = {},
        },
        log_level = "quiet",
      }))

  local sock = assert(net.connect_tcp(0x7f000001, handle.port))
  sock:send("GET http://denied.example.com/ HTTP/1.1\r\nHost: denied.example.com\r\n\r\n")
  local resp = ""
  while true do
    local chunk = sock:recv(4096)
    if not chunk or chunk == "" then break end
    resp = resp .. chunk
    if #resp >= 16 then break end
  end
  sock:close()
  handle:stop()
  assert(resp:find("403", 1, true), "expected 403 from deny, got: " .. resp)
end
test_deny_unknown_host()
