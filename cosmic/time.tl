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

  --- A calendar amount, for `add_calendar`: each field may be negative,
  --- and a missing one is zero.
  record Change
    years: integer
    months: integer
    days: integer
  end

  --- What `add_calendar` does with a day its month does not have, as
  --- January 31 plus a month: "reject" refuses it, "clamp" takes the
  --- month's last day.
  enum Overflow
    "reject"
    "clamp"
  end

  record AddOptions
    --- "reject" when absent.
    overflow: Time.Overflow
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

--- `ns` moved by a calendar amount on the UTC calendar: the years and
--- months first, keeping the day and the time of day, then the days.
--- Nil and why when the day the years and months reach is past its
--- month's end and `opts.overflow` is not "clamp", when a field is not
--- an integer or is past its bound (which only keeps the arithmetic
--- from wrapping), or when the result is outside the range. Raises for
--- an `overflow` that is neither. An exact duration needs no call: add
--- its nanoseconds.
function Time.add_calendar(ns: integer, change: Time.Change,
    opts?: Time.AddOptions): integer | nil, string
  local years, months, days = change.years or 0, change.months or 0, change.days or 0
  local why = outside("years", years, -10000, 10000) or outside("months", months, -120000, 120000)
    or outside("days", days, -3650000, 3650000)
  if why ~= nil then return nil, why end
  local overflow = opts ~= nil and opts.overflow or "reject"
  if overflow ~= "reject" and overflow ~= "clamp" then
    error("time: overflow is \"reject\" or \"clamp\", not " .. tostring(overflow), 2)
  end
  -- TODO: UTC only. In a zone, a day is not always 86400 seconds; adding
  -- days there keeps the wall-clock time across a DST change, once
  -- cosmic.time reads zones.
  local c = Time.civil(ns)
  local index = c.year * 12 + (c.month - 1) + years * 12 + months
  c.year, c.month = index // 12, index % 12 + 1
  local last = month_days(c.year, c.month)
  if c.day > last then
    if overflow ~= "clamp" then
      return nil, ("%04d-%02d has no day %d; overflow \"clamp\" takes its last"):format(
        c.year, c.month, c.day)
    end
    c.day = last
  end
  local moved = civil_from_days(days_from_civil(c.year, c.month, c.day) + days)
  c.year, c.month, c.day = moved.year, moved.month, moved.day
  return moment(c, 0)
end

--- Whole days from `from`'s UTC date to `to`'s, negative when `to`'s is
--- earlier; the time of day does not count.
function Time.days_between(from: integer, to: integer): integer
  return to // NS // DAY - from // NS // DAY
end

--- Whole calendar months from `from` to `to`, negative when `to` is
--- earlier, as Java's `ChronoUnit.MONTHS.between` counts them on the
--- UTC calendar: `to`'s date steps a day toward `from`'s when its time
--- of day has not reached `from`'s, then a month counts once the day of
--- the month does. January 31 to February 29 is 0; to March 31, 2.
--- Whole years are this divided by 12, truncated toward zero.
function Time.months_between(from: integer, to: integer): integer
  local a_day, b_day = from // NS // DAY, to // NS // DAY
  local a_time, b_time = from % (DAY * NS), to % (DAY * NS)
  if b_day > a_day and b_time < a_time then
    b_day = b_day - 1
  elseif b_day < a_day and b_time > a_time then
    b_day = b_day + 1
  end
  local a, b = civil_from_days(a_day), civil_from_days(b_day)
  local packed = ((b.year * 12 + b.month) * 32 + b.day) - ((a.year * 12 + a.month) * 32 + a.day)
  -- Toward zero, as Java's integer division.
  return packed >= 0 and packed // 32 or -((-packed) // 32)
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

--- The integer the `count` digits at `at` in `text` spell, or nil and
--- that the field `name` is not there.
local function field(text: string, at: integer, count: integer, name: string): integer | nil, string
  local n = digits_at(text, at, count)
  if n == nil then
    return nil, ("%s: expected %d digits at byte %d"):format(name, count, at)
  end
  return n, ""
end

