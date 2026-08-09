--- Time and clock utilities.
--- Wraps cosmo.unix time functions for timestamps, sleeping, and time breakdown.
---
--- Recorded decision: the formatting surface stays the
--- curated trio — format_http/parse_http (RFC 7231), format_date/parse_date
--- (YYYY-MM-DD), format_iso8601/parse_iso8601 — plus timegm. A general
--- strftime passthrough (time.format(fmt, ts)) is deferred to post-stable
--- demand.
local unix = require("cosmo.unix")
local cosmo = require("cosmo")
local errno = require("cosmic.errno")

--- DateTime represents a broken-down timestamp.
--- Returned by gmtime() and localtime().
local record DateTime
  year: integer -- Full year (e.g., 2024)
  month: integer -- Month (1-12)
  day: integer -- Day of month (1-31)
  hour: integer -- Hour (0-23)
  min: integer -- Minute (0-59)
  sec: integer -- Second (0-60, 60 for a leap second)
  gmtoff: integer -- Offset from UTC in seconds
  wday: integer -- Day of week (0=Sunday, 6=Saturday)
  yday: integer -- Day of year (0-365)
  isdst: boolean -- True when daylight saving time is in effect
  zone: string -- Timezone name (e.g., "UTC", "PDT")
end

--- Get current wall clock time (real time).
--- Returns seconds since epoch and nanoseconds.
--- @return integer Seconds since epoch
--- @return integer Nanoseconds
local function now(): integer, integer
  local secs, nanos = unix.clock_gettime(unix.CLOCK_REALTIME)
  return secs, nanos
end

--- Get monotonic time (not affected by system time changes).
--- Returns seconds and nanoseconds from an unspecified epoch.
--- @return integer Seconds
--- @return integer Nanoseconds
local function monotonic(): integer, integer
  local secs, nanos = unix.clock_gettime(unix.CLOCK_MONOTONIC)
  return secs, nanos
end

--- Get current wall clock time in whole milliseconds since the epoch.
--- Exact for timestamps within 2^53 ms (~285,000 years), so no manual
--- (secs, nanos) arithmetic is needed for timeouts or timestamps.
--- @return integer Milliseconds since epoch
local function now_ms(): integer
  local secs, nanos = unix.clock_gettime(unix.CLOCK_REALTIME)
  return secs * 1000 + math.floor(nanos / 1000000)
end

--- Get monotonic time in whole milliseconds from an unspecified epoch.
--- Use differences between two calls to measure elapsed time.
--- @return integer Milliseconds
local function monotonic_ms(): integer
  local secs, nanos = unix.clock_gettime(unix.CLOCK_MONOTONIC)
  return secs * 1000 + math.floor(nanos / 1000000)
end

--- Get monotonic time in whole nanoseconds from an unspecified epoch.
--- Use differences between two calls to measure elapsed time. The
--- arithmetic is exact 64-bit integer math (no float rounding), which
--- is what benchmark timing wants.
--- @return integer Nanoseconds
local function monotonic_ns(): integer
  local secs, nanos = unix.clock_gettime(unix.CLOCK_MONOTONIC)
  return secs * 1000000000 + nanos
end

