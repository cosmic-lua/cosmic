#!/usr/bin/env cosmic
local http = require("cosmic.quicksand.proxy.http")
local net = require("cosmic.net")
local proc = require("cosmic.proc")
local signal = require("cosmic.signal")
local pollmod = require("cosmic.poll")
local time = require("cosmic.time")
local check = require("cosmic.check")

local function test_parse_request_line()
  local line = check.must(http.parse_request_line(
      "GET http://a.example.com/ HTTP/1.1\r\n"))
  assert(line.method == "GET", "method: " .. tostring(line.method))
  assert(line.target == "http://a.example.com/", "target: " .. tostring(line.target))
  assert(line.version == "HTTP/1.1", "version: " .. tostring(line.version))
  assert(http.parse_request_line("bogus\r\n") == nil, "garbage rejected")
  assert(http.parse_request_line("get / HTTP/1.1\r\n") == nil,
    "lowercase method rejected")
end
test_parse_request_line()

local function test_parse_connect_target()
  local h, p = http.parse_connect_target("a.example.com:443")
  assert(h == "a.example.com" and p == 443, "host:port parsed")
  assert(http.parse_connect_target("a.example.com") == nil,
    "portless target rejected")
  assert(http.parse_connect_target("a.example.com:x") == nil,
    "non-numeric port rejected")
end
test_parse_connect_target()

local function test_parse_absolute_uri()
  local u = check.must(http.parse_absolute_uri("http://a.example.com/x/y"))
  assert(u.scheme == "http" and u.host == "a.example.com", "scheme + host")
  assert(u.port == 80 and u.path == "/x/y", "default http port + path")
  u = check.must(http.parse_absolute_uri("https://a.example.com"))
  assert(u.scheme == "https" and u.port == 443 and u.path == "/",
    "https default port, bare path")
  u = check.must(http.parse_absolute_uri("http://a.example.com:8080/z"))
  assert(u.port == 8080 and u.path == "/z", "explicit port")
  assert(http.parse_absolute_uri("/origin-form") == nil,
    "origin-form rejected")
  assert(http.parse_absolute_uri("ftp://a.example.com/") == nil,
    "non-http scheme rejected")
end
test_parse_absolute_uri()