--- Nil when `text` holds `want` at `at`, where `t` stands for `T`, or
--- why not.
local function byte_is(text: string, at: integer, want: string, name: string): string
  local got = text:sub(at, at + #want - 1)
  if got ~= want and not (want == "T" and got == "t") then
    return ("expected %q %s at byte %d"):format(want, name, at)
  end
  return nil
end

--- The index in `names` of the name at `at` in `text`, or nil and that
--- `what` is not there.
local function name_at(text: string, at: integer, names: {string}, what: string): integer | nil, string
  for i, name in ipairs(names) do
    if text:sub(at, at + #name - 1) == name then return i, "" end
  end
  return nil, ("expected %s at byte %d"):format(what, at)
end

--- `YYYY-MM-DD` at the start of `text` into `c`, or why not.
local function date_into(text: string, c: Time.Civil): string
  local why: string
  c.year, why = field(text, 1, 4, "year")
  if c.year == nil then return why end
  why = byte_is(text, 5, "-", "after the year")
  if why ~= nil then return why end
  c.month, why = field(text, 6, 2, "month")
  if c.month == nil then return why end
  why = byte_is(text, 8, "-", "after the month")
  if why ~= nil then return why end
  c.day, why = field(text, 9, 2, "day")
  if c.day == nil then return why end
  return nil
end

--- `hh:mm:ss` at `at` in `text` into `c`, or why not.
local function clock_into(text: string, at: integer, c: Time.Civil): string
  local why: string
  c.hour, why = field(text, at, 2, "hour")
  if c.hour == nil then return why end
  why = byte_is(text, at + 2, ":", "after the hour")
  if why ~= nil then return why end
  c.minute, why = field(text, at + 3, 2, "minute")
  if c.minute == nil then return why end
  why = byte_is(text, at + 5, ":", "after the minute")
  if why ~= nil then return why end
  c.second, why = field(text, at + 6, 2, "second")
  if c.second == nil then return why end
  if c.second == 60 then return "second 60 is not 0 through 59: cosmic time has no leap seconds" end
  return nil
end

--- The nanoseconds an RFC 3339 timestamp names, as
--- `2026-09-25T04:09:21.5+05:30`: `T` or `t` between date and time, one
--- to nine digits of fraction, and `Z`, `z` or a numeric offset, where
--- `-00:00` is UTC too. Nil and why for anything else, a leap second, or
--- a moment outside the range.
function Time.parse_rfc3339(text: string): integer | nil, string
  local c: Time.Civil = {}
  local why = date_into(text, c)
  if why ~= nil then return nil, why end
  why = byte_is(text, 11, "T", "between the date and the time")
  if why ~= nil then return nil, why end
  why = clock_into(text, 12, c)
  if why ~= nil then return nil, why end
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
    hours, why = field(text, at + 1, 2, "offset hour")
    if hours == nil then return nil, why end
    why = byte_is(text, at + 3, ":", "in the offset")
    if why ~= nil then return nil, why end
    minutes, why = field(text, at + 4, 2, "offset minute")
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

--- `ns`'s UTC date, `2026-09-25`.
function Time.format_date(ns: integer): string
  -- TODO: UTC only. A zone parameter names the date in a zone, once
  -- cosmic.time reads zones.
  local c = Time.civil(ns)
  return ("%04d-%02d-%02d"):format(c.year, c.month, c.day)
end

--- The nanoseconds of 00:00:00Z on the date `YYYY-MM-DD` names, as
--- `2026-09-25`. Nil and why for anything else, a day its month does
--- not have, or a date whose midnight is outside the range, as the
--- range's first, 1677-09-21.
function Time.parse_date(text: string): integer | nil, string
  -- TODO: UTC only. A zone parameter takes the midnight in a zone, once
  -- cosmic.time reads zones.
  local c: Time.Civil = { hour = 0, minute = 0, second = 0, nanosecond = 0 }
  local why = date_into(text, c)
  if why ~= nil then return nil, why end
  if #text > 10 then return nil, "unexpected text at byte 11" end
  return moment(c, 0)
end

local SHORT_DAYS <const> = { "Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun" }
local LONG_DAYS <const> = { "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday",
  "Sunday" }
local MONTHS <const> = { "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct",
  "Nov", "Dec" }

--- `ns` as an HTTP date, RFC 9110's IMF-fixdate: `Fri, 25 Sep 2026
--- 05:22:21 GMT`, the fraction of a second cut toward the past. A cut
--- in the range's first second names a moment before it, which
--- `parse_http` refuses.
function Time.format_http(ns: integer): string
  local c = Time.civil(ns)
  return ("%s, %02d %s %04d %02d:%02d:%02d GMT"):format(SHORT_DAYS[c.weekday], c.day,
    MONTHS[c.month], c.year, c.hour, c.minute, c.second)
end

--- The nanoseconds an HTTP date names, in any of RFC 9110's three forms
--- (section 5.6.7): IMF-fixdate, `Sun, 06 Nov 1994 08:49:37 GMT`; the
--- obsolete RFC 850 form, `Sunday, 06-Nov-94 08:49:37 GMT`; and
--- asctime's, `Sun Nov  6 08:49:37 1994`, whose day is two digits or
--- a space and one. Names are case-sensitive, as the grammar has them.
--- The day name must be one of the seven, in its form's length, but
--- need not be the date's: `Mon, 26 Jul 1997 05:00:00 GMT`, a Saturday,
--- is read as its date says, as recipients commonly do. An RFC 850 year
--- of 69 through 99 is 1969 through 1999 and one of 00 through 68 is
--- 2000 through 2068, as POSIX's `%y`, so the answer does not hang on
--- the clock as RFC 9110's fifty years ahead would. Nil and why for
--- anything else, a leap second, or a moment outside the range.
function Time.parse_http(text: string): integer | nil, string
  local c: Time.Civil = { nanosecond = 0 }
  local day_name, why: integer, string
  local stop: integer
  local separator = text:sub(4, 4)
  if separator == "," then
    day_name, why = name_at(text, 1, SHORT_DAYS, "a day name")
    if day_name == nil then return nil, why end
    why = byte_is(text, 4, ", ", "after the day name")
    if why ~= nil then return nil, why end
    c.day, why = field(text, 6, 2, "day")
    if c.day == nil then return nil, why end
    why = byte_is(text, 8, " ", "after the day")
    if why ~= nil then return nil, why end
    c.month, why = name_at(text, 9, MONTHS, "a month name")
    if c.month == nil then return nil, why end
    why = byte_is(text, 12, " ", "after the month")
    if why ~= nil then return nil, why end
    c.year, why = field(text, 13, 4, "year")
    if c.year == nil then return nil, why end
    why = byte_is(text, 17, " ", "after the year")
      or clock_into(text, 18, c)
      or byte_is(text, 26, " GMT", "after the time")
    if why ~= nil then return nil, why end
    stop = 29
  elseif separator == " " then
    day_name, why = name_at(text, 1, SHORT_DAYS, "a day name")
    if day_name == nil then return nil, why end
    c.month, why = name_at(text, 5, MONTHS, "a month name")
    if c.month == nil then return nil, why end
    why = byte_is(text, 8, " ", "after the month")
    if why ~= nil then return nil, why end
    if text:sub(9, 9) == " " then
      c.day, why = field(text, 10, 1, "day")
    else
      c.day, why = field(text, 9, 2, "day")
    end
    if c.day == nil then return nil, why end
    why = byte_is(text, 11, " ", "after the day")
      or clock_into(text, 12, c)
      or byte_is(text, 20, " ", "after the time")
    if why ~= nil then return nil, why end
    c.year, why = field(text, 21, 4, "year")
    if c.year == nil then return nil, why end
    stop = 24
  else
    day_name, why = name_at(text, 1, LONG_DAYS, "a day name")
    if day_name == nil then return nil, why end
    local at = #LONG_DAYS[day_name] + 1
    why = byte_is(text, at, ", ", "after the day name")
    if why ~= nil then return nil, why end
    c.day, why = field(text, at + 2, 2, "day")
    if c.day == nil then return nil, why end
    why = byte_is(text, at + 4, "-", "after the day")
    if why ~= nil then return nil, why end
    c.month, why = name_at(text, at + 5, MONTHS, "a month name")
    if c.month == nil then return nil, why end
    why = byte_is(text, at + 8, "-", "after the month")
    if why ~= nil then return nil, why end
    c.year, why = field(text, at + 9, 2, "year")
    if c.year == nil then return nil, why end
    c.year = c.year + (c.year >= 69 and 1900 or 2000)
    why = byte_is(text, at + 11, " ", "after the year")
      or clock_into(text, at + 12, c)
      or byte_is(text, at + 20, " GMT", "after the time")
    if why ~= nil then return nil, why end
    stop = at + 23
  end
  if #text > stop then
    return nil, ("unexpected text at byte %d"):format(stop + 1)
  end
  return moment(c, 0)
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