-- The engine under sleep_ms — internal since #999: rule 2 makes
-- integer milliseconds THE duration, and this was the tree's only
-- three-return function. It reports the remainder in MILLISECONDS for
-- the same reason it has two slots (#1063): the (secs, nanos) pair
-- pushed the error into slot 3, out of `local v, err`'s reach.
local function sleep_remaining_ms(seconds: integer, nanos?: integer): integer | nil, string
  local ns = nanos or 0
  -- The binding reports its own remainder now (cosmopolitan#237): zero
  -- when the sleep completed, and on EINTR the kernel's own remainder
  -- after the errno. Both used to need a pair of clock reads here.
  local rem_s, rem_ns, eno, eintr_s, eintr_ns = unix.nanosleep(seconds, ns)
  -- Round up so an interrupted sleep never reports 0 remaining.
  if rem_s ~= nil then
    return math.ceil(rem_s * 1000 + rem_ns / 1000000)
  end
  if errno.is_code(eno, "EINTR") then
    return math.ceil((eintr_s or 0) * 1000 + (eintr_ns or 0) / 1000000),
    errno.format(rem_ns, "sleep")
  end
  return nil, errno.format(rem_ns, "sleep")
end

--- Sleep for the specified number of milliseconds.
--- The remainder is a single MILLISECONDS number — no (secs, nanos)
--- arithmetic in retry loops: 0 on an uninterrupted sleep; the
--- remaining milliseconds plus an EINTR-tagged error when a signal
--- interrupts; nil, err on invalid input (EINVAL).
--- @param ms number Milliseconds to sleep
--- @return integer | nil Remaining milliseconds (0 on success), or nil on invalid input
--- @return string? Error message when interrupted (EINTR) or invalid (EINVAL)
local function sleep_ms(ms: number): integer | nil, string
  local seconds = math.floor(ms / 1000)
  local remaining_ms = ms % 1000
  return sleep_remaining_ms(seconds, math.floor(remaining_ms * 1000000))
end

-- gmtime and localtime each destructure their own binding, rather than
-- sharing a helper that takes the BINDING as a parameter. That helper
-- had to restate cosmo.unix's 13-value tuple to type its parameter --
-- a hand-copy of what `cosmo/unix.d.tl` already declares, which is
-- both a shape that can drift and the one thing D20 rule 11 has no
-- room for. A duplicated field mapping cannot drift silently: both
-- halves are checked against DateTime.

--- Break down a UNIX timestamp into UTC (Zulu) time components.
--- @param unixts integer UNIX timestamp (seconds since epoch)
--- @return DateTime Broken-down time in UTC
local function gmtime(unixts: integer): DateTime
  local year, mon, mday, hour, min, sec, gmtoff, wday, yday, isdst, zone =
  unix.gmtime(unixts)
  return {
    year = year,
    month = mon,
    day = mday,
    hour = hour,
    min = min,
    sec = sec,
    gmtoff = gmtoff,
    wday = wday,
    yday = yday,
    isdst = isdst > 0,
    zone = zone,
  }
end

--- Break down a UNIX timestamp into local time components.
--- Respects the TZ environment variable.
--- @param unixts integer UNIX timestamp (seconds since epoch)
--- @return DateTime Broken-down time in local timezone
local function localtime(unixts: integer): DateTime
  local year, mon, mday, hour, min, sec, gmtoff, wday, yday, isdst, zone =
  unix.localtime(unixts)
  return {
    year = year,
    month = mon,
    day = mday,
    hour = hour,
    min = min,
    sec = sec,
    gmtoff = gmtoff,
    wday = wday,
    yday = yday,
    isdst = isdst > 0,
    zone = zone,
  }
end

--- Format a UNIX timestamp as an HTTP date string (RFC 7231).
--- @param timestamp integer UNIX timestamp (seconds since epoch)
--- @return string HTTP date string (e.g., "Sun, 01 Feb 2026 12:00:00 GMT")
local function format_http(timestamp: integer): string
  return cosmo.FormatHttpDateTime(timestamp)
end

-- Internal calendar helpers behind timegm's range checks (#993: their
-- exports were zero-caller; the logic stays private).
local function is_leap_year(year: integer): boolean
  return year % 4 == 0 and (year % 100 ~= 0 or year % 400 == 0)
end

local MONTH_DAYS: {integer} = {31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31}

local function days_in_month(year: integer, month: integer): integer
  if month == 2 and is_leap_year(year) then
    return 29
  end
  return MONTH_DAYS[month]
end

--- Convert UTC broken-down time to UNIX epoch seconds.
--- Fields are range-checked; out-of-range values (e.g. month 13, Feb 30)
--- return nil plus an error rather than throwing.
--- @param year integer Full year (e.g., 2025)
--- @param month integer Month (1-12)
--- @param day integer Day of month (1-31)
--- @param hour integer Hour (0-23)
--- @param min integer Minute (0-59)
--- @param sec integer Second (0-60)
--- @return integer | nil UNIX epoch seconds, or nil on invalid input
--- @return string Error message when input is out of range
local function timegm(year: integer, month: integer, day: integer,
    hour: integer, min: integer, sec: integer): integer | nil, string
  if month < 1 or month > 12 then
    return nil, "timegm: month out of range (1-12): " .. tostring(month)
  end
  -- month is already range-checked, so the nil arm is unreachable
  local dim = days_in_month(year, month)
  if day < 1 or day > dim then
    return nil, "timegm: day out of range (1-" .. tostring(dim) .. "): "
    .. tostring(day)
  end
  if hour < 0 or hour > 23 then
    return nil, "timegm: hour out of range (0-23): " .. tostring(hour)
  end
  if min < 0 or min > 59 then
    return nil, "timegm: minute out of range (0-59): " .. tostring(min)
  end
  if sec < 0 or sec > 60 then
    return nil, "timegm: second out of range (0-60): " .. tostring(sec)
  end
  -- Days since the epoch via the O(1) civil-days algorithm (Howard
  -- Hinnant's days_from_civil), replacing the O(years) loop: shift the
  -- year to start in March so leap days fall at the end, then count
  -- 400-year eras (146097 days each). 719468 is the day number of
  -- 1970-01-01 in that scheme.
  local y = month <= 2 and year - 1 or year
  local era = math.floor(y / 400)
  local yoe = y - era * 400
  local mp = (month + 9) % 12
  local doy = math.floor((153 * mp + 2) / 5) + day - 1
  local doe = yoe * 365 + math.floor(yoe / 4) - math.floor(yoe / 100) + doy
  local days = era * 146097 + doe - 719468
  return days * 86400 + hour * 3600 + min * 60 + sec
end

--- Month abbreviation (RFC 7231 IMF-fixdate) to month number.
local MONTH_ABBR: {string: integer} = {
  Jan = 1, Feb = 2, Mar = 3, Apr = 4, May = 5, Jun = 6,
  Jul = 7, Aug = 8, Sep = 9, Oct = 10, Nov = 11, Dec = 12,
}

--- Parse an HTTP date string (RFC 7231) into a UNIX timestamp.
--- Accepts the IMF-fixdate format that format_http emits and that RFC 7231
--- requires senders to generate (e.g. "Sun, 06 Nov 1994 08:49:37 GMT").
--- The obsolete RFC 850 and asctime forms are not accepted.
--- @param str string HTTP date string
--- @return integer | nil UNIX timestamp, or nil if parsing failed
--- @return string Error message on failure
local function parse_http(str: string): integer | nil, string
  local d, mon, y, h, mi, s = str:match(
    "^%a%a%a, (%d%d) (%a%a%a) (%d%d%d%d) (%d%d):(%d%d):(%d%d) GMT$")
  if not d then
    return nil, "parse_http: not an RFC 7231 date: " .. str
  end
  local month = MONTH_ABBR[mon]
  if not month then
    return nil, "parse_http: unknown month: " .. mon
  end
  return timegm(
    math.tointeger(tonumber(y)), month, math.tointeger(tonumber(d)),
    math.tointeger(tonumber(h)), math.tointeger(tonumber(mi)), math.tointeger(tonumber(s)))
end

--- Format a UNIX timestamp as a date string in UTC.
--- @param timestamp integer UNIX timestamp (seconds since epoch)
--- @return string | nil Date string (e.g., "2025-01-01"), or nil on error
--- @return string Error message if formatting failed
local function format_date(timestamp: integer): string | nil, string
  local s, err = cosmo.Strftime("%Y-%m-%d", timestamp)
  if not s then
    return nil, err
  end
  return s
end

--- Parse a YYYY-MM-DD date string into a UNIX timestamp (midnight UTC).
--- @param str string Date string (e.g., "2025-01-01")
--- @return integer | nil UNIX timestamp, or nil if parsing failed
--- @return string Error message on failure
local function parse_date(str: string): integer | nil, string
  local y, mo, d = str:match("^(%d%d%d%d)-(%d%d)-(%d%d)$")
  if not y then
    return nil, "parse_date: not a YYYY-MM-DD date: " .. str
  end
  return timegm(
    math.tointeger(tonumber(y)), math.tointeger(tonumber(mo)), math.tointeger(tonumber(d)),
    0, 0, 0)
end

--- Format a UNIX timestamp as an ISO 8601 string in UTC.
--- @param timestamp integer UNIX timestamp (seconds since epoch)
--- @return string | nil ISO 8601 string (e.g., "2025-01-01T00:00:00Z"), or nil on error
--- @return string Error message if formatting failed
local function format_iso8601(timestamp: integer): string | nil, string
  local s, err = cosmo.Strftime("%Y-%m-%dT%H:%M:%SZ", timestamp)
  if not s then
    return nil, err
  end
  return s
end

--- Resolve an ISO 8601 timezone suffix into a signed offset in seconds.
--- Accepts "", "Z"/"z" (UTC), "±HH:MM", "±HHMM", and "±HH".
--- @return integer Offset east of UTC in seconds, or nil if unparseable
local function parse_offset(tz: string): integer, string
  if tz == "" or tz == "Z" or tz == "z" then
    return 0
  end
  local sign, oh, om = tz:match("^([%+%-])(%d%d):(%d%d)$")
  if not sign then
    sign, oh, om = tz:match("^([%+%-])(%d%d)(%d%d)$")
  end
  if not sign then
    sign, oh = tz:match("^([%+%-])(%d%d)$")
    om = "00"
  end
  if not sign then
    return nil, "invalid timezone offset: " .. tz
  end
  local h = math.tointeger(tonumber(oh))
  local m = math.tointeger(tonumber(om))
  if h > 23 or m > 59 then
    return nil, "timezone offset out of range: " .. tz
  end
  local offset = h * 3600 + m * 60
  return sign == "+" and offset or -offset
end

--- Parse an ISO 8601 timestamp string into a UNIX epoch seconds value.
--- Accepts full timestamps with a "Z" suffix, "±HH:MM"/"±HHMM"/"±HH" offsets,
--- or no suffix (treated as UTC). Optional fractional seconds are accepted and
--- truncated to whole seconds. Also accepts date-only "YYYY-MM-DD" (midnight
--- UTC).
--- @param str string ISO 8601 string (e.g., "2025-01-01T00:00:00.5Z")
--- @return integer | nil UNIX timestamp, or nil if parsing failed
--- @return string Error message on failure
local function parse_iso8601(str: string): integer | nil, string
  -- try date-only format first
  local dy, dmo, dd = str:match("^(%d%d%d%d)-(%d%d)-(%d%d)$")
  if dy then
    return timegm(
      math.tointeger(tonumber(dy)), math.tointeger(tonumber(dmo)), math.tointeger(tonumber(dd)),
      0, 0, 0)
  end
  local y, mo, d, h, mi, s, rest = str:match(
    "^(%d%d%d%d)-(%d%d)-(%d%d)T(%d%d):(%d%d):(%d%d)(.*)$")
  if not y then
    return nil, "parse_iso8601: not an ISO 8601 timestamp: " .. str
  end
  -- optional fractional seconds are accepted and dropped (whole-second epoch)
  local after = rest:match("^%.%d+(.*)$")
  local tz = after or rest
  local epoch, err = timegm(
    math.tointeger(tonumber(y)), math.tointeger(tonumber(mo)), math.tointeger(tonumber(d)),
    math.tointeger(tonumber(h)), math.tointeger(tonumber(mi)), math.tointeger(tonumber(s)))
  if not epoch then
    return nil, err
  end
  local offset, oerr = parse_offset(tz)
  if not offset then
    return nil, "parse_iso8601: " .. oerr
  end
  return epoch - offset
end

local record TimeModule
  --- Exported so callers can name gmtime()/localtime()'s result.
  type DateTime = DateTime

  -- Clock constants

  -- Functions
  now: function(): integer, integer
  monotonic: function(): integer, integer
  now_ms: function(): integer
  monotonic_ms: function(): integer
  monotonic_ns: function(): integer
  sleep_ms: function(ms: number): integer | nil, string
  gmtime: function(unixts: integer): DateTime
  localtime: function(unixts: integer): DateTime
  format_http: function(timestamp: integer): string
  parse_http: function(str: string): integer | nil, string
  format_date: function(timestamp: integer): string | nil, string
  parse_date: function(str: string): integer | nil, string
  format_iso8601: function(timestamp: integer): string | nil, string
  parse_iso8601: function(str: string): integer | nil, string
  timegm: function(year: integer, month: integer, day: integer, hour: integer, min: integer, sec: integer): integer | nil, string
end

local M: TimeModule = {
  -- Clock constants

  -- Functions
  now = now,
  monotonic = monotonic,
  now_ms = now_ms,
  monotonic_ms = monotonic_ms,
  monotonic_ns = monotonic_ns,
  sleep_ms = sleep_ms,
  gmtime = gmtime,
  localtime = localtime,
  format_http = format_http,
  parse_http = parse_http,
  format_date = format_date,
  parse_date = parse_date,
  format_iso8601 = format_iso8601,
  parse_iso8601 = parse_iso8601,
  timegm = timegm,
}

return M
