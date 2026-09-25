--- Clocks, sleeping, and the UTC calendar. Every reading is in
--- nanoseconds, so nothing above this module carries a unit it has to
--- remember. A moment is an integer of nanoseconds since
--- 1970-01-01T00:00:00Z without leap seconds, so the calendar spans
--- what 64 bits hold: 1677-09-21T00:12:43.145224192Z through
--- 2262-04-11T23:47:16.854775807Z, on the proleptic Gregorian calendar.

local sys = require("cosmic.sys")

local record Time
  --- A moment as the UTC calendar names it.
  record Civil
    --- 1677 through 2262.
    year: integer
    --- 1 (January) through 12.
    month: integer
    --- 1 through the month's last day.
    day: integer
    --- 0 through 23.
    hour: integer
    --- 0 through 59.
    minute: integer
    --- 0 through 59: there are no leap seconds.
    second: integer
    --- 0 through 999999999.
    nanosecond: integer
    --- ISO 8601's: 1 (Monday) through 7 (Sunday). `from_civil` ignores it.
    weekday: integer
    --- The day of the year, 1 through 366. `from_civil` ignores it.
    yday: integer
  end

  record FormatOptions
    --- Digits of fraction to write, 0 through 9, cut toward the past; by
    --- default as many as the nanoseconds need, none when they are zero.
    digits: integer
  end
end

local NS <const> = 1000000000
local DAY <const> = 86400

--- The first and last moments an integer holds, as whole seconds and the
--- nanoseconds past them.
local MIN_S <const> = math.mininteger // NS
local MIN_NS <const> = math.mininteger % NS
local MAX_S <const> = math.maxinteger // NS
local MAX_NS <const> = math.maxinteger % NS
local RANGE <const> = "outside 1677-09-21T00:12:43.145224192Z through " ..
  "2262-04-11T23:47:16.854775807Z, what an integer of nanoseconds holds"

--- Days since 1970-01-01 of a proleptic Gregorian date: Howard Hinnant's
--- `days_from_civil`, with floor division.
local function days_from_civil(y: integer, m: integer, d: integer): integer
  y = m <= 2 and y - 1 or y
  local era = y // 400
  local yoe = y - era * 400
  local doy = (153 * (m > 2 and m - 3 or m + 9) + 2) // 5 + d - 1
  local doe = yoe * 365 + yoe // 4 - yoe // 100 + doy
  return era * 146097 + doe - 719468
end

