#!/usr/bin/env cosmic
local middleware = require("cosmic.httpapi.middleware")
local response = require("cosmic.httpapi.response")
local request_mod = require("cosmic.httpapi.request")
local types = require("cosmic.httpapi.types")

-- Track call order
local call_log: {string} = {}

local function make_handler(): types.Handler
  return function(_req: request_mod.Request): response.Response
    table.insert(call_log, "handler")
    return response.text("ok")
  end
end

local function test_chain_no_middleware()
  call_log = {}
  local handler = make_handler()
  local chained = middleware.chain({}, handler)
  local resp = chained(nil as request_mod.Request)
  assert(resp.body == "ok", "expected ok body")
  assert(#call_log == 1, "expected 1 call")
  assert(call_log[1] == "handler", "expected handler call")
end
test_chain_no_middleware()

local function test_single_middleware()
  call_log = {}
  local mw: types.Middleware =
  function(req: request_mod.Request, nxt: types.Handler): response.Response
    table.insert(call_log, "before")
    local resp = nxt(req)
    table.insert(call_log, "after")
    resp.headers["X-MW"] = "applied"
    return resp
  end
  local handler = make_handler()
  local chained = middleware.chain({mw}, handler)
  local resp = chained(nil as request_mod.Request)
  assert(resp.headers["X-MW"] == "applied", "expected middleware header")
  assert(#call_log == 3, "expected 3 calls, got " .. tostring(#call_log))
  assert(call_log[1] == "before", "expected before first")
  assert(call_log[2] == "handler", "expected handler second")
  assert(call_log[3] == "after", "expected after third")
end
test_single_middleware()

local function test_middleware_order()
  call_log = {}
  local mw1: types.Middleware =
  function(req: request_mod.Request, nxt: types.Handler): response.Response
    table.insert(call_log, "mw1-before")
    local resp = nxt(req)
    table.insert(call_log, "mw1-after")
    return resp
  end
  local mw2: types.Middleware =
  function(req: request_mod.Request, nxt: types.Handler): response.Response
    table.insert(call_log, "mw2-before")
    local resp = nxt(req)
    table.insert(call_log, "mw2-after")
    return resp
  end
  local handler = make_handler()
  local chained = middleware.chain({mw1, mw2}, handler)
  chained(nil as request_mod.Request)
  assert(#call_log == 5, "expected 5 calls, got " .. tostring(#call_log))
  assert(call_log[1] == "mw1-before", "first middleware runs first")
  assert(call_log[2] == "mw2-before", "second middleware runs second")
  assert(call_log[3] == "handler", "handler runs in the middle")
  assert(call_log[4] == "mw2-after", "second middleware after")
  assert(call_log[5] == "mw1-after", "first middleware after last")
end
test_middleware_order()

local function test_middleware_short_circuit()
  call_log = {}
  local blocker: types.Middleware =
  function(_req: request_mod.Request, _nxt: types.Handler): response.Response
    table.insert(call_log, "blocked")
    return response.json({error = "forbidden"}, 403)
  end
  local handler = make_handler()
  local chained = middleware.chain({blocker}, handler)
  local resp = chained(nil as request_mod.Request)
  assert(resp.status == 403, "expected 403, got " .. tostring(resp.status))
  assert(#call_log == 1, "expected only blocker call")
  assert(call_log[1] == "blocked", "expected blocked")
end
test_middleware_short_circuit()

local function test_middleware_modifies_request()
  call_log = {}
  local injector: types.Middleware =
  function(req: request_mod.Request, nxt: types.Handler): response.Response
    req.headers["x-injected"] = "yes"
    return nxt(req)
  end
  local handler: types.Handler =
  function(req: request_mod.Request): response.Response
    assert(req.headers["x-injected"] == "yes", "expected injected header")
    return response.text("ok")
  end
  local chained = middleware.chain({injector}, handler)
  local req = request_mod.parse("GET / HTTP/1.1\r\nHost: localhost\r\n\r\n")
  assert(req ~= nil, "parse failed")
  chained(req)
end
test_middleware_modifies_request()
