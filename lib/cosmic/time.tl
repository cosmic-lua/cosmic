--- Time and clock utilities.
--- Wraps cosmo.unix time functions for timestamps, sleeping, and time breakdown.
local unix = require("cosmo.unix")
local cosmo = require("cosmo")

--- DateTime represents a broken-down timestamp.
--- Returned by gmtime() and localtime().
local record DateTime
  year: number -- Full year (e.g., 2024)
  month: number -- Month (1-12)
  day: number -- Day of month (1-31)
  hour: number -- Hour (0-23)
  min: number -- Minute (0-59)
  sec: number -- Second (0-60, 60 for a leap second)
  gmtoff: number -- Offset from UTC in seconds
  wday: number -- Day of week (0=Sunday, 6=Saturday)
  yday: number -- Day of year (0-365)
  isdst: number -- Daylight saving time flag (1=DST, 0=standard)
  zone: string -- Timezone name (e.g., "UTC", "PDT")
end

--- Clock identifiers for clock_gettime().
local record Clock
  REALTIME: number -- Wall clock, subject to NTP adjustments
  MONOTONIC: number -- Monotonic clock, not affected by system time changes
  BOOTTIME: number -- Monotonic clock including suspend time
  MONOTONIC_RAW: number -- Raw monotonic clock, not adjusted for NTP
  REALTIME_COARSE: number -- Faster but less precise real time clock
  MONOTONIC_COARSE: number -- Faster but less precise monotonic clock
  THREAD_CPUTIME_ID: number -- CPU time for current thread
  PROCESS_CPUTIME_ID: number -- CPU time for current process
end

--- Get current time from the specified clock.
--- Returns seconds since epoch and nanoseconds.
--- @param clock number? Clock identifier (default: CLOCK_REALTIME)
--- @return number Seconds since epoch
--- @return number Nanoseconds
local function clock_gettime(clock?: number): number, number
  local secs, nanos = unix.clock_gettime(clock)
  return secs, nanos
end

--- Get current wall clock time (real time).
--- Returns seconds since epoch and nanoseconds.
--- @return number Seconds since epoch
--- @return number Nanoseconds
local function now(): number, number
  local secs, nanos = unix.clock_gettime(unix.CLOCK_REALTIME)
  return secs, nanos
end

--- Get monotonic time (not affected by system time changes).
--- Returns seconds and nanoseconds from an unspecified epoch.
--- @return number Seconds
--- @return number Nanoseconds
local function monotonic(): number, number
  local secs, nanos = unix.clock_gettime(unix.CLOCK_MONOTONIC)
  return secs, nanos
end

--- Sleep for the specified duration.
--- @param seconds number Seconds to sleep
--- @param nanos number? Additional nanoseconds to sleep (default: 0)
--- @return number Remaining seconds if interrupted
--- @return number Remaining nanoseconds if interrupted
local function sleep(seconds: number, nanos?: number): number, number
  local rem_s, rem_ns = unix.nanosleep(seconds, nanos or 0)
  return rem_s, rem_ns
end

--- Sleep for the specified number of milliseconds.
--- @param ms number Milliseconds to sleep
--- @return number Remaining seconds if interrupted
--- @return number Remaining nanoseconds if interrupted
local function sleep_ms(ms: number): number, number
  local seconds = math.floor(ms / 1000)
  local remaining_ms = ms % 1000
  local nanos = remaining_ms * 1000000
  local rem_s, rem_ns = unix.nanosleep(seconds, nanos)
  return rem_s, rem_ns
end

--- Break down a UNIX timestamp into UTC (Zulu) time components.
--- @param unixts number UNIX timestamp (seconds since epoch)
--- @return DateTime Broken-down time in UTC
local function gmtime(unixts: number): DateTime
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
    isdst = isdst,
    zone = zone,
  }
end

