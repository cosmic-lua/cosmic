--- Worked examples for `cosmic.time`, shown by `cosmic docs` under the
--- symbol each one demonstrates and run by `cosmic test` like any other
--- test -- see doc/design.md's `examples` table.

local Time = require("cosmic.time")

local Example = {}

--- A millisecond's wait, measured on the monotonic clock, which never
--- jumps the way the wall clock can.
function Example.sleep_ns()
  local before = Time.monotonic_ns()
  assert(Time.sleep_ns(1000000))
  local waited = Time.monotonic_ns() - before
  print(waited >= 1000000)
  assert(waited >= 1000000, tostring(waited))
end

--- A moment named on the UTC calendar, and written as RFC 3339 text.
function Example.civil()
  local ns = 951782400 * 1000000000 + 250000000
  local c = Time.civil(ns)
  print(c.year, c.month, c.day, c.weekday, c.yday)
  assert(c.year == 2000 and c.month == 2 and c.day == 29 and c.weekday == 2 and c.yday == 60)
  print(Time.format_rfc3339(ns))
  print(Time.format_rfc3339(ns, { digits = 0 }))
end

--- A timestamp with an offset read back as nanoseconds, and a calendar
--- date refused for a day its month does not have.
function Example.parse_rfc3339()
  local ns, why = Time.parse_rfc3339("2026-09-25T09:39:21+05:30")
  assert(ns ~= nil, why)
  print(Time.format_rfc3339(ns))
  local c = Time.civil(ns)
  c.day = 31
  local refused, reason = Time.from_civil(c)
  print(refused, reason)
  assert(refused == nil and reason ~= "")
end

--- A month past January 31 names no day unless asked to take the
--- month's last; the whole months between two dates count the same way.
function Example.add_calendar()
  local jan31 = assert(Time.parse_rfc3339("2024-01-31T09:00:00Z"))
  print(Time.add_calendar(jan31, { months = 1 }))
  local feb = assert(Time.add_calendar(jan31, { months = 1 }, { overflow = "clamp" }))
  print(Time.format_rfc3339(feb))
  assert(Time.format_rfc3339(feb) == "2024-02-29T09:00:00Z")
  print(Time.days_between(jan31, feb), Time.months_between(jan31, feb))
  assert(Time.days_between(jan31, feb) == 29 and Time.months_between(jan31, feb) == 0)
end

return Example
