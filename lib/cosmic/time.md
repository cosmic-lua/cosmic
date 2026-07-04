# time

 Time and clock utilities.
 Wraps cosmo.unix time functions for timestamps, sleeping, and time breakdown.

## Types

### DateTime

 DateTime represents a broken-down timestamp.
 Returned by gmtime() and localtime().

```teal
local record DateTime
  year: number
  month: number
  day: number
  hour: number
  min: number
  sec: number
  gmtoff: number
  wday: number
  yday: number
  isdst: number
  zone: string
end
```

### Clock

 Clock identifiers for clock_gettime().

```teal
local record Clock
  REALTIME: number
  MONOTONIC: number
  BOOTTIME: number
  MONOTONIC_RAW: number
  REALTIME_COARSE: number
  MONOTONIC_COARSE: number
  THREAD_CPUTIME_ID: number
  PROCESS_CPUTIME_ID: number
end
```

### TimeModule

```teal
local record TimeModule
  CLOCK_REALTIME: number
  CLOCK_MONOTONIC: number
  CLOCK_BOOTTIME: number
  CLOCK_MONOTONIC_RAW: number
  CLOCK_REALTIME_COARSE: number
  CLOCK_MONOTONIC_COARSE: number
  CLOCK_THREAD_CPUTIME_ID: number
  CLOCK_PROCESS_CPUTIME_ID: number
  clock_gettime: function(clock?: number): number, number
  now: function(): number, number
  monotonic: function(): number, number
  sleep: function(seconds: number, nanos?: number): number, number
  sleep_ms: function(ms: number): number, number
  gmtime: function(unixts: number): DateTime
  localtime: function(unixts: number): DateTime
  format_http: function(timestamp: number): string
  parse_http: function(str: string): number, string
  format_date: function(timestamp: number): string
  parse_date: function(str: string): number, string
  format_iso8601: function(timestamp: number): string
  parse_iso8601: function(str: string): number, string
  timegm: function(year: number, month: number, day: number, hour: number, min: number, sec: number): number, string
end
```

## Functions

### clock_gettime

```teal
function clock_gettime(clock?: number): number, number
```

 Get current time from the specified clock.
 Returns seconds since epoch and nanoseconds.

**Parameters:**

- `clock` (number?) - Clock identifier (default: CLOCK_REALTIME)

**Returns:**

- number - Seconds since epoch
- number - Nanoseconds

### now

```teal
function now(): number, number
```

 Get current wall clock time (real time).
 Returns seconds since epoch and nanoseconds.

**Returns:**

- number - Seconds since epoch
- number - Nanoseconds

### monotonic

```teal
function monotonic(): number, number
```

 Get monotonic time (not affected by system time changes).
 Returns seconds and nanoseconds from an unspecified epoch.

**Returns:**

- number - Seconds
- number - Nanoseconds

### sleep

```teal
function sleep(seconds: number, nanos?: number): number, number
```

 Sleep for the specified duration.

**Parameters:**

- `seconds` (number) - Seconds to sleep
- `nanos` (number?) - Additional nanoseconds to sleep (default: 0)

**Returns:**

- number - Remaining seconds if interrupted
- number - Remaining nanoseconds if interrupted

### sleep_ms

```teal
function sleep_ms(ms: number): number, number
```

 Sleep for the specified number of milliseconds.

**Parameters:**

- `ms` (number) - Milliseconds to sleep

**Returns:**

- number - Remaining seconds if interrupted
- number - Remaining nanoseconds if interrupted

### gmtime

```teal
function gmtime(unixts: number): DateTime
```

 Break down a UNIX timestamp into UTC (Zulu) time components.

**Parameters:**

- `unixts` (number) - UNIX timestamp (seconds since epoch)

**Returns:**

- DateTime - Broken-down time in UTC

### localtime

```teal
function localtime(unixts: number): DateTime
```

 Break down a UNIX timestamp into local time components.
 Respects the TZ environment variable.

**Parameters:**

- `unixts` (number) - UNIX timestamp (seconds since epoch)

**Returns:**

- DateTime - Broken-down time in local timezone

### format_http

```teal
function format_http(timestamp: number): string
```

 Format a UNIX timestamp as an HTTP date string (RFC 7231).

**Parameters:**

- `timestamp` (number) - UNIX timestamp (seconds since epoch)

**Returns:**

- string - HTTP date string (e.g., "Sun, 01 Feb 2026 12:00:00 GMT")

### timegm

```teal
function timegm(year: number, month: number, day: number,
    hour: number, min: number, sec: number): number, string
```

 Convert UTC broken-down time to UNIX epoch seconds.
 Fields are range-checked; out-of-range values (e.g. month 13, Feb 30)
 return nil plus an error rather than throwing.

**Parameters:**

- `year` (number) - Full year (e.g., 2025)
- `month` (number) - Month (1-12)
- `day` (number) - Day of month (1-31)
- `hour` (number) - Hour (0-23)
- `min` (number) - Minute (0-59)
- `sec` (number) - Second (0-60)

**Returns:**

- number - UNIX epoch seconds, or nil on invalid input
- string - Error message when input is out of range

### parse_http

```teal
function parse_http(str: string): number, string
```

 Parse an HTTP date string (RFC 7231) into a UNIX timestamp.
 Accepts the IMF-fixdate format that format_http emits and that RFC 7231
 requires senders to generate (e.g. "Sun, 06 Nov 1994 08:49:37 GMT").
 The obsolete RFC 850 and asctime forms are not accepted.

**Parameters:**

- `str` (string) - HTTP date string

**Returns:**

- number - UNIX timestamp, or nil if parsing failed
- string - Error message on failure

### format_date

```teal
function format_date(timestamp: number): string
```

 Format a UNIX timestamp as a date string in UTC.

**Parameters:**

- `timestamp` (number) - UNIX timestamp (seconds since epoch)

**Returns:**

- string - Date string (e.g., "2025-01-01")

### parse_date

```teal
function parse_date(str: string): number, string
```

 Parse a YYYY-MM-DD date string into a UNIX timestamp (midnight UTC).

**Parameters:**

- `str` (string) - Date string (e.g., "2025-01-01")

**Returns:**

- number - UNIX timestamp, or nil if parsing failed
- string - Error message on failure

### format_iso8601

```teal
function format_iso8601(timestamp: number): string
```

 Format a UNIX timestamp as an ISO 8601 string in UTC.

**Parameters:**

- `timestamp` (number) - UNIX timestamp (seconds since epoch)

**Returns:**

- string - ISO 8601 string (e.g., "2025-01-01T00:00:00Z")

### parse_iso8601

```teal
function parse_iso8601(str: string): number, string
```

 Parse an ISO 8601 timestamp string into a UNIX epoch seconds value.
 Accepts full timestamps with a "Z" suffix, "±HH:MM"/"±HHMM"/"±HH" offsets,
 or no suffix (treated as UTC). Optional fractional seconds are accepted and
 truncated to whole seconds. Also accepts date-only "YYYY-MM-DD" (midnight
 UTC).

**Parameters:**

- `str` (string) - ISO 8601 string (e.g., "2025-01-01T00:00:00.5Z")

**Returns:**

- number - UNIX timestamp, or nil if parsing failed
- string - Error message on failure
