--- Time and clock utilities.
--- Wraps cosmo.unix time functions for timestamps, sleeping, and time breakdown.
local unix = require("cosmo.unix")

--- DateTime represents a broken-down timestamp.
--- Returned by gmtime() and localtime().
local record DateTime
  year: number        -- Full year (e.g., 2024)
  month: number       -- Month (1-12)
  day: number         -- Day of month (1-31)
  hour: number        -- Hour (0-23)
  min: number         -- Minute (0-59)
  sec: number         -- Second (0-59)
  gmtoff: number      -- Offset from UTC in seconds
  wday: number        -- Day of week (1=Sunday, 7=Saturday)
  yday: number        -- Day of year (1-366)
  isdst: number       -- Daylight saving time flag (1=DST, 0=standard)
  zone: string        -- Timezone name (e.g., "UTC", "PDT")
end

--- Clock identifiers for clock_gettime().
local record Clock
  REALTIME: number           -- Wall clock, subject to NTP adjustments
  MONOTONIC: number          -- Monotonic clock, not affected by system time changes
  BOOTTIME: number           -- Monotonic clock including suspend time
  MONOTONIC_RAW: number      -- Raw monotonic clock, not adjusted for NTP
  REALTIME_COARSE: number    -- Faster but less precise real time clock
  MONOTONIC_COARSE: number   -- Faster but less precise monotonic clock
  THREAD_CPUTIME_ID: number  -- CPU time for current thread
  PROCESS_CPUTIME_ID: number -- CPU time for current process
end

--- Get current time from the specified clock.
--- Returns seconds since epoch and nanoseconds.
--- @param clock number? Clock identifier (default: CLOCK_REALTIME)
--- @return number Seconds since epoch
--- @return number Nanoseconds
local function clock_gettime(clock?: number): number, number
  return unix.clock_gettime(clock)
end

--- Get current wall clock time (real time).
--- Returns seconds since epoch and nanoseconds.
--- @return number Seconds since epoch
--- @return number Nanoseconds
local function now(): number, number
  return unix.clock_gettime(unix.CLOCK_REALTIME)
end

--- Get monotonic time (not affected by system time changes).
--- Returns seconds and nanoseconds from an unspecified epoch.
--- @return number Seconds
--- @return number Nanoseconds
local function monotonic(): number, number
  return unix.clock_gettime(unix.CLOCK_MONOTONIC)
end

--- Sleep for the specified duration.
--- @param seconds number Seconds to sleep
--- @param nanos number? Additional nanoseconds to sleep (default: 0)
--- @return number Remaining seconds if interrupted
--- @return number Remaining nanoseconds if interrupted
local function sleep(seconds: number, nanos?: number): number, number
  return unix.nanosleep(seconds, nanos or 0)
end

--- Sleep for the specified number of milliseconds.
--- @param ms number Milliseconds to sleep
--- @return number Remaining seconds if interrupted
--- @return number Remaining nanoseconds if interrupted
local function sleep_ms(ms: number): number, number
  local seconds = math.floor(ms / 1000)
  local remaining_ms = ms % 1000
  local nanos = remaining_ms * 1000000
  return unix.nanosleep(seconds, nanos)
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
}

return M