--- Break down a UNIX timestamp into local time components.
--- Respects the TZ environment variable.
--- @param unixts number UNIX timestamp (seconds since epoch)
--- @return DateTime Broken-down time in local timezone
local function localtime(unixts: number): DateTime
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
    isdst = isdst,
    zone = zone,
  }
end

--- Format a UNIX timestamp as an HTTP date string (RFC 7231).
--- @param timestamp number UNIX timestamp (seconds since epoch)
--- @return string HTTP date string (e.g., "Sun, 01 Feb 2026 12:00:00 GMT")
local function format_http(timestamp: number): string
  return cosmo.FormatHttpDateTime(timestamp)
end

--- Return true if year is a leap year.
local function is_leap_year(year: number): boolean
  return year % 4 == 0 and (year % 100 ~= 0 or year % 400 == 0)
end

--- Days in each month for a non-leap year.
local MONTH_DAYS: {integer} = {31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31}

--- Number of days in the given month, accounting for leap years.
local function days_in_month(year: number, month: number): number
  if month == 2 and is_leap_year(year) then
    return 29
  end
  return MONTH_DAYS[month as integer]
end

--- Convert UTC broken-down time to UNIX epoch seconds.
--- Fields are range-checked; out-of-range values (e.g. month 13, Feb 30)
--- return nil plus an error rather than throwing.
--- @param year number Full year (e.g., 2025)
--- @param month number Month (1-12)
--- @param day number Day of month (1-31)
--- @param hour number Hour (0-23)
--- @param min number Minute (0-59)
--- @param sec number Second (0-60)
--- @return number | nil UNIX epoch seconds, or nil on invalid input
--- @return string Error message when input is out of range
local function timegm(year: number, month: number, day: number,
    hour: number, min: number, sec: number): number | nil, string
  if month < 1 or month > 12 then
    return nil, "timegm: month out of range (1-12): " .. tostring(month)
  end
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
  local days: number = 0
  -- count days for complete years since 1970
  if year >= 1970 then
    for y = 1970, year - 1 do
      days = days + (is_leap_year(y) and 366 or 365)
    end
  else
    for y = year, 1969 do
      days = days - (is_leap_year(y) and 366 or 365)
    end
  end
  -- count days for complete months in the target year
  for m = 1, month - 1 do
    days = days + MONTH_DAYS[m as integer]
    if m == 2 and is_leap_year(year) then
      days = days + 1
    end
  end
  days = days + day - 1
  return days * 86400 + hour * 3600 + min * 60 + sec
end

--- Month abbreviation (RFC 7231 IMF-fixdate) to month number.
local MONTH_ABBR: {string: number} = {
  Jan = 1, Feb = 2, Mar = 3, Apr = 4, May = 5, Jun = 6,
  Jul = 7, Aug = 8, Sep = 9, Oct = 10, Nov = 11, Dec = 12,
}

--- Parse an HTTP date string (RFC 7231) into a UNIX timestamp.
--- Accepts the IMF-fixdate format that format_http emits and that RFC 7231
--- requires senders to generate (e.g. "Sun, 06 Nov 1994 08:49:37 GMT").
--- The obsolete RFC 850 and asctime forms are not accepted.
--- @param str string HTTP date string
--- @return number | nil UNIX timestamp, or nil if parsing failed
--- @return string Error message on failure
local function parse_http(str: string): number | nil, string
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
    tonumber(y) as number, month, tonumber(d) as number,
    tonumber(h) as number, tonumber(mi) as number, tonumber(s) as number)
end

--- Format a UNIX timestamp as a date string in UTC.
--- @param timestamp number UNIX timestamp (seconds since epoch)
--- @return string Date string (e.g., "2025-01-01")
local function format_date(timestamp: number): string
  return cosmo.Strftime("%Y-%m-%d", timestamp)
end

