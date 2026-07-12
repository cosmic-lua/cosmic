#!/usr/bin/env cosmic
local http = require("cosmic.quicksand.proxy.http")

local function test_parse_request_line()
  local m, t, v = http.parse_request_line("GET http://a.example.com/ HTTP/1.1\r\n")
  assert(m == "GET", "method: " .. tostring(m))
  assert(t == "http://a.example.com/", "target: " .. tostring(t))
  assert(v == "HTTP/1.1", "version: " .. tostring(v))
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
  local s, h, p, path = http.parse_absolute_uri("http://a.example.com/x/y")
  assert(s == "http" and h == "a.example.com", "scheme + host")
  assert(p == 80 and path == "/x/y", "default http port + path")
  s, h, p, path = http.parse_absolute_uri("https://a.example.com")
  assert(s == "https" and p == 443 and path == "/",
    "https default port, bare path")
  s, h, p, path = http.parse_absolute_uri("http://a.example.com:8080/z")
  assert(p == 8080 and path == "/z", "explicit port")
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