local function test_headers_and_content_length()
  local block = "GET / HTTP/1.1\r\nHost: a.example.com\r\n"
  .. "Content-Length: 5\r\nX-Foo: bar\r\n\r\n"
  local headers = http.parse_headers(block)
  assert(#headers == 3, "three headers, got " .. tostring(#headers))
  assert(http.header_get(headers, "x-foo") == "bar", "case-insensitive get")
  assert(http.header_get(headers, "absent") == nil, "missing header is nil")
  assert(http.content_length(headers) == 5, "content-length parsed")
  assert(http.content_length({}) == 0, "absent content-length is 0")
end
test_headers_and_content_length()

-- Content-Length is 1*DIGIT (RFC 7230). tonumber() leniency would let a
-- client name a hex, exponent, or negative body size; anything but a
-- plain digit string must read as malformed (nil), not silently as 0 —
-- a "0" misread desyncs the connection with the body still unread.
local function test_content_length_strict()
  local function cl(v: string): integer | nil
    local block = "POST / HTTP/1.1\r\nContent-Length: " .. v .. "\r\n\r\n"
    return http.content_length(http.parse_headers(block))
  end
  assert(cl("0") == 0, "zero parses")
  assert(cl("5") == 5, "digits parse")
  assert(cl("007") == 7, "leading zeros parse")
  assert(cl("banana") == nil, "garbage is malformed")
  assert(cl("-5") == nil, "negative is malformed")
  assert(cl("1e3") == nil, "exponent is malformed")
  assert(cl("0x10") == nil, "hex is malformed")
  assert(cl("4 4") == nil, "embedded space is malformed")
  assert(cl("5.0") == nil, "float is malformed")
  assert(cl("99999999999999999999999999") == nil,
    "integer overflow is malformed")
end
test_content_length_strict()

local function test_rebuild_request_injects_and_strips()
  local block = "POST http://a.example.com/p HTTP/1.1\r\n"
  .. "Host: a.example.com\r\nContent-Length: 5\r\nX-Foo: bar\r\n"
  .. "Proxy-Connection: keep-alive\r\n\r\n"
  local req = http.rebuild_request({
      method = "POST",
      path = "/p",
      headers = http.parse_headers(block),
      body = "hello",
      host_hdr = "b.example.com:8080",
      inject_name = "Authorization",
      inject_value = "Bearer t",
    })
  assert(req:find("^POST /p HTTP/1.1\r\n") ~= nil, "origin-form request line")
  assert(req:find("Host: b.example.com:8080\r\n", 1, true) ~= nil,
    "host rewritten to upstream target")
  assert(req:find("Host: a.example.com", 1, true) == nil,
    "client host stripped")
  assert(req:find("Authorization: Bearer t\r\n", 1, true) ~= nil,
    "auth injected")
  assert(req:find("Content-Length: 5\r\n", 1, true) ~= nil,
    "content-length reissued from body")
  assert(req:find("Connection: close\r\n", 1, true) ~= nil,
    "connection: close set")
  assert(req:find("Proxy-Connection", 1, true) == nil,
    "hop-by-hop proxy-connection stripped")
  assert(req:find("X-Foo: bar\r\n", 1, true) ~= nil,
    "end-to-end headers preserved")
  assert(req:sub(-5) == "hello", "body appended")
end
test_rebuild_request_injects_and_strips()

-- The injected auth header must REPLACE any client-supplied header of
-- the same name — the boxed workload must not be able to smuggle its
-- own credentials past the proxy's injection.
local function test_rebuild_request_replaces_client_auth()
  local block = "GET http://a.example.com/ HTTP/1.1\r\n"
  .. "Authorization: Bearer evil\r\nTE: trailers\r\n\r\n"
  local req = http.rebuild_request({
      method = "GET",
      path = "/",
      headers = http.parse_headers(block),
      body = nil,
      host_hdr = "a.example.com",
      inject_name = "Authorization",
      inject_value = "Bearer good",
    })
  assert(req:find("Bearer good", 1, true) ~= nil, "injected auth present")
  assert(req:find("Bearer evil", 1, true) == nil, "client auth replaced")
  assert(req:find("TE:", 1, true) == nil, "hop-by-hop TE stripped")
  assert(req:find("Content-Length: 0\r\n", 1, true) ~= nil,
    "bodyless request gets content-length 0")
end
test_rebuild_request_replaces_client_auth()

-- Regression: pump() used to return (tearing down the CONNECT tunnel)
-- on ANY unix.poll failure, including EINTR. A one-shot SIGALRM fires
-- ~50ms into a forked pump's initial (data-less) poll; the parent only
-- sends its payload ~150ms in, well after the old code would have
-- already torn the tunnel down. No unshare needed -- pump() is plain
-- fd plumbing over a plain fork, like proxy/serve_test.tl's worker.
local function test_pump_relays_data_across_eintr()
  local cp = check.must(net.socket_pair())
  local c1, c2 = cp.a, cp.b
  local up = check.must(net.socket_pair())
  local u1, u2 = up.a, up.b

  local pid = proc.fork()
  if pid == nil then
    assert(c1:close())
    assert(c2:close())
    assert(u1:close())
    assert(u2:close())
    check.enforce_skip("pump EINTR: fork unavailable")
    return
  end
  if pid == 0 then
    assert(c1:close())
    assert(u1:close())
    assert(signal.sigaction(signal.SIGALRM, function() end))
    assert(signal.setitimer({
          which = signal.ITIMER_REAL,
          value_ms = 50,
          interval_ms = 0,
        }))
    http.pump(c2:fd(), u2:fd())
    os.exit(0)
  end

  assert(c2:close())
  assert(u2:close())
  assert(time.sleep_ms(150))
  local payload = "hello-through-pump"
  local sent = c1:send(payload)
  assert(sent == #payload, "send failed: " .. tostring(sent))

  local pp = pollmod.new()
  assert(pp:add(u1:fd(), pollmod.POLLIN))
  local ready = check.must(pp:wait(2000))
  assert(ready[u1:fd()], "pump should have relayed the payload across the EINTR")
  local got = u1:recv(64)
  assert(got == payload, "expected relayed payload, got: " .. tostring(got))

  assert(c1:close())
  assert(u1:close())
  assert(proc.wait(pid))
end
test_pump_relays_data_across_eintr()
