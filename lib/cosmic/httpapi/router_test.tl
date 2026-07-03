#!/usr/bin/env cosmic
local router = require("cosmic.httpapi.router")
local response = require("cosmic.httpapi.response")
local types = require("cosmic.httpapi.types")
local request_mod = require("cosmic.httpapi.request")

local function ok_handler(_req: request_mod.Request): response.Response
  return response.text("ok")
end

local function user_handler(_req: request_mod.Request): response.Response
  return response.text("user")
end

local function test_exact_match()
  local r = router.new()
  r:add("GET", "/hello", ok_handler)
  local handler, params = r:match("GET", "/hello")
  assert(handler ~= nil, "expected handler for GET /hello")
  assert(params ~= nil, "expected params table")
  assert(next(params) == nil, "expected empty params for exact match")
end
test_exact_match()

local function test_no_match_returns_nil()
  local r = router.new()
  r:add("GET", "/hello", ok_handler)
  local handler = r:match("GET", "/world")
  assert(handler == nil, "expected nil for unmatched path")
end
test_no_match_returns_nil()

local function test_method_mismatch()
  local r = router.new()
  r:add("GET", "/hello", ok_handler)
  local handler = r:match("POST", "/hello")
  assert(handler == nil, "expected nil for method mismatch")
end
test_method_mismatch()

local function test_param_capture()
  local r = router.new()
  r:add("GET", "/users/{id}", user_handler)
  local handler, params = r:match("GET", "/users/42")
  assert(handler ~= nil, "expected handler for /users/42")
  assert(params["id"] == "42", "expected id=42, got " .. tostring(params["id"]))
end
test_param_capture()

local function test_multiple_params()
  local r = router.new()
  r:add("GET", "/users/{user_id}/posts/{post_id}", ok_handler)
  local handler, params = r:match("GET", "/users/7/posts/99")
  assert(handler ~= nil, "expected handler")
  assert(params["user_id"] == "7",
    "expected user_id=7, got " .. tostring(params["user_id"]))
  assert(params["post_id"] == "99",
    "expected post_id=99, got " .. tostring(params["post_id"]))
end
test_multiple_params()

local function test_root_path()
  local r = router.new()
  r:add("GET", "/", ok_handler)
  local handler = r:match("GET", "/")
  assert(handler ~= nil, "expected handler for root path")
end
test_root_path()

local function test_trailing_slash_no_match()
  local r = router.new()
  r:add("GET", "/hello", ok_handler)
  local handler = r:match("GET", "/hello/")
  assert(handler == nil, "expected no match for trailing slash")
end
test_trailing_slash_no_match()

local function test_multiple_routes()
  local r = router.new()
  r:add("GET", "/a", ok_handler)
  r:add("POST", "/b", user_handler)
  local h1 = r:match("GET", "/a")
  local h2 = r:match("POST", "/b")
  local h3 = r:match("GET", "/b")
  assert(h1 ~= nil, "expected handler for GET /a")
  assert(h2 ~= nil, "expected handler for POST /b")
  assert(h3 == nil, "expected nil for GET /b")
end
test_multiple_routes()

local function test_param_with_dashes()
  local r = router.new()
  r:add("GET", "/items/{slug}", ok_handler)
  local handler, params = r:match("GET", "/items/my-cool-item")
  assert(handler ~= nil, "expected handler")
  assert(params["slug"] == "my-cool-item",
    "expected slug, got " .. tostring(params["slug"]))
end
test_param_with_dashes()

local function test_same_path_different_methods()
  local r = router.new()
  r:add("GET", "/resource", ok_handler)
  r:add("POST", "/resource", user_handler)
  local h1 = r:match("GET", "/resource")
  local h2 = r:match("POST", "/resource")
  assert(h1 ~= nil, "expected GET handler")
  assert(h2 ~= nil, "expected POST handler")
  assert(h1 ~= h2, "expected different handlers")
end
test_same_path_different_methods()

local _ = types
