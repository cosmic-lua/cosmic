#!/usr/bin/env cosmic
--- Tests for cosmic.http.router. Pure, no sockets: a Request and a
--- Response are built as plain-table test doubles rather than through
--- a real connection, since the router only ever reads req.method and
--- req.path and writes req.params, res.status, and calls the Response
--- send verbs — a fake that answers those is the whole contract.
local ip = require("cosmic.ip")
local request = require("cosmic.http.request")
local response = require("cosmic.http.response")
local router = require("cosmic.http.router")

--- Reads back a fake Response's recorded status, headers and body.
local type Inspect = function(): (integer, {string: string}, string)

--- Reads back the params a handler most recently saw, or nil if it
--- never ran.
local type Ran = function(): {string: string} | nil

--- A minimal Request test double: only method, path and params matter
--- to the router, so the rest are placeholder values a real Request
--- always carries but this module never reads.
--- @param method string The request method, already uppercase
--- @param path string The request's decoded path
--- @return request.Request The double, cast from a plain table
local function fake_request(method: string, path: string): request.Request
  local req: {string: any} = {
    method = method,
    target = path,
    path = path,
    query = {},
    version = 11,
    headers = {},
    raw_headers = {},
    peer = ip.from_int(0),
    params = {},
  }
  req.header = function(_self: request.Request, _name: string): string | nil
    return nil
  end
  req.body = function(_self: request.Request): string | nil, string
    return ""
  end
  return req as request.Request -- cast: test double narrows the interface to what the router reads
end

--- A Response test double that records status/headers/body instead of
--- writing to a socket, plus an inspector to read what a handler did.
--- @return response.Response The double, cast from a plain table
--- @return Inspect Reads back status, headers, body
local function fake_response(): response.Response, Inspect
  local status = 200
  local headers: {string: string} = {}
  local body = ""

  local function record_send(self: response.Response, b: string): boolean, string
    status = self.status
    body = b
    return true, ""
  end

  local res: {string: any} = {status = 200}
  res.set_header = function(_self: response.Response, name: string, value: string)
    headers[name] = value
  end
  res.add_header = function(_self: response.Response, name: string, value: string)
    headers[name] = value
  end
  res.send = record_send
  res.text = function(self: response.Response, s: string): boolean, string
    return record_send(self, s)
  end
  res.html = function(self: response.Response, _h: any): boolean, string
    return record_send(self, "")
  end
  res.json = function(self: response.Response, _v: any): boolean, string
    return record_send(self, "")
  end
  res.redirect = function(self: response.Response, _l: string, _s?: integer): boolean, string
    return record_send(self, "")
  end
  res.start = function(_self: response.Response): boolean, string
    return true, ""
  end
  res.write = function(_self: response.Response, _chunk: string): boolean, string
    return true, ""
  end
  res.finish = function(_self: response.Response): boolean, string
    return true, ""
  end
  res.event = function(_self: response.Response, _ev: any): boolean, string
    return true, ""
  end

  local function inspect(): integer, {string: string}, string
    return status, headers, body
  end
  return res as response.Response, inspect -- cast: test double narrows the interface to what the router calls
end

--- A handler that records every request it was called with, once, so a
--- test can assert both that it ran and what it saw.
--- @return function(request.Request, response.Response) A handler that answers "ok" and remembers req.params
--- @return Ran Whether it ran, and with what params
local function recording_handler(): function(request.Request, response.Response), Ran
  local seen: {string: string} = nil
  local function h(req: request.Request, res: response.Response)
    seen = req.params
    local _ok, _err = res:text("ok")
  end
  local function ran(): {string: string} | nil
    return seen
  end
  return h, ran
end

local function test_literal_match()
  local rt = router.new()
  local h, ran = recording_handler()
  assert(rt:get("/todos", h))

  local res, inspect = fake_response()
  rt:handler()(fake_request("GET", "/todos"), res)
  local status, _headers, body = inspect()
  assert(status == 200, tostring(status))
  assert(body == "ok", body)
  assert(ran() ~= nil)
end

local function test_param_capture()
  local rt = router.new()
  local h, ran = recording_handler()
  assert(rt:delete("/todos/:id", h))

  local res = fake_response()
  rt:handler()(fake_request("DELETE", "/todos/42"), res)
  local params = ran()
  assert(params ~= nil and params.id == "42", tostring(params and params.id))
