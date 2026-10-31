--- Coverage for [`Http.Options.retry`] without the network: each case
--- reads canned replies through the scripted transport, where the Nth
--- attempt reads entry N, so the reply that comes back says how many
--- requests were sent (each carries an `X-N` header of its own number).
--- A caught signal ending a retry's wait is cosmic/http_retry_tool_test.tl's.

local Clock = require("cosmic.clock")
local Fs = require("cosmic.fs")
local Http = require("cosmic.http")
local Test = require("cosmic.test")
local Time = require("cosmic.time")

Test.policy{ loopback = { "127.0.0.1" } }

local url = "http://cosmic.test/"

--- A whole reply numbered `n`: a status line, `head`'s header lines, and
--- `body`, closing the connection after it.
local function reply(n: integer, status: string, head: string, body?: string): string
  body = body or ""
  return "HTTP/1.1 " .. status .. "\r\nX-N: " .. tostring(n) .. "\r\n" .. head ..
    "Content-Length: " .. tostring(#body) .. "\r\nConnection: close\r\n\r\n" .. body
end

--- The message of the raise `fn` ends in.
local function raised(fn: function()): string
  local ok, err = pcall(fn)
  assert(not ok, "expected a raise")
  return tostring(err)
end

local function test_a_429_with_retry_after_zero_is_sent_again()
  local got = assert(Http.get(url, { retry = { attempts = 2 }, script = {
    reply(1, "429 Too Many Requests", "Retry-After: 0\r\n", "slow down"),
    reply(2, "200 OK", "", "fine"),
  } }))
  assert(got.status == 200, tostring(got.status))
  assert(got.body == "fine", got.body)
  assert(got.headers["x-n"] == "2", tostring(got.headers["x-n"]))
end

local function test_without_retry_a_429_is_returned()
  local got = assert(Http.get(url, { script = {
    reply(1, "429 Too Many Requests", "Retry-After: 0\r\n"), reply(2, "200 OK", ""),
  } }))
  assert(got.status == 429 and got.headers["x-n"] == "1", tostring(got.status))
end

local function test_a_503_every_time_returns_the_last_after_the_attempts()
  local script = {
    reply(1, "503 Service Unavailable", ""),
    reply(2, "503 Service Unavailable", ""),
    reply(3, "503 Service Unavailable", ""),
    reply(4, "200 OK", ""),
  }
  local got = assert(Http.get(url, { retry = { attempts = 3, backoff_ns = 0 }, script = script }))
  assert(got.status == 503, tostring(got.status))
  assert(got.headers["x-n"] == "3", "the request was sent " .. tostring(got.headers["x-n"]) .. " times")
end

local function test_a_500_is_retried_only_when_statuses_names_it()
  local script = { reply(1, "500 Internal Server Error", ""), reply(2, "200 OK", "") }
  local plain = assert(Http.get(url, { retry = { attempts = 2, backoff_ns = 0 }, script = script }))
  assert(plain.status == 500 and plain.headers["x-n"] == "1", tostring(plain.status))
  local named = assert(Http.get(url, {
    retry = { attempts = 2, backoff_ns = 0, statuses = { 500 } }, script = script,
  }))
  assert(named.status == 200 and named.headers["x-n"] == "2", tostring(named.status))
end

local function test_a_post_body_is_sent_again()
  local response = assert(Http.open(url, {
    method = "POST", body = "payload",
    retry = { attempts = 2, backoff_ns = 0 },
    script = { reply(1, "503 Service Unavailable", ""), reply(2, "200 OK", "") },
  }))
  assert(response.status == 200 and response.headers["x-n"] == "2", tostring(response.status))
  local sent = response:sent()
  response:close()
  assert(sent:find("POST / HTTP/1.1\r\n", 1, true) == 1, sent)
  assert(sent:find("payload", 1, true) ~= nil, "the retry sent no body: " .. sent)
end

local function test_a_retry_after_beyond_max_wait_returns_the_response_at_once()
  local began = Clock.monotonic_ns()
  local got = assert(Http.get(url, {
    retry = { attempts = 3, backoff_ns = 0, max_wait_ns = Clock.seconds(5) },
    script = {
      reply(1, "429 Too Many Requests", "Retry-After: 3600\r\n"),
      reply(2, "200 OK", ""),
    },
  }))
  assert(Clock.monotonic_ns() - began < Clock.seconds(2), "the request waited")
  assert(got.status == 429 and got.headers["x-n"] == "1", tostring(got.status))
end

local function test_a_retry_after_date_in_the_past_is_no_wait()
  local began = Clock.monotonic_ns()
  local past = Time.format_http(Clock.now_ns() - Clock.seconds(3600))
  local got = assert(Http.get(url, {
    -- A backoff that would show if the date were not read.
    retry = { attempts = 2, backoff_ns = Clock.seconds(30) },
    script = {
      reply(1, "429 Too Many Requests", "Retry-After: " .. past .. "\r\n"),
      reply(2, "200 OK", ""),
    },
  }))
  assert(Clock.monotonic_ns() - began < Clock.seconds(5), "the request waited")
  assert(got.status == 200, tostring(got.status))
end

local function test_a_retry_after_date_ahead_is_waited_out()
  local ahead = Time.format_http(Clock.now_ns() + Clock.ms(1500))
  local began = Clock.monotonic_ns()
  local got = assert(Http.get(url, {
    retry = { attempts = 2, backoff_ns = 0 },
    script = {
      reply(1, "429 Too Many Requests", "Retry-After: " .. ahead .. "\r\n"),
      reply(2, "200 OK", ""),
    },
  }))
  local waited = Clock.monotonic_ns() - began
  -- The date has whole seconds, so the wait is between 0.5 and 1.5 s.
  assert(waited >= Clock.ms(400) and waited < Clock.seconds(3), tostring(waited))
  assert(got.status == 200, tostring(got.status))
end

local function test_without_retry_after_the_backoff_is_waited()
  local began = Clock.monotonic_ns()
  local got = assert(Http.get(url, {
    retry = { attempts = 2, backoff_ns = Clock.ms(300) },
    script = { reply(1, "503 Service Unavailable", ""), reply(2, "200 OK", "") },
  }))
  assert(Clock.monotonic_ns() - began >= Clock.ms(250))
  assert(got.status == 200, tostring(got.status))
end

local function test_a_download_retries_a_429_then_writes_the_body(tmp: string)
  local path = tmp .. "/got"
  local ok, why = Http.download(url, path, { retry = { attempts = 2 }, script = {
    reply(1, "429 Too Many Requests", "Retry-After: 0\r\n", "no"),
    reply(2, "200 OK", "", "the file"),
  } })
  assert(ok, why)
  assert(Fs.read(path) == "the file")
  local result = Http.download_result(url, tmp .. "/again", { retry = { attempts = 2 }, script = {
    reply(1, "503 Service Unavailable", "Retry-After: 0\r\n", "no"),
    reply(2, "200 OK", "", "again"),
  } })
  assert(result.kind == "downloaded", result.reason)
  assert(Fs.read(tmp .. "/again") == "again")
end

local function test_a_request_retries_with_its_method()
  local got = assert(Http.request("PUT", url, {
    body = "x", retry = { attempts = 2, backoff_ns = 0 },
    script = { reply(1, "503 Service Unavailable", ""), reply(2, "200 OK", "", "done") },
  }))
  assert(got.status == 200 and got.body == "done", tostring(got.status))
end

local function test_a_failed_open_is_not_retried()
  local response, why = Http.open(url, {
    retry = { attempts = 3, backoff_ns = 0 },
    script = {},
  })
  assert(response == nil and why ~= "", tostring(why))
end

--- A policy of the wrong shape raises naming the option, with a first
--- reply of 200 that would never ask for a retry, from each entry point.
-- TODO: test a policy of the wrong Lua type (attempts "3", a fractional
-- span, statuses 429) once a test may hold a mistyped value without a
-- cast, which build/ceilings.txt forbids adding: only values of the right
-- type are built here.
local function test_a_policy_of_the_wrong_shape_raises_naming_the_option(tmp: string)
  local record Case
    option: string
    policy: Http.Retry
  end
  local cases: {Case} = {
    { option = "attempts", policy = { attempts = 0 } },
    { option = "attempts", policy = { attempts = -3 } },
    { option = "statuses", policy = { attempts = 2, statuses = { 99 } } },
    { option = "statuses", policy = { attempts = 2, statuses = { 600 } } },
    { option = "statuses", policy = { attempts = 2, statuses = { 429, 0 } } },
    { option = "backoff_ns", policy = { attempts = 2, backoff_ns = -1 } },
    { option = "max_wait_ns", policy = { attempts = 2, max_wait_ns = -1 } },
  }
  for _, case in ipairs(cases) do
    local option, policy = "opts.retry." .. case.option, case.policy
    local function opts(): Http.Options
      return { retry = policy, script = { reply(1, "200 OK", "") } }
    end
    local entries: {string:function()} = {
      open = function() local _ = Http.open(url, opts()) end,
      get = function() local _ = Http.get(url, opts()) end,
      request = function() local _ = Http.request("PUT", url, opts()) end,
      download = function() local _ = Http.download(url, tmp .. "/never", opts()) end,
      download_result = function() local _ = Http.download_result(url, tmp .. "/never", opts()) end,
    }
    for name, entry in pairs(entries) do
      local err = raised(entry)
      assert(err:find("http: " .. option .. " must be", 1, true) ~= nil, name .. ": " .. err)
      -- Blamed on this file, the caller, not on a line of cosmic.http.
      assert(err:find("http_retry_test:", 1, true) ~= nil, name .. ": " .. err)
    end
  end
  assert(Fs.stat(tmp .. "/never") == nil)
end
