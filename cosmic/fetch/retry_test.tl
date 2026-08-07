#!/usr/bin/env cosmic
--- Retry policy tests: transport errors retry under
--- the default policy, retryable statuses retry for idempotent methods,
--- and custom should_retry sees failures too. All against forked
--- loopback servers; base_delay_ms is tiny so backoff never slows the suite.
local check = require("cosmic.check")
local fetch = require("cosmic.fetch")
local net = require("cosmic.net")
local proc = require("cosmic.proc")
local signal = require("cosmic.signal")

local function body_response(status_line: string, body: string): string
  return "HTTP/1.1 " .. status_line .. "\r\nContent-Length: " .. #body
  .. "\r\nConnection: close\r\n\r\n" .. body
end

--- Fork a loopback server that answers #responses requests in order.
--- An empty-string response reads ONE byte of the request and closes:
--- the byte guarantees the request has arrived, so close() always
--- finds unread bytes and the kernel answers with an RST — the client
--- deterministically sees a connection reset (error kind "connect").
--- Closing before the request arrives would send a clean FIN instead,
--- which classifies as an EOF-before-headers "protocol" error — not
--- retried — leaving this child blocked in accept() forever.
--- The child also arms a lifetime alarm: if the client stops early for
--- any other reason, SIGALRM's default action kills the child so
--- proc.wait() can never hang the suite.
local function serve(responses: {string}): integer, integer
  local srv = net.listen_tcp("127.0.0.1", 0)
  local s = check.must(srv, "listen_tcp failed")
  local port = check.must(s:getsockname()).port
  local pid = proc.fork()
  if pid == 0 then
    assert(signal.setitimer({
          which = signal.ITIMER_REAL,
          value_ms = 30000,
          interval_ms = 0,
        }))
    for _, resp in ipairs(responses) do
      local conn = s:accept()
      if conn then
        local c = conn
        if #resp > 0 then
          local buf = ""
          while not buf:find("\r\n\r\n", 1, true) do
            local data = c:recv(4096)
            if not data or #data == 0 then break end
            buf = buf .. data
          end
          assert(c:send(resp))
        else
          assert(c:recv(1))
        end
        assert(c:close())
      end
    end
    os.exit(0)
  end
  assert(s:close())
  return math.tointeger(port), pid
end

local function test_default_policy_retries_transport_error()
  -- first connection is accepted then closed without a response (a
  -- transport error, kind "connect"); the second attempt gets a 200.
  -- A retry loop that consults should_retry only when the attempt
  -- true can never recover from this.
  local port, pid = serve({"", body_response("200 OK", "recovered")})
  local result, err = fetch.fetch("http://127.0.0.1:" .. port .. "/",
    {allow_private = true, max_attempts = 2, base_delay_ms = 10})
  assert(proc.wait(pid))
  assert(result ~= nil,
    "transport error must be retried under the default policy, got: " .. tostring(err))
  assert(result.body == "recovered", "second attempt's body expected")
end
test_default_policy_retries_transport_error()

local function test_default_policy_retries_503()
  local port, pid = serve({
      body_response("503 Service Unavailable", "busy"),
      body_response("200 OK", "fine"),
    })
  local result = check.must(fetch.fetch("http://127.0.0.1:" .. port .. "/",
    {allow_private = true, max_attempts = 2, base_delay_ms = 10}))
  assert(proc.wait(pid))
  assert(result.status == 200,
    "503 must be retried under the default policy, got " .. tostring(result.status))
end
test_default_policy_retries_503()

local function test_default_policy_does_not_retry_post()
  -- POST is not idempotent: the default policy must return the 503
  -- untouched instead of replaying the request.
  local port, pid = serve({body_response("503 Service Unavailable", "busy")})
  local result = fetch.fetch("http://127.0.0.1:" .. port .. "/",
    {allow_private = true, method = "POST", body = "x",
      max_attempts = 3, base_delay_ms = 10})
  assert(proc.wait(pid))
  assert(result ~= nil, "the 503 must arrive as a Response")
  assert(result.status == 503,
    "POST must not be retried by default, got " .. tostring(result.status))
end
test_default_policy_does_not_retry_post()

