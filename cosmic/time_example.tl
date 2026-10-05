--- Worked examples for [`cosmic.time`], shown by `cosmic docs` under the
--- symbol each one demonstrates and run by `cosmic test` like any other
--- test -- see doc/design.md's `examples` table.

local Store = require("cosmic.store")
local Time = require("cosmic.time")
local Test = require("cosmic.test")

--- The host's own local zone.
Test.policy{
  grants = { { path = "/etc/localtime", letters = "r" } },
  env = { "TZ" },
}

local Example = {}

--- A duration as people write it: a calendar part (years, months, days)
--- and an exact part in nanoseconds, with one sign for the whole. Text
--- that is not one is refused with why.
function Example.parse_duration()
  local d = assert(Time.parse_duration("1y2mo3d4h5m6.5s"))
  print(d.years, d.months, d.days, d.ns)
  assert(d.years == 1 and d.months == 2 and d.days == 3)
  assert(d.ns == Time.hours(4) + Time.minutes(5) + Time.seconds(6.5))
  local back = Time.parse_duration("-90m")
  assert(back ~= nil and back.ns == -Time.minutes(90))
  local none, why = Time.parse_duration("5 minutes")
  assert(none == nil)
  print(why)
end

--- What a person typed as a moment: local time on a zone's calendar, and
--- how a time its clocks repeat is read -- refused by default, or the
--- earlier or the later of its two moments as asked.
function Example.from_civil()
  local tokyo = assert(Time.zone("Asia/Tokyo"))
  local midnight = assert(Time.parse_rfc3339("2026-09-25T00:00:00Z"))
  local nine: Time.Civil = { year = 2026, month = 9, day = 25, hour = 9, minute = 0, second = 0,
    ns = 0 }
  assert(Time.from_civil(nine, tokyo) == midnight, "09:00 in Tokyo is midnight UTC")
  local ny = assert(Time.zone("America/New_York"))
  local twice: Time.Civil = { year = 2026, month = 11, day = 1, hour = 1, minute = 30, second = 0,
    ns = 0 }
  print(Time.from_civil(twice, ny))
  for _, how in ipairs({ "earlier", "later" } as {Time.Disambiguation}) do
    local ns = assert(Time.from_civil(twice, ny, { disambiguation = how }))
    print(how, Time.format_rfc3339(ns, ny))
  end
  local earlier = assert(Time.from_civil(twice, ny, { disambiguation = "earlier" }))
  assert(Time.format_rfc3339(earlier, ny) == "2026-11-01T01:30:00-04:00")
end

--- A moment named on the UTC calendar, and written as RFC 3339 text.
function Example.civil()
  local ns = 951782400 * 1000000000 + 250000000
  local c = Time.civil(ns)
  print(c.year, c.month, c.day, c.weekday, c.yday)
  assert(c.year == 2000 and c.month == 2 and c.day == 29 and c.weekday == 2 and c.yday == 60)
  print(Time.format_rfc3339(ns))
  print(Time.format_rfc3339(ns, nil, { digits = 0 }))
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
--- month's last, and a duration's exact part, here an hour and a half, is
--- added to the moment the calendar part reaches.
function Example.add_calendar()
  local jan31 = assert(Time.parse_rfc3339("2024-01-31T09:00:00Z"))
  print(Time.add_calendar(jan31, { months = 1 }))
  local feb = assert(Time.add_calendar(jan31, { months = 1, ns = Time.minutes(90) }, nil,
    { overflow = "clamp" }))
  print(Time.format_rfc3339(feb))
  assert(Time.format_rfc3339(feb) == "2024-02-29T10:30:00Z")
end

--- The whole years, months and days from one moment to another, and the
--- hours, minutes and seconds left over, as a duration that adds back
--- to the second moment. The months count as Java's do: January 31 to
--- February 29 is none.
function Example.between()
  local from = assert(Time.parse_rfc3339("2024-01-31T09:00:00Z"))
  local to = assert(Time.parse_rfc3339("2026-03-15T10:30:00Z"))
  local span = assert(Time.between(from, to))
  print(Time.format_duration(span))
  assert(span.years == 2 and span.months == 1 and span.days == 15 and span.ns == Time.minutes(90))
  assert(Time.add_calendar(from, span, nil, { overflow = "clamp" }) == to)
  local leap = assert(Time.parse_rfc3339("2024-02-29T09:00:00Z"))
  assert(assert(Time.between(from, leap)).months == 0)
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
  print(Time.format_rfc3339(ns, ny, { zone_name = true }))
  local skipped: Time.Civil = { year = 2026, month = 3, day = 8, hour = 2, minute = 30, second = 0,
    ns = 0 }
  print(Time.from_civil(skipped, ny))
  local later = assert(Time.from_civil(skipped, ny, { disambiguation = "compatible" }))
  print(Time.format_rfc3339(later, ny))
  assert(Time.format_rfc3339(later, ny) == "2026-03-08T03:30:00-04:00")
end

--- The host's own zone: the carried one `TZ`, /etc/localtime or /etc/timezone names.
function Example.local_zone()
  local here, why = Time.local_zone()
  assert(here ~= nil, why)
  print(here.name, Time.format_rfc3339(Time.now_ns(), here, { digits = 0 }))
  -- A TZ string with its own rules, Sydney's: daylight saving time from
  -- the first Sunday of October to the first of April, across the new year.
  local sydney = assert(Time.local_zone({ tz = "AEST-10AEDT,M10.1.0,M4.1.0/3" }))
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
  print(Time.format_rfc3339(0, tokyo, { zone_name = true }))
  assert(Time.format_rfc3339(0, tokyo, { zone_name = true }) ==
      "1970-01-01T09:00:00+09:00[Asia/Tokyo]")
end

--- RFC 9557 text names the zone after the offset: the moment and the
--- zone come back, and an offset the zone did not have then is refused.
function Example.parse_rfc3339_zoned()
  local zoned = assert(Time.parse_rfc3339_zoned("2026-07-01T12:00:00-04:00[America/New_York]"))
  print(zoned.ns, zoned.zone.name)
  assert(zoned.zone.name == "America/New_York" and zoned.ns == 1782921600 * 1000000000)
  print(Time.parse_rfc3339_zoned("2026-07-01T12:00:00-05:00[America/New_York]"))
  local plain = assert(Time.parse_rfc3339_zoned("2026-07-01T21:30:00+05:30"))
  print(plain.zone.name)
  assert(plain.zone.name == "+05:30" and plain.ns == zoned.ns)
end

return Example
