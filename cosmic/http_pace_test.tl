--- Coverage for [`Http.pacer`] and [`Http.Options.pace`] without the
--- network: replies are canned through the scripted transport, as in
--- cosmic/http_retry_test.tl, and each request's own start is read from
--- the clock around it.

local Clock = require("cosmic.clock")
local Fs = require("cosmic.fs")
local Http = require("cosmic.http")
local Test = require("cosmic.test")

Test.policy{ cpu_features = true, loopback = { "127.0.0.1" } }

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

local function ok_script(): {string}
  return { reply(1, "200 OK", "") }
end

local function test_a_first_request_does_not_wait()
  local pacer = Http.pacer(Clock.seconds(30))
  local began = Clock.monotonic_ns()
  local got = assert(Http.get(url, { pace = pacer, script = ok_script() }))
  assert(got.status == 200, tostring(got.status))
  assert(Clock.monotonic_ns() - began < Clock.seconds(5), "the first request waited")
end

local function test_two_requests_through_one_pacer_are_an_interval_apart()
  local pacer = Http.pacer(Clock.ms(200))
  local began = Clock.monotonic_ns()
  assert(Http.get(url, { pace = pacer, script = ok_script() }))
  assert(Http.get(url, { pace = pacer, script = ok_script() }))
  local took = Clock.monotonic_ns() - began
  assert(took >= Clock.ms(200), "the second request did not wait: " .. tostring(took))
  assert(took < Clock.seconds(5), "the second request waited too long: " .. tostring(took))
end

local function test_a_pacer_spaces_every_entry_point(tmp: string)
  local pacer = Http.pacer(Clock.ms(100))
  local began = Clock.monotonic_ns()
  local response = assert(Http.open(url, { pace = pacer, script = ok_script() }))
  response:close()
  assert(Http.request("PUT", url, { pace = pacer, script = ok_script() }))
  assert(Http.download(url, tmp .. "/one", { pace = pacer, script = ok_script() }))
  local result = Http.download_result(url, tmp .. "/two", { pace = pacer, script = ok_script() })
  assert(result.kind == "downloaded", result.reason)
  assert(Fs.stat(tmp .. "/two") ~= nil)
  local took = Clock.monotonic_ns() - began
  assert(took >= Clock.ms(300), "four requests took " .. tostring(took))
  assert(took < Clock.seconds(5), tostring(took))
end

local function test_two_pacers_do_not_wait_on_each_other()
  local slow, other = Http.pacer(Clock.seconds(30)), Http.pacer(Clock.seconds(30))
  assert(Http.get(url, { pace = slow, script = ok_script() }))
  local began = Clock.monotonic_ns()
  assert(Http.get(url, { pace = other, script = ok_script() }))
  assert(Clock.monotonic_ns() - began < Clock.seconds(5), "a pacer waited on another's request")
end

local function test_a_request_without_pace_does_not_wait_on_a_pacer()
  local pacer = Http.pacer(Clock.seconds(30))
  assert(Http.get(url, { pace = pacer, script = ok_script() }))
  local began = Clock.monotonic_ns()
  assert(Http.get(url, { script = ok_script() }))
  assert(Clock.monotonic_ns() - began < Clock.seconds(5), "an unpaced request waited")
end

--- The retry's wait (600 ms from the first request's start) is longer than
--- the interval (400 ms), so the pacer adds nothing to it; with the sum the
--- retry would take 1000 ms. The bound between leaves a slow host's
--- scheduling room on either side.
local function test_a_retry_waits_the_longer_of_its_wait_and_the_interval()
  local pacer = Http.pacer(Clock.ms(400))
  local began = Clock.monotonic_ns()
  local got = assert(Http.get(url, {
    pace = pacer, retry = { attempts = 2, backoff_ns = Clock.ms(600) },
    script = { reply(1, "503 Service Unavailable", ""), reply(2, "200 OK", "") },
  }))
  local took = Clock.monotonic_ns() - began
  assert(got.status == 200 and got.headers["x-n"] == "2", tostring(got.status))
  assert(took >= Clock.ms(580), "the retry did not wait out its backoff: " .. tostring(took))
  assert(took < Clock.ms(850), "the pacer's wait was added to the retry's: " .. tostring(took))
end

--- The other way round: the interval (200 ms) outlasts the retry's wait
--- (none), and every attempt is paced, not only the first.
local function test_every_retry_attempt_is_paced()
  local pacer = Http.pacer(Clock.ms(200))
  local began = Clock.monotonic_ns()
  local got = assert(Http.get(url, {
    pace = pacer, retry = { attempts = 3, backoff_ns = 0 },
    script = {
      reply(1, "503 Service Unavailable", ""),
      reply(2, "503 Service Unavailable", ""),
      reply(3, "200 OK", ""),
    },
  }))
  local took = Clock.monotonic_ns() - began
  assert(got.status == 200 and got.headers["x-n"] == "3", tostring(got.status))
  assert(took >= Clock.ms(400), "the attempts were not paced: " .. tostring(took))
  assert(took < Clock.seconds(5), tostring(took))
