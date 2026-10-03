--- The limits of [`cosmic.http`] in nanoseconds, which it hands the core
--- in the milliseconds and seconds it counts them in: a request to a
--- loopback listener that accepts and never answers ends at about the
--- time given, whatever the unit the core reads it in.

local Http = require("cosmic.http")
local Net = require("cosmic.net")
local Test = require("cosmic.test")
local Time = require("cosmic.time")

--- The listener answers nothing, on the worker's own loopback.
Test.needs{ network = { "127.0.0.1" } }

--- Whether `why` is curl's message for an expired limit: its
--- "Operation timed out after N", "Connection timeout after N ms" or
--- "Resolving timed out after N milliseconds", the phase the limit ended in.
--- TODO: match the kind rather than the wording, once cosmic.http reports
--- a timeout as one (CURLE_OPERATION_TIMEDOUT) rather than curl's message.
local function timed_out(why: string): boolean
  return why:find("^Operation timed out after %d+") ~= nil or
    why:find("^Connection timeout after %d+ ms") ~= nil or
    why:find("^%a+ timed out after %d+ milliseconds") ~= nil
end

--- A listener whose connections complete in its backlog and are never
--- read, and the URL of a request to it.
local function silent(): Net.Listener, string
  local server = assert(Net.listen(Net.tcp("127.0.0.1", 0)))
  return server, "http://127.0.0.1:" .. tostring(server.address.port) .. "/"
end

local function test_a_request_timeout_ends_at_about_the_time_given()
  local server <close>, url = silent()
  local began = Time.monotonic_ns()
  local response, why = Http.open(url, { timeout_ns = Time.ms(300) })
  local took = Time.monotonic_ns() - began
  assert(response == nil and timed_out(why), tostring(why))
  assert(took >= Time.ms(250) and took < Time.seconds(10), tostring(took // Time.ms(1)) .. " ms")
  assert(server ~= nil)
end

--- Counted in whole milliseconds and rounded up, a limit of one
--- nanosecond is a millisecond: never 0, which the core reads as none.
local function test_a_limit_under_a_millisecond_is_not_none()
  local server <close>, url = silent()
  local began = Time.monotonic_ns()
  local response, why = Http.open(url, { timeout_ns = 1 })
  assert(response == nil and timed_out(why), tostring(why))
  assert(Time.monotonic_ns() - began < Time.seconds(5), "ended long after 1 ms")
  began = Time.monotonic_ns()
  response, why = Http.open(url, { connect_timeout_ns = 1, timeout_ns = Time.ms(200) })
  assert(response == nil and timed_out(why), tostring(why))
  assert(Time.monotonic_ns() - began < Time.seconds(10))
  assert(server ~= nil)
end

--- A transfer that stays under the rate for `low_speed_ns` is ended: the
--- core counts it in seconds.
local function test_a_stalled_transfer_ends_after_the_low_speed_time()
  local server <close>, url = silent()
  local began = Time.monotonic_ns()
  local response, why = Http.open(url, { low_speed_bytes = 1000, low_speed_ns = Time.seconds(1) })
  local took = Time.monotonic_ns() - began
  assert(response == nil, "a stalled request was answered")
  assert(took >= Time.ms(500) and took < Time.seconds(20),
    tostring(took // Time.ms(1)) .. " ms: " .. tostring(why))
  assert(server ~= nil)
end
