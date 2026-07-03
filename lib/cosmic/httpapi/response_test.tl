#!/usr/bin/env cosmic
local response = require("cosmic.httpapi.response")

local function test_new_response()
  local r = response.new(200, "hello")
  assert(r.status == 200, "expected status 200, got " .. tostring(r.status))
  assert(r.body == "hello", "expected body 'hello', got " .. tostring(r.body))
  assert(r.headers ~= nil, "expected headers table")
end
test_new_response()

local function test_new_with_headers()
  local r = response.new(201, "created", {["X-Custom"] = "yes"})
  assert(r.status == 201, "expected status 201")
  assert(r.headers["X-Custom"] == "yes", "expected custom header")
end
test_new_with_headers()

local function test_json_response()
  local r = response.json({name = "alice"})
  assert(r.status == 200, "expected status 200, got " .. tostring(r.status))
  assert(r.headers["Content-Type"] == "application/json", "expected json content type")
  assert(r.body:find('"name"'), "expected json body with name field")
  assert(r.body:find('"alice"'), "expected json body with alice value")
end
test_json_response()

local function test_json_custom_status()
  local r = response.json({error = "not found"}, 404)
  assert(r.status == 404, "expected status 404, got " .. tostring(r.status))
end
test_json_custom_status()

local function test_text_response()
  local r = response.text("hello world")
  assert(r.status == 200, "expected status 200")
  assert(r.body == "hello world", "expected text body")
  assert(r.headers["Content-Type"] == "text/plain; charset=utf-8",
    "expected text content type, got " .. tostring(r.headers["Content-Type"]))
end
test_text_response()

local function test_text_custom_status()
  local r = response.text("not found", 404)
  assert(r.status == 404, "expected status 404")
end
test_text_custom_status()

local function test_html_response()
  local r = response.html("<h1>Hello</h1>")
  assert(r.status == 200, "expected status 200")
  assert(r.body == "<h1>Hello</h1>", "expected html body")
  assert(r.headers["Content-Type"] == "text/html; charset=utf-8",
    "expected html content type")
end
test_html_response()

local function test_redirect_response()
  local r = response.redirect("/new-location")
  assert(r.status == 302, "expected status 302, got " .. tostring(r.status))
  assert(r.headers["Location"] == "/new-location", "expected location header")
  assert(r.body == "", "expected empty body")
end
test_redirect_response()

local function test_redirect_permanent()
  local r = response.redirect("/permanent", 301)
  assert(r.status == 301, "expected status 301")
end
test_redirect_permanent()

local function test_serialize_basic()
  local r = response.new(200, "OK")
  local raw = response.serialize(r)
  assert(raw:find("HTTP/1.1 200"), "expected HTTP status line, got: " .. raw:sub(1, 40))
  assert(raw:find("Content%-Length: 2"), "expected content-length header")
  assert(raw:find("\r\n\r\nOK$"), "expected body after blank line")
end
test_serialize_basic()

local function test_serialize_headers()
  local r = response.new(404, "nope", {["X-Test"] = "val"})
  local raw = response.serialize(r)
  assert(raw:find("HTTP/1.1 404"), "expected 404 status")
  assert(raw:find("X%-Test: val"), "expected custom header in output")
end
test_serialize_headers()

local function test_serialize_empty_body()
  local r = response.new(204, "")
  local raw = response.serialize(r)
  assert(raw:find("HTTP/1.1 204"), "expected 204 status")
  assert(raw:find("Content%-Length: 0"), "expected zero content-length")
end
test_serialize_empty_body()