end

local function test_cancelled_ends_a_pacer_wait_at_once()
  local pacer = Http.pacer(Clock.seconds(30))
  assert(Http.get(url, { pace = pacer, script = ok_script() }))
  local began = Clock.monotonic_ns()
  local got, why = Http.get(url, {
    pace = pacer, script = ok_script(), cancelled = function(): boolean return true end,
  })
  assert(got == nil and why == "interrupted", tostring(why))
  assert(Clock.monotonic_ns() - began < Clock.seconds(5), "the wait was not ended")
end

local function test_cancelled_during_a_pacer_wait_stops_waiting()
  local pacer = Http.pacer(Clock.seconds(30))
  assert(Http.get(url, { pace = pacer, script = ok_script() }))
  local began = Clock.monotonic_ns()
  local got, why = Http.get(url, {
    pace = pacer, script = ok_script(),
    cancelled = function(): boolean return Clock.monotonic_ns() - began > Clock.ms(300) end,
  })
  local took = Clock.monotonic_ns() - began
  assert(got == nil and why == "interrupted", tostring(why))
  assert(took >= Clock.ms(300) and took < Clock.seconds(5), tostring(took))
end

--- A request cut short while it waited did not start, so it leaves the
--- pacer's last start where it was. Cut short 500 ms in, a stamp would put
--- the next request at 1500 ms at least; left alone, it is due at 1000. The
--- bound between leaves a slow host's scheduling room on either side.
local function test_an_interrupted_wait_does_not_mark_a_start()
  local pacer = Http.pacer(Clock.seconds(1))
  local began = Clock.monotonic_ns()
  assert(Http.get(url, { pace = pacer, script = ok_script() }))
  local _, why = Http.get(url, {
    pace = pacer, script = ok_script(),
    cancelled = function(): boolean return Clock.monotonic_ns() - began > Clock.ms(500) end,
  })
  assert(why == "interrupted", tostring(why))
  assert(Http.get(url, { pace = pacer, script = ok_script() }))
  local took = Clock.monotonic_ns() - began
  assert(took >= Clock.ms(980), "the third request did not wait: " .. tostring(took))
  assert(took < Clock.ms(1400), "the interrupted wait marked a start: " .. tostring(took))
end

--- A request that fails to connect still counts as a start: the attempt
--- loaded the API, so the next request waits the interval after it.
local function test_a_refused_connection_counts_as_a_start()
  local pacer = Http.pacer(Clock.ms(300))
  local began = Clock.monotonic_ns()
  -- Nothing binds port 1, so the connection is refused.
  local response, why = Http.get("http://127.0.0.1:1/", { pace = pacer })
  assert(response == nil and why ~= "", tostring(why))
  assert(Http.get(url, { pace = pacer, script = ok_script() }))
  local took = Clock.monotonic_ns() - began
  assert(took >= Clock.ms(300), "the request after a refusal did not wait: " .. tostring(took))
  assert(took < Clock.seconds(5), tostring(took))
end

local function test_an_interval_of_zero_never_waits()
  local pacer = Http.pacer(0)
  assert(pacer.interval_ns == 0)
  local began = Clock.monotonic_ns()
  for _ = 1, 3 do assert(Http.get(url, { pace = pacer, script = ok_script() })) end
  assert(Clock.monotonic_ns() - began < Clock.seconds(5), "a pacer of 0 waited")
end

local function test_pacer_refuses_a_negative_interval()
  local err = raised(function() local _ = Http.pacer(-1) end)
  assert(err:find("http: pacer interval_ns must be an integer of at least 0", 1, true) ~= nil, err)
  -- Blamed on this file, the caller, not on a line of cosmic.http.
  assert(err:find("http_pace_test:", 1, true) ~= nil, err)
end

-- TODO: test a `pace` of a wrong Lua type (a string, a number) and a
-- fractional [`Http.pacer`] interval once a test may hold a mistyped value
-- without a cast, which build/ceilings.txt forbids adding: only a
-- class of the right shape, not made by Http.pacer, is built here.
local class Fake is Http.Pacer
  interval_ns: integer
end

--- A table that is no pacer raises naming the option, from each entry
--- point, with a first reply of 200 that would never ask for a wait.
local function test_a_pace_that_is_no_pacer_raises_naming_the_option(tmp: string)
  local fake: Fake = { interval_ns = 0 }
  local function opts(): Http.Options
    return { pace = fake, script = ok_script() }
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
    assert(err:find("http: opts.pace must be made by Http.pacer", 1, true) ~= nil, name .. ": " .. err)
    assert(err:find("http_pace_test:", 1, true) ~= nil, name .. ": " .. err)
  end
  assert(Fs.stat(tmp .. "/never") == nil)
end