local function test_default_policy_does_not_retry_404()
  local port, pid = serve({body_response("404 Not Found", "gone")})
  local result = fetch.fetch("http://127.0.0.1:" .. port .. "/",
    {allow_private = true, max_attempts = 3, base_delay_ms = 10})
  assert(proc.wait(pid))
  assert(result ~= nil, "the 404 must arrive as a Response")
  assert(result.status == 404,
    "404 is not retryable, got " .. tostring(result.status))
end
test_default_policy_does_not_retry_404()

local function test_custom_should_retry_sees_failures()
  -- a custom predicate is consulted for failed attempts too, rather
  -- than transport errors returning immediately without asking
  local seen: {boolean} = {}
  local port, pid = serve({"", body_response("200 OK", "again")})
  local result = fetch.fetch("http://127.0.0.1:" .. port .. "/", {
      allow_private = true,
      max_attempts = 2,
      base_delay_ms = 10,
      should_retry = function(r: fetch.Response, _e: fetch.Error): boolean
        table.insert(seen, r ~= nil)
        return r == nil
      end,
    })
  assert(proc.wait(pid))
  assert(result ~= nil, "custom retry of a transport error must succeed")
  assert(#seen == 1 and seen[1] == false,
    "should_retry must have been consulted with the failed result")
end
test_custom_should_retry_sees_failures()

local function test_custom_should_retry_false_stops()
  local port, pid = serve({body_response("503 Service Unavailable", "busy")})
  local attempts = 0
  local result = fetch.fetch("http://127.0.0.1:" .. port .. "/", {
      allow_private = true,
      max_attempts = 5,
      base_delay_ms = 10,
      should_retry = function(_: fetch.Response, _e: fetch.Error): boolean
        attempts = attempts + 1
        return false
      end,
    })
  assert(proc.wait(pid))
  assert(result ~= nil, "the 503 must arrive as a Response")
  assert(result.status == 503, "the 503 must be returned as-is")
  assert(attempts == 1, "should_retry must be asked exactly once, got " .. attempts)
end
test_custom_should_retry_false_stops()

local function test_exhausted_attempts_return_last_failure()
  local port, pid = serve({"", ""})
  local result, _err, errobj = fetch.fetch("http://127.0.0.1:" .. port .. "/",
    {allow_private = true, max_attempts = 2, base_delay_ms = 10})
  assert(proc.wait(pid))
  assert(result == nil, "both attempts failed; no Response may exist")
  assert(errobj and errobj.kind == "connect",
    "the transport failure kind survives, got " .. tostring(errobj and errobj.kind))
end
test_exhausted_attempts_return_last_failure()

-- FIX 15: max_attempts <= 0 used to skip the fetch loop entirely and
-- skip the attempt loop entirely. It is clamped to 1 real attempt.
local function test_max_attempts_zero_is_clamped_to_one()
  local port, pid = serve({body_response("200 OK", "ok")})
  local result, err = fetch.fetch("http://127.0.0.1:" .. port .. "/",
    {allow_private = true, max_attempts = 0})
  assert(proc.wait(pid))
  assert(result ~= nil and result.body == "ok",
    "max_attempts=0 should still make one real attempt, got: " .. tostring(err))
end
test_max_attempts_zero_is_clamped_to_one()

local function test_max_attempts_negative_is_clamped_to_one()
  local port, pid = serve({body_response("200 OK", "ok")})
  local result = fetch.fetch("http://127.0.0.1:" .. port .. "/",
    {allow_private = true, max_attempts = -5})
  assert(proc.wait(pid))
  assert(result ~= nil, "max_attempts=-5 should still make one real attempt")
end
test_max_attempts_negative_is_clamped_to_one()

local function test_validation_error_is_invalid_request_and_never_retries()
  -- validation failures carry kind invalid_request, which the retry
  -- table pins to false, so the default policy can never retry them
  local result, err, errobj = fetch.fetch("ftp://example.com/",
    {max_attempts = 3, base_delay_ms = 10})
  assert(result == nil, "validation failure expected")
  assert(errobj and errobj.kind == "invalid_request",
    "validation failures carry kind invalid_request")
  assert(err:find("unsupported URL scheme") ~= nil,
    "the validation error must survive retries untouched")
end
test_validation_error_is_invalid_request_and_never_retries()
