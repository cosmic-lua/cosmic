--- Worked examples for `cosmic.time`, shown by `cosmic docs` under the
--- symbol each one demonstrates and run by `cosmic test` like any other
--- test -- see doc/design.md's `examples` table.

local Store = require("cosmic.store")
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

--- A moment's UTC date, and a date read back as its midnight.
function Example.parse_date()
  local ns = assert(Time.parse_rfc3339("2026-09-25T05:22:21Z"))
  print(Time.format_date(ns))
  local midnight, why = Time.parse_date("2026-09-25")
  assert(midnight ~= nil, why)
  print(Time.format_rfc3339(midnight))
  assert(Time.format_rfc3339(midnight) == "2026-09-25T00:00:00Z")
  print(Time.parse_date("2026-02-29"))
end

--- An HTTP date written as IMF-fixdate, RFC 9110's three forms read
--- back as the same moment, and a date read whatever its day name says.
function Example.parse_http()
  local ns = assert(Time.parse_rfc3339("1994-11-06T08:49:37.25Z"))
  print(Time.format_http(ns))
  for _, text in ipairs({ "Sun, 06 Nov 1994 08:49:37 GMT", "Sunday, 06-Nov-94 08:49:37 GMT",
      "Sun Nov  6 08:49:37 1994" }) do
    local got = assert(Time.parse_http(text))
    print(Time.format_rfc3339(got))
    assert(got == ns - 250000000)
  end
  local saturday = assert(Time.parse_http("Mon, 26 Jul 1997 05:00:00 GMT"))
  print(Time.format_http(saturday))
  assert(Time.format_http(saturday) == "Sat, 26 Jul 1997 05:00:00 GMT")
end

--- A moment on New York's calendar, where clocks skip 02:30 on
--- 2026-03-08: refused by default, and read as a wall clock set forward
--- with "compatible".
function Example.zone()
  local ny = assert(Time.zone("America/New_York"))
  local ns = assert(Time.parse_rfc3339("2026-07-01T16:00:00Z"))
  local c = Time.civil(ns, ny)
  print(c.hour, c.offset, c.abbreviation, c.dst)
  assert(c.hour == 12 and c.offset == -14400 and c.abbreviation == "EDT" and c.dst)
  print(Time.format_rfc3339(ns, { zone = ny, zone_name = true }))
  local skipped: Time.Civil = { year = 2026, month = 3, day = 8, hour = 2, minute = 30, second = 0,
    nanosecond = 0 }
  print(Time.from_civil(skipped, ny))
  local later = assert(Time.from_civil(skipped, ny, { disambiguation = "compatible" }))
  print(Time.format_rfc3339(later, { zone = ny }))
  assert(Time.format_rfc3339(later, { zone = ny }) == "2026-03-08T03:30:00-04:00")
end

--- The host's own zone, as `TZ` and /etc/localtime name it.
function Example.local_zone()
  local here, why = Time.local_zone()
  assert(here ~= nil, why)
  print(here.name, Time.format_rfc3339(Time.now_ns(), { zone = here, digits = 0 }))
end

--- Sydney's rules as a POSIX TZ string: daylight saving time from the
--- first Sunday of October to the first of April, across the new year.
function Example.zone_from_posix()
  local sydney = assert(Time.zone_from_posix("AEST-10AEDT,M10.1.0,M4.1.0/3"))
  local ns = assert(Time.parse_rfc3339("2027-01-01T00:00:00+11:00"))
  local c = Time.civil(ns, sydney)
  print(c.abbreviation, c.offset)
  assert(c.abbreviation == "AEDT" and c.offset == 39600)
  local utc = Time.civil(ns, Time.UTC)
  print(utc.day, utc.hour, utc.abbreviation)
  assert(utc.day == 31 and utc.hour == 13 and utc.abbreviation == "UTC")
end

--- A zone from TZif bytes -- here the binary's own copy of Tokyo's,
--- which could as well have been read from a file.
function Example.zone_from_tzif()
  local tokyo = assert(Time.zone_from_tzif(assert(Store.zoneinfo("Asia/Tokyo")), "Asia/Tokyo"))
  print(Time.format_rfc3339(0, { zone = tokyo, zone_name = true }))
  assert(Time.format_rfc3339(0, { zone = tokyo, zone_name = true }) ==
    "1970-01-01T09:00:00+09:00[Asia/Tokyo]")
end

--- RFC 9557 text names the zone after the offset: the moment and the
--- zone come back, and an offset the zone did not have then is refused.
function Example.parse_rfc3339_zoned()
  local zoned = assert(Time.parse_rfc3339_zoned("2026-07-01T12:00:00-04:00[America/New_York]"))
  print(zoned.ns, zoned.zone.name)
  assert(zoned.zone.name == "America/New_York" and zoned.ns == 1782921600 * 1000000000)
  print(Time.parse_rfc3339_zoned("2026-07-01T12:00:00-05:00[America/New_York]"))
end

return Example