--- Parse a YYYY-MM-DD date string into a UNIX timestamp (midnight UTC).
--- @param str string Date string (e.g., "2025-01-01")
--- @return number | nil UNIX timestamp, or nil if parsing failed
--- @return string Error message on failure
local function parse_date(str: string): number | nil, string
  local y, mo, d = str:match("^(%d%d%d%d)-(%d%d)-(%d%d)$")
  if not y then
    return nil, "parse_date: not a YYYY-MM-DD date: " .. str
  end
  return timegm(
    tonumber(y) as number, tonumber(mo) as number, tonumber(d) as number,
    0, 0, 0)
end

--- Format a UNIX timestamp as an ISO 8601 string in UTC.
--- @param timestamp number UNIX timestamp (seconds since epoch)
--- @return string ISO 8601 string (e.g., "2025-01-01T00:00:00Z")
local function format_iso8601(timestamp: number): string
  return cosmo.Strftime("%Y-%m-%dT%H:%M:%SZ", timestamp)
end

--- Resolve an ISO 8601 timezone suffix into a signed offset in seconds.
--- Accepts "", "Z"/"z" (UTC), "±HH:MM", "±HHMM", and "±HH".
--- @return number Offset east of UTC in seconds, or nil if unparseable
local function parse_offset(tz: string): number, string
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
  local h = tonumber(oh) as number
  local m = tonumber(om) as number
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
--- @return number | nil UNIX timestamp, or nil if parsing failed
--- @return string Error message on failure
local function parse_iso8601(str: string): number | nil, string
  -- try date-only format first
  local dy, dmo, dd = str:match("^(%d%d%d%d)-(%d%d)-(%d%d)$")
  if dy then
    return timegm(
      tonumber(dy) as number, tonumber(dmo) as number, tonumber(dd) as number,
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
    tonumber(y) as number, tonumber(mo) as number, tonumber(d) as number,
    tonumber(h) as number, tonumber(mi) as number, tonumber(s) as number)
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
  -- Clock constants
  CLOCK_REALTIME: number
  CLOCK_MONOTONIC: number
  CLOCK_BOOTTIME: number
  CLOCK_MONOTONIC_RAW: number
  CLOCK_REALTIME_COARSE: number
  CLOCK_MONOTONIC_COARSE: number
  CLOCK_THREAD_CPUTIME_ID: number
  CLOCK_PROCESS_CPUTIME_ID: number

  -- Functions
  clock_gettime: function(clock?: number): number, number
  now: function(): number, number
  monotonic: function(): number, number
  sleep: function(seconds: number, nanos?: number): number, number
  sleep_ms: function(ms: number): number, number
  gmtime: function(unixts: number): DateTime
  localtime: function(unixts: number): DateTime
  format_http: function(timestamp: number): string
  parse_http: function(str: string): number | nil, string
  format_date: function(timestamp: number): string
  parse_date: function(str: string): number | nil, string
  format_iso8601: function(timestamp: number): string
  parse_iso8601: function(str: string): number | nil, string
  timegm: function(year: number, month: number, day: number, hour: number, min: number, sec: number): number | nil, string
end

local M: TimeModule = {
  -- Clock constants
  CLOCK_REALTIME = unix.CLOCK_REALTIME,
  CLOCK_MONOTONIC = unix.CLOCK_MONOTONIC,
  CLOCK_BOOTTIME = unix.CLOCK_BOOTTIME,
  CLOCK_MONOTONIC_RAW = unix.CLOCK_MONOTONIC_RAW,
  CLOCK_REALTIME_COARSE = unix.CLOCK_REALTIME_COARSE,
  CLOCK_MONOTONIC_COARSE = unix.CLOCK_MONOTONIC_COARSE,
  CLOCK_THREAD_CPUTIME_ID = unix.CLOCK_THREAD_CPUTIME_ID,
  CLOCK_PROCESS_CPUTIME_ID = unix.CLOCK_PROCESS_CPUTIME_ID,

  -- Functions
  clock_gettime = clock_gettime,
  now = now,
  monotonic = monotonic,
  sleep = sleep,
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
