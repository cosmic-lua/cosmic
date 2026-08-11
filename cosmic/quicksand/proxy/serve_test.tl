#!/usr/bin/env cosmic
--- End-to-end tests for the proxy's request-body limits: a
--- Content-Length over max_body_bytes is refused with 413 and a
--- malformed one with 400, in both cases before a single body byte is
--- read or buffered. Those requests are all refused before the
--- upstream dial, so they need only loopback sockets, no DNS or
--- egress.
---
--- The last test reaches further: it is the one request the
--- rule engine ALLOWS, so it runs on past the allowlist into the
--- upstream dial. It stops there by design -- see the note above it
--- for why a relayed response is not reachable hermetically.
local check = require("cosmic.check")
local serve = require("cosmic.quicksand.proxy.serve")
local net = require("cosmic.net")
-- cosmic.child models spawn-and-collect, but the upstream here has to
-- share this process's already-bound listening socket, so this test
-- forks directly via cosmic.proc.
local proc = require("cosmic.proc")
local signal = require("cosmic.signal")
local fd = require("cosmic.fd")

--- Start a proxy on an ephemeral loopback port with a tiny body cap
--- and one allowed pass-through host.
local function start_proxy(max_body: integer): serve.Server
  local srv = check.must(serve.new({
        bind_port = 0,
        allowed_hosts = {["a.example.com"] = {}},
        log_level = "quiet",
        max_body_bytes = max_body,
        resolve_timeout_ms = 200,
      }), "serve.new failed")
  assert(srv.listen(), "listen failed")
  return srv
end

--- Send one raw request, run one in-process handle() pass, and return
--- the full response. handle() closes the server-side fd; recv drains
--- until EOF (nil per the stream contract).
local function roundtrip(srv: serve.Server, request: string): string
  local sock = check.must(net.dial("127.0.0.1", srv.port()), "connect failed")
  assert(sock:send(request))
  -- named to match serve.tl's own client_fd, and to leave `fd` to the
  -- cosmic.fd module imported above
  local client_fd = check.must(srv.accept(), "accept failed")
  srv.handle(client_fd)
  local parts: {string} = {}
  while true do
    local chunk = sock:recv(4096)
    if not chunk then break end
    table.insert(parts, check.must(chunk))
  end
  assert(sock:close())
  return table.concat(parts)
end

-- A Content-Length beyond the cap is refused with 413 without reading
-- the body: the client never sends one, so anything but an immediate
-- refusal would deadlock this single-threaded test.
local function test_over_cap_body_refused_with_413()
  local srv = start_proxy(1024)
  local resp = roundtrip(srv,
    "POST http://a.example.com/upload HTTP/1.1\r\n"
    .. "Host: a.example.com\r\n"
    .. "Content-Length: 4096\r\n\r\n")
  assert(resp:find("^HTTP/1%.1 413 "),
    "over-cap body should get 413, got: " .. resp:sub(1, 40))
end
test_over_cap_body_refused_with_413()

-- A malformed Content-Length is a 400, not a silent 0: misreading it
-- as 0 would forward the request with the body still unread on the
-- socket.
local function test_malformed_content_length_refused_with_400()
  local srv = start_proxy(1024)
  local resp = roundtrip(srv,
    "POST http://a.example.com/upload HTTP/1.1\r\n"
    .. "Host: a.example.com\r\n"
    .. "Content-Length: banana\r\n\r\n")
  assert(resp:find("^HTTP/1%.1 400 "),
    "malformed content-length should get 400, got: " .. resp:sub(1, 40))
end
test_malformed_content_length_refused_with_400()

-- Boundary control: a body of exactly max_body_bytes passes the cap
-- check (the later upstream dial fails in this sandbox, so the
-- observable is only "anything but 413/400").
local function test_at_cap_body_passes_the_cap_check()
  local srv = start_proxy(16)
  local body = string.rep("x", 16)
  local resp = roundtrip(srv,
    "POST http://a.example.com/upload HTTP/1.1\r\n"
    .. "Host: a.example.com\r\n"
    .. "Content-Length: 16\r\n\r\n" .. body)
  assert(not resp:find("^HTTP/1%.1 413 "),
    "at-cap body must not be refused with 413, got: " .. resp:sub(1, 40))
  assert(not resp:find("^HTTP/1%.1 400 "),
    "at-cap body must not be refused with 400, got: " .. resp:sub(1, 40))
