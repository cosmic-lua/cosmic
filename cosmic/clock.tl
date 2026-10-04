--- Clocks, sleeping, and spans of exact time, every one in nanoseconds,
--- so nothing above this module carries a unit it has to remember. It
--- needs nothing but [`cosmic.sys`]: a module that only reads a clock, waits
--- or builds a timeout takes this one rather than [`cosmic.time`], whose
--- calendar and time zone code it would otherwise depend on.
---
--- A span is an integer of nanoseconds, which [`ms`], [`seconds`],
--- [`minutes`] and [`hours`] make from a count (`Clock.seconds(5)`) and
--- [`ceil`] counts back in a coarser unit. [`cosmic.time`] answers each of
--- these under the same name, and names a moment and a span of the calendar.

local sys = require("cosmic.sys")

local record Clock
end

local NS <const> = 1000000000

--- The wall clock in nanoseconds, which can step backwards when the host
--- adjusts it. Unlike os.time, it is not calendar seconds:
--- [`cosmic.time`]'s `civil` and `format_rfc3339` name it on the UTC
--- calendar. Raises when the clock cannot be read, which a host that runs
--- cosmic at all never refuses.
function Clock.now_ns(): integer
  local reading, trouble = sys.clock_gettime(sys.CLOCK_REALTIME)
  if reading == nil then
    error("clock: clock_gettime(CLOCK_REALTIME): " .. trouble, 2)
  end
  return reading
end

--- A clock that only moves forward, for measuring elapsed duration in
--- nanoseconds. Use it for timing in place of os.clock; it measures wall
--- duration rather than process CPU time. Raises when the clock cannot
--- be read, which a host that runs cosmic at all never refuses.
function Clock.monotonic_ns(): integer
  local reading, trouble = sys.clock_gettime(sys.CLOCK_MONOTONIC)
  if reading == nil then
    error("clock: clock_gettime(CLOCK_MONOTONIC): " .. trouble, 2)
  end
  return reading
end

--- Sleeps for `nanoseconds`, as `sleep` or `nanosleep` does, resuming
--- the wait when a signal interrupts it, so the whole time passes.
--- Answers `true` and "" once it has, or `false` and why when the
--- system refuses the sleep. Raises when `nanoseconds` is negative.
function Clock.sleep_ns(nanoseconds: integer): boolean, string
  local ok, trouble = sys.nanosleep(nanoseconds)
  if not ok then
    return false, trouble
  end
  return true, ""
end

--- `n` units of `unit_ns` nanoseconds each, for the constructors below;
--- raises, blaming their caller, for a count that is no number or a span
--- that is not a whole number of nanoseconds an integer holds.
local function span(n: number, unit_ns: integer, name: string): integer
  local kind = math.type(n)
  if kind == "integer" then
    local count = math.tointeger(n)
    local most = math.maxinteger // unit_ns
    if count > most or count < -most then
      error(("clock: %s(%d) is outside what an integer of nanoseconds holds"):format(name, count), 3)
    end
    return count * unit_ns
  elseif kind == "float" then
    -- A count like 1.005 has no exact binary form, so its product is
    -- only near a whole number: within a few units in the last place.
    local scaled = n * unit_ns
    local whole = math.floor(scaled + 0.5)
    if math.type(whole) ~= "integer" or math.abs(scaled - whole) > math.abs(scaled) * 2 ^ -50 then
      error(("clock: %s(%s) is not a whole number of nanoseconds an integer holds"):format(name,
        tostring(n)), 3)
    end
    return whole
  end
  error(("clock: %s takes a number, not %s"):format(name, type(n)), 3)
end

--- `n` milliseconds as nanoseconds: `Clock.ms(250)` is 250000000. A float
--- is as good as an integer when the span is a whole number of
--- nanoseconds, to within the rounding of the product (`Clock.ms(0.5)` is
--- 500000, and `Clock.seconds(1.005)` is 1005000000). Raises for anything
--- else: a value that is no number, a span with a fraction of a
--- nanosecond, or one outside what an integer holds.
function Clock.ms(n: number): integer
  return span(n, 1000000, "Clock.ms")
end

--- A timeout or a deadline's length: `Clock.seconds(5)` is 5000000000
--- nanoseconds. A count is held to what [`ms`] holds one to.
function Clock.seconds(n: number): integer
  return span(n, NS, "Clock.seconds")
end

--- Ninety seconds as a count of minutes: `Clock.minutes(1.5)` is
--- 90000000000 nanoseconds. A count is held to what [`ms`] holds one to.
function Clock.minutes(n: number): integer
  return span(n, 60 * NS, "Clock.minutes")
end

--- Hours as nanoseconds: `Clock.hours(1)` is 3600000000000. A count is
--- held to what [`ms`] holds one to.
function Clock.hours(n: number): integer
  return span(n, 3600 * NS, "Clock.hours")
end

--- The count of `unit` nanoseconds that covers `ns`, rounded up, for a
--- raw call that takes its span as a count of one unit: `Clock.ceil(ns,
--- Clock.ms(1))` is the milliseconds a poll waits, and 1 for a single
--- nanosecond, where rounding down would answer 0, no wait at all.
--- Raises for a `unit` below 1 or an argument that is no integer.
function Clock.ceil(ns: integer, unit: integer): integer
  if math.type(ns) ~= "integer" then error("clock: ns must be an integer", 2) end
  if math.type(unit) ~= "integer" or unit < 1 then
    error("clock: unit must be an integer above 0", 2)
  end
  return ns // unit + (ns % unit ~= 0 and 1 or 0)
end

return Clock
