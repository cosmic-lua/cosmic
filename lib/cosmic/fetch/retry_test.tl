#!/usr/bin/env cosmic
--- Retry policy tests (issue #530 part 2): transport errors retry under
--- the default policy, retryable statuses retry for idempotent methods,
--- and custom should_retry sees failures too. All against forked
--- loopback servers; base_delay is tiny so backoff never slows the suite.
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
--- retried — leaving this child blocked in accept() forever (#574).
--- The child also arms a lifetime alarm: if the client stops early for
--- any other reason, SIGALRM's default action kills the child so
--- proc.wait() can never hang the suite.
local function serve(responses: {string}): integer, integer
  local srv, port = net.listen_tcp("127.0.0.1", 0)
  assert(srv ~= nil, "listen_tcp failed")
  local s = srv as net.Socket
  local pid = proc.fork()
  if pid == 0 then
    signal.setitimer({
        which = signal.ITIMER_REAL,
        valuesec = 30,
        valuens = 0,
        intervalsec = 0,
        intervalns = 0,
      })
    for _, resp in ipairs(responses) do
      local conn = s:accept()
      if conn then
        local c = conn as net.Socket
        if #resp > 0 then
          local buf = ""
          while not buf:find("\r\n\r\n", 1, true) do
            local data = c:recv(4096)
            if not data or #data == 0 then break end
            buf = buf .. data
          end
          c:send(resp)
        else
          c:recv(1)
        end
        c:close()
      end
    end
    os.exit(0)
  end
  s:close()
  return math.tointeger(port), pid
end

local function test_default_policy_retries_transport_error()
  -- first connection is accepted then closed without a response (a
  -- transport error, kind "connect"); the second attempt gets a 200.
  -- Before #530 the retry loop only consulted should_retry when
  -- result.ok was true, so this could never succeed.
  local port, pid = serve({"", body_response("200 OK", "recovered")})
  local result = fetch.fetch("http://127.0.0.1:" .. port .. "/",
    {allow_private = true, max_attempts = 2, base_delay = 0.01})
  proc.wait(pid)
  assert(result.ok == true,
    "transport error must be retried under the default policy, got: " .. tostring(result.error))
  assert(result.body == "recovered", "second attempt's body expected")
end
test_default_policy_retries_transport_error()

local function test_default_policy_retries_503()
  local port, pid = serve({
      body_response("503 Service Unavailable", "busy"),
      body_response("200 OK", "fine"),
    })
  local result = fetch.fetch("http://127.0.0.1:" .. port .. "/",
    {allow_private = true, max_attempts = 2, base_delay = 0.01})
  proc.wait(pid)
  assert(result.ok == true and result.status == 200,
    "503 must be retried under the default policy, got " .. tostring(result.status))
end
test_default_policy_retries_503()

local function test_default_policy_does_not_retry_post()
  -- POST is not idempotent: the default policy must return the 503
  -- untouched instead of replaying the request.
  local port, pid = serve({body_response("503 Service Unavailable", "busy")})
  local result = fetch.fetch("http://127.0.0.1:" .. port .. "/",
    {allow_private = true, method = "POST", body = "x",
      max_attempts = 3, base_delay = 0.01})
  proc.wait(pid)
  assert(result.ok == true and result.status == 503,
    "POST must not be retried by default, got " .. tostring(result.status))
end
test_default_policy_does_not_retry_post()

local function test_default_policy_does_not_retry_404()
  local port, pid = serve({body_response("404 Not Found", "gone")})
  local result = fetch.fetch("http://127.0.0.1:" .. port .. "/",
    {allow_private = true, max_attempts = 3, base_delay = 0.01})
  proc.wait(pid)
  assert(result.ok == true and result.status == 404,
    "404 is not retryable, got " .. tostring(result.status))
end
test_default_policy_does_not_retry_404()

local function test_custom_should_retry_sees_failures()
  -- a custom predicate is consulted for failed attempts too (the old
  -- loop returned transport errors immediately, without asking)
  local seen: {boolean} = {}
  local port, pid = serve({"", body_response("200 OK", "again")})
  local result = fetch.fetch("http://127.0.0.1:" .. port .. "/", {
      allow_private = true,
      max_attempts = 2,
      base_delay = 0.01,
      should_retry = function(r: fetch.Result): boolean
        table.insert(seen, r.ok)
        return not r.ok
      end,
    })
  proc.wait(pid)
  assert(result.ok == true, "custom retry of a transport error must succeed")
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
      base_delay = 0.01,
      should_retry = function(_: fetch.Result): boolean
        attempts = attempts + 1
        return false
      end,
    })
  proc.wait(pid)
  assert(result.status == 503, "the 503 must be returned as-is")
  assert(attempts == 1, "should_retry must be asked exactly once, got " .. attempts)
end
test_custom_should_retry_false_stops()

local function test_exhausted_attempts_return_last_failure()
  local port, pid = serve({"", ""})
  local result = fetch.fetch("http://127.0.0.1:" .. port .. "/",
    {allow_private = true, max_attempts = 2, base_delay = 0.01})
  proc.wait(pid)
  assert(result.ok == false, "both attempts failed; ok must be false")
  assert(result.error_kind == "connect",
    "the transport failure kind survives, got " .. tostring(result.error_kind))
end
test_exhausted_attempts_return_last_failure()

local function test_validation_error_has_no_kind_and_default_never_retries()
  -- validation failures carry no error_kind, so the default policy's
  -- retryable-kind check can never match them
  local result = fetch.fetch("ftp://example.com/",
    {max_attempts = 3, base_delay = 0.01})
  assert(result.ok == false, "validation failure expected")
  assert(result.error_kind == nil, "validation failures have no error_kind")
  assert(result.error:find("unsupported URL scheme") ~= nil,
    "the validation error must survive retries untouched")
end
test_validation_error_has_no_kind_and_default_never_retries()
