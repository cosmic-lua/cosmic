# time

 Time and clock utilities.
 Wraps cosmo.unix time functions for timestamps, sleeping, and time breakdown.

 Recorded decision (api-review-2, #593): the formatting surface stays the
 curated trio — format_http/parse_http (RFC 7231), format_date/parse_date
 (YYYY-MM-DD), format_iso8601/parse_iso8601 — plus timegm. A general
 strftime passthrough (time.format(fmt, ts)) is deferred to post-stable
 demand.

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
  isdst: boolean
  zone: string
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
  now_ms: function(): number
  monotonic_ms: function(): number
  sleep: function(seconds: number, nanos?: number): number | nil, number, string
  sleep_ms: function(ms: number): number | nil, string
  gmtime: function(unixts: number): DateTime
  localtime: function(unixts: number): DateTime
  format_http: function(timestamp: number): string
  parse_http: function(str: string): number | nil, string
  format_date: function(timestamp: number): string | nil, string
  parse_date: function(str: string): number | nil, string
  format_iso8601: function(timestamp: number): string | nil, string
  parse_iso8601: function(str: string): number | nil, string
  timegm: function(year: number, month: number, day: number, hour: number, min: number, sec: number): number | nil, string
  is_leap_year: function(year: number): boolean
  days_in_month: function(year: number, month: number): number | nil, string
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

### now_ms

```teal
function now_ms(): number
```

 Get current wall clock time in whole milliseconds since the epoch.
 Exact for timestamps within 2^53 ms (~285,000 years), so no manual
 (secs, nanos) arithmetic is needed for timeouts or timestamps.

**Returns:**

- number - Milliseconds since epoch

### monotonic_ms

```teal
function monotonic_ms(): number
```

 Get monotonic time in whole milliseconds from an unspecified epoch.
 Use differences between two calls to measure elapsed time.

**Returns:**

- number - Milliseconds

### sleep

```teal
function sleep(seconds: number, nanos?: number): number | nil, number, string
```

 Sleep for the specified duration.
 Returns 0, 0 after an uninterrupted sleep. When a signal interrupts
 the sleep, returns the remaining seconds and nanoseconds plus an
 error string naming EINTR. Invalid input (e.g. a negative duration)
 returns nil, nil, and an error naming EINVAL.

**Parameters:**

- `seconds` (number) - Seconds to sleep
- `nanos` (number?) - Additional nanoseconds to sleep (default: 0)

**Returns:**

- number - | nil Remaining seconds (0 on success), or nil on invalid input
- number - Remaining nanoseconds (0 on success)
- string? - Error message when interrupted (EINTR) or invalid (EINVAL)

### sleep_ms

```teal
function sleep_ms(ms: number): number | nil, string
```

 Sleep for the specified number of milliseconds.
 The remainder is a single MILLISECONDS number — no (secs, nanos)
 arithmetic in retry loops: 0 on an uninterrupted sleep; the
 remaining milliseconds plus an EINTR-tagged error when a signal
 interrupts; nil, err on invalid input (EINVAL). time.sleep keeps
 its (secs, nanos, err) contract for symmetry with clock_gettime.

**Parameters:**

- `ms` (number) - Milliseconds to sleep

**Returns:**

- number - | nil Remaining milliseconds (0 on success), or nil on invalid input
- string? - Error message when interrupted (EINTR) or invalid (EINVAL)

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

### is_leap_year

```teal
function is_leap_year(year: number): boolean
```

 Return true if year is a leap year (Gregorian rules).

**Parameters:**

- `year` (number) - Full year (e.g., 2024)

**Returns:**

- boolean - True when the year has 366 days

### days_in_month

```teal
function days_in_month(year: number, month: number): number | nil, string
```

 Number of days in the given month, accounting for leap years.

**Parameters:**

- `year` (number) - Full year (e.g., 2024)
- `month` (number) - Month (1-12)

**Returns:**

- number - | nil Days in that month (28-31), or nil when month is out of range
- string - Error message when month is out of range

### timegm

```teal
function timegm(year: number, month: number, day: number,
    hour: number, min: number, sec: number): number | nil, string
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

- number - | nil UNIX epoch seconds, or nil on invalid input
- string - Error message when input is out of range

### parse_http

```teal
function parse_http(str: string): number | nil, string
```

 Parse an HTTP date string (RFC 7231) into a UNIX timestamp.
 Accepts the IMF-fixdate format that format_http emits and that RFC 7231
 requires senders to generate (e.g. "Sun, 06 Nov 1994 08:49:37 GMT").
 The obsolete RFC 850 and asctime forms are not accepted.

**Parameters:**

- `str` (string) - HTTP date string

**Returns:**

- number - | nil UNIX timestamp, or nil if parsing failed
- string - Error message on failure

### format_date

```teal
function format_date(timestamp: number): string | nil, string
```

 Format a UNIX timestamp as a date string in UTC.

**Parameters:**

- `timestamp` (number) - UNIX timestamp (seconds since epoch)

**Returns:**

- string - | nil Date string (e.g., "2025-01-01"), or nil on error
- string - Error message if formatting failed

### parse_date

```teal
function parse_date(str: string): number | nil, string
```

 Parse a YYYY-MM-DD date string into a UNIX timestamp (midnight UTC).

**Parameters:**

- `str` (string) - Date string (e.g., "2025-01-01")

**Returns:**

- number - | nil UNIX timestamp, or nil if parsing failed
- string - Error message on failure

### format_iso8601

```teal
function format_iso8601(timestamp: number): string | nil, string
```

 Format a UNIX timestamp as an ISO 8601 string in UTC.

**Parameters:**

- `timestamp` (number) - UNIX timestamp (seconds since epoch)

**Returns:**

- string - | nil ISO 8601 string (e.g., "2025-01-01T00:00:00Z"), or nil on error
- string - Error message if formatting failed

### parse_iso8601

```teal
function parse_iso8601(str: string): number | nil, string
```

 Parse an ISO 8601 timestamp string into a UNIX epoch seconds value.
 Accepts full timestamps with a "Z" suffix, "±HH:MM"/"±HHMM"/"±HH" offsets,
 or no suffix (treated as UTC). Optional fractional seconds are accepted and
 truncated to whole seconds. Also accepts date-only "YYYY-MM-DD" (midnight
 UTC).

**Parameters:**

- `str` (string) - ISO 8601 string (e.g., "2025-01-01T00:00:00.5Z")

**Returns:**

- number - | nil UNIX timestamp, or nil if parsing failed
- string - Error message on failure