end
test_at_cap_body_passes_the_cap_check()

-- Denied hosts are refused before the body checks ever run, so an
-- oversized claim against a non-allowlisted host stays a plain 403.
local function test_deny_precedes_body_checks()
  local srv = start_proxy(1024)
  local resp = roundtrip(srv,
    "POST http://evil.example.com/ HTTP/1.1\r\n"
    .. "Host: evil.example.com\r\n"
    .. "Content-Length: 4096\r\n\r\n")
  assert(resp:find("^HTTP/1%.1 403 "),
    "denied host should get 403, got: " .. resp:sub(1, 40))
end
test_deny_precedes_body_checks()

-- The allowlist does not override the SSRF guard.
--
-- This is as far as the allow path can be driven hermetically. dial()
-- refuses every non-public IP unconditionally -- loopback included,
-- with no opt-out -- so a test-local upstream can never be reached,
-- and a real relayed response would need actual egress. What CAN be
-- proved here is the security property that makes that so: putting a
-- loopback address on the allowlist does not get you a connection to
-- it.
--
-- The upstream is real and would answer 200 if it were ever reached,
-- which is what makes this discriminating: a bypassed guard shows up
-- as the body below, not as a subtly different error. It is also
-- distinct from the 403 in the test above -- the rule engine DID
-- allow this host, so the request reached the dial and came back 502.
--
-- handle() runs in a forked worker because the allow path ends in
-- http.pump(), which is bidirectional and would otherwise wait on a
-- client half-close that never comes.

local UPSTREAM_BODY = "hello-from-upstream"

local function test_allowlist_does_not_bypass_the_ssrf_guard()
  local listener = net.listen_tcp("127.0.0.1", 0, {backlog = 8})
  local ls = check.must(listener, "upstream listen failed")
  local port = check.must(ls:local_endpoint()).port

  local pid = proc.fork()
  if not pid then
    assert(ls:close())
    check.enforce_skip("ssrf guard: fork unavailable")
    return
  end
  if pid == 0 then
    local conn = ls:accept()
    if conn is net.Socket then
      assert(conn:recv(65536))
      assert(conn:send("HTTP/1.1 200 OK\r\nContent-Length: " .. #UPSTREAM_BODY
          .. "\r\n\r\n" .. UPSTREAM_BODY))
      assert(conn:close())
    end
    assert(ls:close())
    os.exit(0)
  end
  assert(ls:close())

  local srv = check.must(serve.new({
        bind_port = 0,
        allowed_hosts = {["127.0.0.1:" .. port] = {}},
        log_level = "quiet",
        resolve_timeout_ms = 2000,
      }), "serve.new failed")
  assert(srv.listen(), "listen failed")

  local sock = check.must(net.dial("127.0.0.1", srv.port()),
    "client connect failed")
  assert(sock:send("GET http://127.0.0.1:" .. port .. "/hi HTTP/1.1\r\n"
      .. "Host: 127.0.0.1:" .. port .. "\r\n\r\n"))
  local cfd = check.must(srv.accept(), "proxy accept failed")

  local worker = proc.fork()
  if worker == 0 then
    srv.handle(cfd)
    os.exit(0)
  end
  -- Drop the parent's copy or the client never sees EOF once the
  -- worker closes its own.
  assert(fd.wrap(cfd):close())

  local parts: {string} = {}
  while true do
    local chunk = sock:recv(4096)
    if not chunk then break end
    parts[#parts + 1] = chunk
  end
  assert(sock:close())
  local resp = table.concat(parts)
  assert(proc.wait(worker))
  -- The upstream is still parked in accept() and always will be --
  -- that is the point -- so kill it rather than waiting on it.
  assert(signal.kill(pid, signal.SIGKILL))
  assert(proc.wait(pid))

  assert(not resp:find(UPSTREAM_BODY, 1, true),
    "the allowlist must not reach a loopback upstream, got: " .. resp)
  assert(not resp:find("^HTTP/1%.1 403 "),
    "the rule engine should have ALLOWED this host, got a deny: "
    .. resp:sub(1, 40))
  assert(resp:find("^HTTP/1%.1 502 "),
    "a blocked upstream should surface as 502, got: " .. resp:sub(1, 40))
end
test_allowlist_does_not_bypass_the_ssrf_guard()