end

local function test_wildcard_capture_including_empty()
  local rt = router.new()
  local h, ran = recording_handler()
  assert(rt:get("/files/*rest", h))

  local res = fake_response()
  rt:handler()(fake_request("GET", "/files/a/b/c"), res)
  local params = ran()
  assert(params ~= nil and params.rest == "a/b/c", tostring(params and params.rest))

  local h2, ran2 = recording_handler()
  local rt2 = router.new()
  assert(rt2:get("/files/*rest", h2))
  local res2 = fake_response()
  rt2:handler()(fake_request("GET", "/files/"), res2)
  local params2 = ran2()
  assert(params2 ~= nil and params2.rest == "", tostring(params2 and params2.rest))
end

local function test_not_found_answers_404()
  local rt = router.new()
  assert(rt:get("/todos", (recording_handler())))

  local res, inspect = fake_response()
  rt:handler()(fake_request("GET", "/nope"), res)
  local status = inspect()
  assert(status == 404, tostring(status))
end

local function test_not_found_override()
  local rt = router.new()
  local custom_ran = false
  rt:not_found(function(_req: request.Request, res: response.Response)
      custom_ran = true
      res.status = 404
      local _ok, _err = res:text("nothing here")
    end)

  local res, inspect = fake_response()
  rt:handler()(fake_request("GET", "/nope"), res)
  local status, _headers, body = inspect()
  assert(custom_ran)
  assert(status == 404, tostring(status))
  assert(body == "nothing here", body)
end

local function test_method_mismatch_answers_405_with_allow()
  local rt = router.new()
  assert(rt:get("/todos", (recording_handler())))
  assert(rt:post("/todos", (recording_handler())))

  local res, inspect = fake_response()
  rt:handler()(fake_request("DELETE", "/todos"), res)
  local status, headers = inspect()
  assert(status == 405, tostring(status))
  assert(headers["Allow"] == "GET, POST", tostring(headers["Allow"]))
end

local function test_head_falls_back_to_get()
  local rt = router.new()
  local h, ran = recording_handler()
  assert(rt:get("/todos", h))

  local res, inspect = fake_response()
  rt:handler()(fake_request("HEAD", "/todos"), res)
  local status = inspect()
  assert(status == 200, tostring(status))
  assert(ran() ~= nil)
end

local function test_first_registered_wins()
  local rt = router.new()
  local first_ran = false
  local second_ran = false
  assert(rt:get("/todos/:id", function(_req: request.Request, res: response.Response)
        first_ran = true
        local _ok, _err = res:text("first")
      end))
  assert(rt:get("/todos/:id", function(_req: request.Request, res: response.Response)
        second_ran = true
        local _ok, _err = res:text("second")
      end))

  local res, inspect = fake_response()
  rt:handler()(fake_request("GET", "/todos/1"), res)
  local _status, _headers, body = inspect()
  assert(first_ran)
  assert(not second_ran)
  assert(body == "first", body)
end

local function test_any_matches_every_method()
  local rt = router.new()
  local h, ran = recording_handler()
  assert(rt:any("/ping", h))

  local res = fake_response()
  rt:handler()(fake_request("PATCH", "/ping"), res)
  assert(ran() ~= nil)
end

local function test_bad_pattern_empty_segment()
  local rt = router.new()
  local ok, err = rt:get("/todos//sub", (recording_handler()))
  assert(ok == false)
  assert(err:find("empty segment", 1, true), err)
end

local function test_bad_pattern_colon_no_name()
  local rt = router.new()
  local ok, err = rt:get("/todos/:", (recording_handler()))
  assert(ok == false)
  assert(err:find("':' segment has no name", 1, true), err)
end

local function test_bad_pattern_star_no_name()
  local rt = router.new()
  local ok, err = rt:get("/files/*", (recording_handler()))
  assert(ok == false)
  assert(err:find("'*' segment has no name", 1, true), err)
end

local function test_bad_pattern_star_not_last()
  local rt = router.new()
  local ok, err = rt:get("/files/*rest/more", (recording_handler()))
  assert(ok == false)
  assert(err:find("'*' segment must be last", 1, true), err)
end
