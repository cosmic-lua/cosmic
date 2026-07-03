#!/usr/bin/env cosmic
local request = require("cosmic.httpapi.request")

local function test_parse_get_request()
  local raw = "GET /hello HTTP/1.1\r\nHost: localhost\r\n\r\n"
  local req, err = request.parse(raw)
  assert(req ~= nil, "parse failed: " .. tostring(err))
  assert(req.method == "GET", "expected GET, got " .. tostring(req.method))
  assert(req.path == "/hello", "expected /hello, got " .. tostring(req.path))
  assert(req.headers["host"] == "localhost",
    "expected host header, got " .. tostring(req.headers["host"]))
end
test_parse_get_request()

local function test_parse_post_with_body()
  local raw = "POST /data HTTP/1.1\r\n"
  .. "Host: localhost\r\n"
  .. "Content-Length: 13\r\n"
  .. "\r\n"
  .. '{"key":"val"}'
  local req, err = request.parse(raw)
  assert(req ~= nil, "parse failed: " .. tostring(err))
  assert(req.method == "POST", "expected POST")
  assert(req.path == "/data", "expected /data")
  assert(req.body == '{"key":"val"}', "expected body, got " .. tostring(req.body))
end
test_parse_post_with_body()

local function test_parse_query_string()
  local raw = "GET /search?q=hello&page=2 HTTP/1.1\r\nHost: localhost\r\n\r\n"
  local req, err = request.parse(raw)
  assert(req ~= nil, "parse failed: " .. tostring(err))
  assert(req.path == "/search", "expected /search, got " .. tostring(req.path))
  assert(req.query == "q=hello&page=2",
    "expected query string, got " .. tostring(req.query))
  assert(req.query_params["q"] == "hello",
    "expected q=hello, got " .. tostring(req.query_params["q"]))
  assert(req.query_params["page"] == "2",
    "expected page=2, got " .. tostring(req.query_params["page"]))
end
test_parse_query_string()

local function test_parse_raw_path()
  local raw = "GET /users/42?fields=name HTTP/1.1\r\nHost: localhost\r\n\r\n"
  local req, err = request.parse(raw)
  assert(req ~= nil, "parse failed: " .. tostring(err))
  assert(req.raw_path == "/users/42?fields=name",
    "expected raw_path, got " .. tostring(req.raw_path))
end
test_parse_raw_path()

local function test_parse_multiple_headers()
  local raw = "GET / HTTP/1.1\r\n"
  .. "Host: localhost\r\n"
  .. "Accept: application/json\r\n"
  .. "Authorization: Bearer tok123\r\n"
  .. "\r\n"
  local req, err = request.parse(raw)
  assert(req ~= nil, "parse failed: " .. tostring(err))
  assert(req.headers["accept"] == "application/json", "expected accept header")
  assert(req.headers["authorization"] == "Bearer tok123", "expected auth header")
end
test_parse_multiple_headers()

local function test_parse_empty_path()
  local raw = "GET / HTTP/1.1\r\nHost: localhost\r\n\r\n"
  local req, err = request.parse(raw)
  assert(req ~= nil, "parse failed: " .. tostring(err))
  assert(req.path == "/", "expected /, got " .. tostring(req.path))
  assert(req.query == nil or req.query == "", "expected no query")
end
test_parse_empty_path()

local function test_parse_invalid_request_line()
  local raw = "INVALID\r\nHost: localhost\r\n\r\n"
  local req, err = request.parse(raw)
  assert(req == nil, "expected parse to fail")
  assert(err ~= nil, "expected error message")
end
test_parse_invalid_request_line()

local function test_parse_empty_input()
  local req, err = request.parse("")
  assert(req == nil, "expected parse to fail on empty input")
  assert(err ~= nil, "expected error message")
end
test_parse_empty_input()

local function test_params_initialized_empty()
  local raw = "GET / HTTP/1.1\r\nHost: localhost\r\n\r\n"
  local req = request.parse(raw)
  assert(req ~= nil, "parse failed")
  assert(req.params ~= nil, "expected params table")
end
test_params_initialized_empty()