--- The inverse of `days_from_civil`: Hinnant's `civil_from_days`.
local function civil_from_days(z: integer): Time.Civil
  z = z + 719468
  local era = z // 146097
  local doe = z - era * 146097
  local yoe = (doe - doe // 1460 + doe // 36524 - doe // 146096) // 365
  local doy = doe - (365 * yoe + yoe // 4 - yoe // 100)
  local mp = (5 * doy + 2) // 153
  local month = mp < 10 and mp + 3 or mp - 9
  return {
    year = yoe + era * 400 + (month <= 2 and 1 or 0),
    month = month,
    day = doy - (153 * mp + 2) // 5 + 1,
  }
end

local function leap(y: integer): boolean
  return y % 4 == 0 and (y % 100 ~= 0 or y % 400 == 0)
end

local MONTH_DAYS <const> = { 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 }

local function month_days(y: integer, m: integer): integer
  return m == 2 and leap(y) and 29 or MONTH_DAYS[m]
end

--- Why `value`, the field `name`, is not an integer from `lo` through
--- `hi`, or nil when it is.
local function outside(name: string, value: integer, lo: integer, hi: integer): string
  if math.type(value) ~= "integer" then
    return ("%s is not an integer: %s %s"):format(name, math.type(value) or type(value),
      tostring(value))
  end
  if value < lo or value > hi then
    return ("%s %d is not %d through %d"):format(name, value, lo, hi)
  end
  return nil
end

--- The nanoseconds of a calendar moment `offset` seconds east of UTC,
--- or nil and which field is wrong, or that the moment is outside what
--- an integer holds.
local function moment(c: Time.Civil, offset: integer): integer | nil, string
  local why = outside("year", c.year, math.mininteger, math.maxinteger)
    or outside("month", c.month, 1, 12)
  if why ~= nil then return nil, why end
  -- A year either side of the range, so an offset can reach its edges.
  if c.year < 1676 or c.year > 2263 then return nil, RANGE end
  why = outside("day", c.day, 1, month_days(c.year, c.month))
    or outside("hour", c.hour, 0, 23)
    or outside("minute", c.minute, 0, 59)
    or outside("second", c.second, 0, 59)
    or outside("nanosecond", c.nanosecond, 0, NS - 1)
  if why ~= nil then return nil, why end
  local s = days_from_civil(c.year, c.month, c.day) * DAY
    + c.hour * 3600 + c.minute * 60 + c.second - offset
  local n = c.nanosecond
  if s < MIN_S or (s == MIN_S and n < MIN_NS) or s > MAX_S or (s == MAX_S and n > MAX_NS) then
    return nil, RANGE
  end
  -- At MIN_S the product wraps past the bottom and the sum wraps back:
  -- Lua's integers are two's complement.
  return s * NS + n, ""
end

--- `ns` on the UTC calendar. Every integer is a moment in range.
function Time.civil(ns: integer): Time.Civil
  local s, n = ns // NS, ns % NS
  -- TODO: UTC only. Local civil time, what os.date answers without "!",
  -- waits on a zoneinfo reader (TZif, RFC 8536, over /usr/share/zoneinfo
  -- and TZ) or a tz database carried in the binary.
  local days, into = s // DAY, s % DAY
  local c = civil_from_days(days)
  c.hour, c.minute, c.second = into // 3600, into % 3600 // 60, into % 60
  c.nanosecond = n
  c.weekday = (days + 3) % 7 + 1
  c.yday = days - days_from_civil(c.year, 1, 1) + 1
  return c
end

--- The nanoseconds `c` names on the UTC calendar, or nil and which
--- field is out of its range (month 13, February 30, hour 24) or not an
--- integer (a float such as 2026.0 included), or that the moment is
--- outside what an integer holds. Nothing is normalized: day 32 is
--- refused, not carried into the next month.
function Time.from_civil(c: Time.Civil): integer | nil, string
  return moment(c, 0)
end

--- `ns` as RFC 3339 text in UTC, `2026-09-25T04:09:21Z`, with a fraction
--- as `opts.digits` says (`2026-09-25T04:09:21.5Z` by default). A cut
--- in the range's first second names a moment before it, which
--- `parse_rfc3339` refuses. Raises when `digits` is not 0 through 9.
function Time.format_rfc3339(ns: integer, opts?: Time.FormatOptions): string
  local digits = opts ~= nil and opts.digits or nil
  if digits ~= nil and outside("digits", digits, 0, 9) ~= nil then
    error("time: " .. outside("digits", digits, 0, 9), 2)
  end
  local c = Time.civil(ns)
  local fraction = ("%09d"):format(c.nanosecond)
  if digits == nil then
    fraction = fraction:gsub("0+$", "")
  else
    fraction = fraction:sub(1, digits)
  end
  return ("%04d-%02d-%02dT%02d:%02d:%02d%s%sZ"):format(c.year, c.month, c.day,
    c.hour, c.minute, c.second, fraction ~= "" and "." or "", fraction)
end

--- The integer the `count` ASCII digits at `at` in `text` spell, or nil.
local function digits_at(text: string, at: integer, count: integer): integer
  local n = 0
  for i = at, at + count - 1 do
    local b = text:byte(i)
    if b == nil or b < 48 or b > 57 then return nil end
    n = n * 10 + (b - 48)
  end
  return n
end

--- The nanoseconds an RFC 3339 timestamp names, as
--- `2026-09-25T04:09:21.5+05:30`: `T` or `t` between date and time, one
--- to nine digits of fraction, and `Z`, `z` or a numeric offset, where
--- `-00:00` is UTC too. Nil and why for anything else, a leap second, or
--- a moment outside the range.
function Time.parse_rfc3339(text: string): integer | nil, string
  local function field(at: integer, count: integer, name: string): integer | nil, string
    local n = digits_at(text, at, count)
    if n == nil then
      return nil, ("%s: expected %d digits at byte %d"):format(name, count, at)
    end
    return n, ""
  end
  local function byte_is(at: integer, want: string, name: string): string
    local got = text:sub(at, at)
    if got ~= want and not (want == "T" and got == "t") then
      return ("expected %q %s at byte %d"):format(want, name, at)
    end
    return nil
  end
  local c: Time.Civil = {}
  local why: string
  c.year, why = field(1, 4, "year")
  if c.year == nil then return nil, why end
  why = byte_is(5, "-", "after the year")
  if why ~= nil then return nil, why end
  c.month, why = field(6, 2, "month")
  if c.month == nil then return nil, why end
  why = byte_is(8, "-", "after the month")
  if why ~= nil then return nil, why end
  c.day, why = field(9, 2, "day")
  if c.day == nil then return nil, why end
  why = byte_is(11, "T", "between the date and the time")
  if why ~= nil then return nil, why end
  c.hour, why = field(12, 2, "hour")
  if c.hour == nil then return nil, why end
  why = byte_is(14, ":", "after the hour")
  if why ~= nil then return nil, why end
  c.minute, why = field(15, 2, "minute")
  if c.minute == nil then return nil, why end
  why = byte_is(17, ":", "after the minute")
  if why ~= nil then return nil, why end
  c.second, why = field(18, 2, "second")
  if c.second == nil then return nil, why end
  if c.second == 60 then return nil, "second 60 is not 0 through 59: cosmic time has no leap seconds" end
  c.nanosecond = 0
  local at = 20
  if text:sub(at, at) == "." then
    local first = at + 1
    at = first
    while digits_at(text, at, 1) ~= nil do at = at + 1 end
    local count = at - first
    if count == 0 or count > 9 then
      return nil, ("fraction at byte %d: expected 1 to 9 digits, not %d"):format(first, count)
    end
    c.nanosecond = digits_at(text, first, count)
    for _ = count + 1, 9 do c.nanosecond = c.nanosecond * 10 end
  end
  local offset = 0
  local zone = text:sub(at, at)
  if zone == "Z" or zone == "z" then
    at = at + 1
  elseif zone == "+" or zone == "-" then
    local hours, minutes: integer, integer
    hours, why = field(at + 1, 2, "offset hour")
    if hours == nil then return nil, why end
    why = byte_is(at + 3, ":", "in the offset")
    if why ~= nil then return nil, why end
    minutes, why = field(at + 4, 2, "offset minute")
    if minutes == nil then return nil, why end
    why = outside("offset hour", hours, 0, 23) or outside("offset minute", minutes, 0, 59)
    if why ~= nil then return nil, why end
    offset = (hours * 60 + minutes) * 60
    if zone == "-" then offset = -offset end
    at = at + 6
  else
    return nil, ("expected \"Z\" or an offset at byte %d"):format(at)
  end
  if at <= #text then
    return nil, ("unexpected text at byte %d"):format(at)
  end
  return moment(c, offset)
end

--- The wall clock in nanoseconds, which can step backwards when the host
--- adjusts it. Unlike os.time, it is not calendar seconds: `civil` and
--- `format_rfc3339` name it on the UTC calendar. Raises when the clock
--- cannot be read, which a host that runs cosmic at all never refuses.
function Time.now_ns(): integer
  local reading, trouble = sys.clock_gettime(sys.CLOCK_REALTIME)
  if reading == nil then
    error("clock_gettime(CLOCK_REALTIME): " .. trouble, 2)
  end
  return reading
end

--- A clock that only moves forward, for measuring elapsed duration in
--- nanoseconds. Use it for timing in place of os.clock; it measures wall
--- duration rather than process CPU time. Raises when the clock cannot
--- be read, which a host that runs cosmic at all never refuses.
function Time.monotonic_ns(): integer
  local reading, trouble = sys.clock_gettime(sys.CLOCK_MONOTONIC)
  if reading == nil then
    error("clock_gettime(CLOCK_MONOTONIC): " .. trouble, 2)
  end
  return reading
end

--- Sleeps, as `sleep` or `nanosleep` does, resuming the wait when a
--- signal interrupts it.
function Time.sleep_ns(nanoseconds: integer): boolean, string
  local ok, trouble = sys.nanosleep(nanoseconds)
  if not ok then
    return false, trouble
  end
  return true, ""
end

return Time
