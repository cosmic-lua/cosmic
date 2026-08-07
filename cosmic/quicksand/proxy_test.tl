#!/usr/bin/env cosmic
local proxy = require("cosmic.quicksand.proxy")
local quicksand = require("cosmic.quicksand")
local check = require("cosmic.check")
local net = require("cosmic.net")

-- quicksand's bind_ip option is a raw integer (C-boundary internals);
-- the cosmic.net surface takes dotted-quad strings or ip.Addr.
local LOOPBACK < const > = 0x7f000001
local LOOPBACK_STR < const > = "127.0.0.1"

local function test_module_exports()
  assert(type(proxy.start) == "function")
end
test_module_exports()

-- Drive one request through a live proxy and return everything the
-- server sends back before closing.
local function roundtrip(port: integer, request: string): string
  local sock = check.must(net.connect_tcp(LOOPBACK_STR, port))
  assert(sock:send(request))
  local resp = ""
  while true do
    local chunk = sock:recv(4096)
    if not chunk or chunk == "" then break end
    resp = resp .. chunk
  end
  assert(sock:close())
  return resp
end

-- Rule validation happens in the parent, before any fork: a typo'd
-- rule fails loudly instead of degrading to pass-through.
local function test_start_rejects_invalid_rules_pre_fork()
  local handle, err = proxy.start({
      bind_ip = LOOPBACK,
      bind_port = 0,
      allowed_hosts = {
        ["api.example.com"] = {type = "bearer"},
      },
      log_level = "quiet",
    })
  assert(handle == nil, "start should refuse an incomplete bearer rule")
  assert(err:find("token", 1, true),
    "error should cite the missing token, got: " .. tostring(err))
end
test_start_rejects_invalid_rules_pre_fork()

-- start() forks a child; exercise the full lifecycle on Linux and
-- verify stop() kills + reaps idempotently. Skip on non-Linux since
-- the proxy plumbing is Linux-only.
local function test_start_stop_lifecycle()
  local c = quicksand.capabilities()
  if not c.linux then
    check.enforce_skip("quicksand proxy is Linux-only")
    return
  end

  local h = check.must(proxy.start({
        bind_ip = LOOPBACK,
        bind_port = 0, -- ephemeral
        allowed_hosts = {
          ["api.example.com:443"] = {},
        },
        log_level = "quiet",
      }))
  assert(type(h.pid) == "number" and h.pid > 0,
    "pid should be positive")
  assert(type(h.port) == "number" and h.port > 0,
    "port should be positive")
  assert(h:alive(), "alive() should be true while running")

  -- Connecting to the proxy and immediately closing should at least
  -- establish a TCP connection — verify by opening a client socket.
  local sock = check.must(net.connect_tcp(LOOPBACK_STR, h.port),
    "failed to connect to proxy on port " .. tostring(h.port))
  assert(sock:close())

  h:stop()
  assert(h.pid == 0, "stop() should zero the pid")
  -- Second call must be a no-op.
  h:stop()
  assert(not h:alive(), "alive() should be false after stop()")
end
test_start_stop_lifecycle()

-- Deny-by-default: a client request for a host not in the allowlist
-- gets 403 back, for both plain-HTTP and CONNECT.
local function test_deny_unknown_host()
  local c = quicksand.capabilities()
  if not c.linux then
    check.enforce_skip("quicksand proxy is Linux-only")
    return
  end

  local handle = check.must(proxy.start({
        bind_ip = LOOPBACK,
        bind_port = 0,
        allowed_hosts = {
          ["allowed.example.com:80"] = {},
        },
        log_level = "quiet",
      }))

  local resp = roundtrip(handle.port,
    "GET http://denied.example.com/ HTTP/1.1\r\n"
    .. "Host: denied.example.com\r\n\r\n")
  assert(resp:find("403", 1, true),
    "expected 403 from plain-HTTP deny, got: " .. resp)

  resp = roundtrip(handle.port,
    "CONNECT denied.example.com:443 HTTP/1.1\r\n\r\n")
  assert(resp:find("403", 1, true),
    "expected 403 from CONNECT deny, got: " .. resp)

  handle:stop()
  check.enforced("proxy deny-by-default")
end
test_deny_unknown_host()

-- Wire-level input validation: malformed request lines and
-- origin-form targets get 400; chunked request bodies get 411.
local function test_malformed_and_chunked_requests()
  local c = quicksand.capabilities()
  if not c.linux then
    check.enforce_skip("quicksand proxy is Linux-only")
    return
  end

  local handle = check.must(proxy.start({
        bind_ip = LOOPBACK,
        bind_port = 0,
        allowed_hosts = {
          ["allowed.example.com"] = {},
        },
        log_level = "quiet",
      }))

  local resp = roundtrip(handle.port, "garbage\r\n\r\n")
  assert(resp:find("400", 1, true),
    "expected 400 for malformed request line, got: " .. resp)

  resp = roundtrip(handle.port,
    "GET /origin-form HTTP/1.1\r\nHost: allowed.example.com\r\n\r\n")
  assert(resp:find("400", 1, true),
    "expected 400 for origin-form target, got: " .. resp)

  resp = roundtrip(handle.port,
    "POST http://allowed.example.com/ HTTP/1.1\r\n"
    .. "Transfer-Encoding: chunked\r\n\r\n")
  assert(resp:find("411", 1, true),
    "expected 411 for chunked request body, got: " .. resp)

  handle:stop()
end
test_malformed_and_chunked_requests()

-- SSRF protection end to end: an allowlisted host that resolves to a
-- private address is refused at dial time, surfacing as 502 — the
-- allowlist alone must not be enough to reach loopback or RFC1918.
local function test_allowed_private_upstream_gets_502()
  local c = quicksand.capabilities()
  if not c.linux then
    check.enforce_skip("quicksand proxy is Linux-only")
    return
  end

  local handle = check.must(proxy.start({
        bind_ip = LOOPBACK,
        bind_port = 0,
        allowed_hosts = {
          ["localhost"] = {},
          ["127.0.0.1"] = {},
        },
        log_level = "quiet",
        resolve_timeout_ms = 2000,
      }))

  local resp = roundtrip(handle.port,
    "CONNECT 127.0.0.1:80 HTTP/1.1\r\n\r\n")
  assert(resp:find("502", 1, true),
    "expected 502 for private upstream, got: " .. resp)

  handle:stop()
  check.enforced("proxy SSRF guard")
end
test_allowed_private_upstream_gets_502()

-- stop() escalation: a child that never handles SIGTERM (simulated
-- with SIGSTOP) is SIGKILL'd after the timeout and still reaped.
local function test_stop_escalates_to_sigkill()
  local c = quicksand.capabilities()
  if not c.linux then
    check.enforce_skip("quicksand proxy is Linux-only")
    return
  end
  local signal = require("cosmic.signal")

  local handle = check.must(proxy.start({
        bind_ip = LOOPBACK,
        bind_port = 0,
        allowed_hosts = {},
        log_level = "quiet",
      }))
  assert(signal.kill(handle.pid, signal.SIGSTOP))
  local before = os.time()
  assert(handle:stop(300), "stop() with a hung child should return")
  assert(handle.pid == 0, "escalation should reap and zero the pid")
  assert(os.time() - before < 10, "escalation should happen promptly")
end
test_stop_escalates_to_sigkill()
