#!/usr/bin/env cosmic
--- End-to-end tests for the proxy's request-body limits (#497): a
--- Content-Length over max_body_bytes is refused with 413 and a
--- malformed one with 400, in both cases before a single body byte is
--- read or buffered. Every request here is refused before the upstream
--- dial, so the tests need only loopback sockets, no DNS or egress.
local check = require("cosmic.check")
local serve = require("cosmic.quicksand.proxy.serve")
local net = require("cosmic.net")

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
  local sock = check.must(net.connect_tcp("127.0.0.1", srv.port()), "connect failed")
  assert(sock:send(request))
  local fd = check.must(srv.accept(), "accept failed")
  srv.handle(fd)
  local parts: {string} = {}
  while true do
    local chunk = sock:recv(4096)
    if not chunk then break end
    table.insert(parts, (check.must(chunk)))
  end
  sock:close()
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
