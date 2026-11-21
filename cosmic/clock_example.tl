--- Worked examples for [`cosmic.clock`], shown by `cosmic docs` under the
--- symbol each one demonstrates and run by `cosmic test` like any other
--- test -- see doc/design.md's `examples` table.

local Clock = require("cosmic.clock")

local Example = {} -- checked: literal_needs_type

--- A millisecond's wait, measured on the monotonic clock, which never
--- jumps the way the wall clock can.
function Example.sleep_ns()
  local before = Clock.monotonic_ns()
  assert(Clock.sleep_ns(Clock.ms(1)))
  local waited = Clock.monotonic_ns() - before
  print(waited >= Clock.ms(1))
  assert(waited >= Clock.ms(1), tostring(waited))
end

--- A count of milliseconds as the nanoseconds every function here takes.
--- A fraction is fine while the span is a whole number of nanoseconds,
--- and one that is not is refused.
function Example.ms()
  print(Clock.ms(250), Clock.ms(0.5))
  assert(Clock.ms(250) == 250000000 and Clock.ms(0.5) == 500000)
  local ok, why = pcall(Clock.ms, 0.0000001)
  print(ok, why)
  assert(not ok)
end

--- Seconds as nanoseconds: a deadline five seconds from the monotonic
--- clock.
function Example.seconds()
  local deadline = Clock.monotonic_ns() + Clock.seconds(5)
  print(Clock.seconds(5), Clock.seconds(0.25))
  assert(Clock.seconds(5) == 5000000000 and Clock.seconds(0.25) == 250000000)
  assert(deadline > Clock.monotonic_ns())
end

--- Minutes as nanoseconds: ninety seconds, written two ways.
function Example.minutes()
  print(Clock.minutes(1.5), Clock.minutes(2))
  assert(Clock.minutes(1.5) == Clock.seconds(90) and Clock.minutes(2) == 120000000000)
  local ok, why = pcall(Clock.minutes, math.maxinteger)
  print(ok, why)
  assert(not ok)
end

--- Hours as nanoseconds: what a day is on a clock that never changes.
function Example.hours()
  print(Clock.hours(24), Clock.hours(0.5))
  assert(Clock.hours(24) == 86400 * 1000000000 and Clock.hours(0.5) == Clock.minutes(30))
end

--- A span as the count of a unit that covers it, for a call that takes
--- milliseconds: a nanosecond is one millisecond, never none.
function Example.ceil()
  local ms = Clock.ms(1)
  print(Clock.ceil(1, ms), Clock.ceil(Clock.ms(5), ms), Clock.ceil(Clock.ms(5) + 1, ms))
  assert(Clock.ceil(0, ms) == 0 and Clock.ceil(1, ms) == 1)
  assert(Clock.ceil(Clock.ms(5), ms) == 5 and Clock.ceil(Clock.ms(5) + 1, ms) == 6)
  assert(Clock.ceil(-1, ms) == 0 and Clock.ceil(Clock.seconds(2), Clock.seconds(1)) == 2)
  local ok, why = pcall(Clock.ceil, 1, 0)
  print(ok, why)
  assert(not ok)
end

--- Where a loop spends its time: each pass of the loop is a span, the
--- part of it inside is another, and the report lists the names by the
--- wall time they took, the most first.
function Example.span()
  local spans: Clock.Spans = {}
  for _ = 1, 3 do
    local _pass <close> = Clock.span(spans, "pass")
    do
      local _wait <close> = Clock.span(spans, "wait")
      assert(Clock.sleep_ns(Clock.ms(1)))
    end
  end
  for _, line in ipairs(Clock.report(spans)) do print(line) end
  assert(assert(spans["pass"]).count == 3 and assert(spans["wait"]).count == 3)
end

--- The totals of spans as lines, the name that took the most wall time
--- first.
function Example.report()
  local spans: Clock.Spans = {
    parse = { count = 12, wall_ns = Clock.ms(35), cpu_ns = Clock.ms(30) },
    write = { count = 1, wall_ns = Clock.ms(80), cpu_ns = Clock.ms(2) },
  }
  local lines = Clock.report(spans)
  for _, line in ipairs(lines) do print(line) end
  assert(lines[1] == "write  1 span, 80.000 ms wall, 2.000 ms cpu")
  assert(lines[2] == "parse  12 spans, 35.000 ms wall, 30.000 ms cpu")
end

return Example -- checked: export_not_declared
