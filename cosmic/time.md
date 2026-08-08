# time

 Time and clock utilities.
 Wraps cosmo.unix time functions for timestamps, sleeping, and time breakdown.

 Recorded decision (api-review-2): the formatting surface stays the
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
  year: integer
  month: integer
  day: integer
  hour: integer
  min: integer
  sec: integer
  gmtoff: integer
  wday: integer
  yday: integer
  isdst: boolean
  zone: string
end
```

### TimeModule

```teal
local record TimeModule
  now: function(): integer, integer
  monotonic: function(): integer, integer
  now_ms: function(): integer
  monotonic_ms: function(): integer
  monotonic_ns: function(): integer
  sleep: function(seconds: integer, nanos?: integer): integer | nil, integer, string
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
```

## Functions

### now

```teal
function now(): integer, integer
```

 Get current wall clock time (real time).
 Returns seconds since epoch and nanoseconds.

**Returns:**

- integer - Seconds since epoch
- integer - Nanoseconds

### monotonic

```teal
function monotonic(): integer, integer
```

 Get monotonic time (not affected by system time changes).
 Returns seconds and nanoseconds from an unspecified epoch.

**Returns:**

- integer - Seconds
- integer - Nanoseconds

### now_ms

```teal
function now_ms(): integer
```

 Get current wall clock time in whole milliseconds since the epoch.
 Exact for timestamps within 2^53 ms (~285,000 years), so no manual
 (secs, nanos) arithmetic is needed for timeouts or timestamps.

**Returns:**

- integer - Milliseconds since epoch

### monotonic_ms

```teal
function monotonic_ms(): integer
```

 Get monotonic time in whole milliseconds from an unspecified epoch.
 Use differences between two calls to measure elapsed time.

**Returns:**

- integer - Milliseconds

### monotonic_ns

```teal
function monotonic_ns(): integer
```

 Get monotonic time in whole nanoseconds from an unspecified epoch.
 Use differences between two calls to measure elapsed time. The
 arithmetic is exact 64-bit integer math (no float rounding), which
 is what benchmark timing wants.

**Returns:**

- integer - Nanoseconds

### sleep

```teal
function sleep(seconds: integer, nanos?: integer): integer | nil, integer, string
```

 Sleep for the specified duration.
 Returns 0, 0 after an uninterrupted sleep. When a signal interrupts
 the sleep, returns the remaining seconds and nanoseconds plus an
 error string naming EINTR. Invalid input (e.g. a negative duration)
 returns nil, nil, and an error naming EINVAL.
 sleep is a deliberate exception to the automatic EINTR retry policy
 (cosmic.stream): the interruption IS the result, and the
 remainder lets callers resume or bail as they choose.

**Parameters:**

- `seconds` (integer) - Seconds to sleep
- `nanos` (integer?) - Additional nanoseconds to sleep (default: 0)

**Returns:**

- integer - | nil Remaining seconds (0 on success), or nil on invalid input
- integer - Remaining nanoseconds (0 on success)
- string? - Error message when interrupted (EINTR) or invalid (EINVAL)

### sleep_ms

```teal
function sleep_ms(ms: number): integer | nil, string
```

 Sleep for the specified number of milliseconds.
 The remainder is a single MILLISECONDS number — no (secs, nanos)
 arithmetic in retry loops: 0 on an uninterrupted sleep; the
 remaining milliseconds plus an EINTR-tagged error when a signal
 interrupts; nil, err on invalid input (EINVAL). time.sleep keeps
 its (secs, nanos, err) contract for symmetry with now/monotonic.

**Parameters:**

- `ms` (number) - Milliseconds to sleep

**Returns:**

- integer - | nil Remaining milliseconds (0 on success), or nil on invalid input
- string? - Error message when interrupted (EINTR) or invalid (EINVAL)

### gmtime

```teal
function gmtime(unixts: integer): DateTime
```

 Break down a UNIX timestamp into UTC (Zulu) time components.

**Parameters:**

- `unixts` (integer) - UNIX timestamp (seconds since epoch)

**Returns:**

- DateTime - Broken-down time in UTC

### localtime

```teal
function localtime(unixts: integer): DateTime
```

 Break down a UNIX timestamp into local time components.
 Respects the TZ environment variable.

**Parameters:**

- `unixts` (integer) - UNIX timestamp (seconds since epoch)

**Returns:**

- DateTime - Broken-down time in local timezone

### format_http

```teal
function format_http(timestamp: integer): string
```

 Format a UNIX timestamp as an HTTP date string (RFC 7231).

**Parameters:**

- `timestamp` (integer) - UNIX timestamp (seconds since epoch)

**Returns:**

- string - HTTP date string (e.g., "Sun, 01 Feb 2026 12:00:00 GMT")

### timegm

```teal
function timegm(year: integer, month: integer, day: integer,
    hour: integer, min: integer, sec: integer): integer | nil, string
```

 Convert UTC broken-down time to UNIX epoch seconds.
 Fields are range-checked; out-of-range values (e.g. month 13, Feb 30)
 return nil plus an error rather than throwing.

**Parameters:**

- `year` (integer) - Full year (e.g., 2025)
- `month` (integer) - Month (1-12)
- `day` (integer) - Day of month (1-31)
- `hour` (integer) - Hour (0-23)
- `min` (integer) - Minute (0-59)
- `sec` (integer) - Second (0-60)

**Returns:**

- integer - | nil UNIX epoch seconds, or nil on invalid input
- string - Error message when input is out of range

### parse_http

```teal
function parse_http(str: string): integer | nil, string
```

 Parse an HTTP date string (RFC 7231) into a UNIX timestamp.
 Accepts the IMF-fixdate format that format_http emits and that RFC 7231
 requires senders to generate (e.g. "Sun, 06 Nov 1994 08:49:37 GMT").
 The obsolete RFC 850 and asctime forms are not accepted.

**Parameters:**

- `str` (string) - HTTP date string

**Returns:**

- integer - | nil UNIX timestamp, or nil if parsing failed
- string - Error message on failure

### format_date

```teal
function format_date(timestamp: integer): string | nil, string
```

 Format a UNIX timestamp as a date string in UTC.

**Parameters:**

- `timestamp` (integer) - UNIX timestamp (seconds since epoch)

**Returns:**

- string - | nil Date string (e.g., "2025-01-01"), or nil on error
- string - Error message if formatting failed

### parse_date

```teal
function parse_date(str: string): integer | nil, string
```

 Parse a YYYY-MM-DD date string into a UNIX timestamp (midnight UTC).

**Parameters:**

- `str` (string) - Date string (e.g., "2025-01-01")

**Returns:**

- integer - | nil UNIX timestamp, or nil if parsing failed
- string - Error message on failure

### format_iso8601

```teal
function format_iso8601(timestamp: integer): string | nil, string
```

 Format a UNIX timestamp as an ISO 8601 string in UTC.

**Parameters:**

- `timestamp` (integer) - UNIX timestamp (seconds since epoch)

**Returns:**

- string - | nil ISO 8601 string (e.g., "2025-01-01T00:00:00Z"), or nil on error
- string - Error message if formatting failed

### parse_iso8601

```teal
function parse_iso8601(str: string): integer | nil, string
```

 Parse an ISO 8601 timestamp string into a UNIX epoch seconds value.
 Accepts full timestamps with a "Z" suffix, "±HH:MM"/"±HHMM"/"±HH" offsets,
 or no suffix (treated as UTC). Optional fractional seconds are accepted and
 truncated to whole seconds. Also accepts date-only "YYYY-MM-DD" (midnight
 UTC).

**Parameters:**

- `str` (string) - ISO 8601 string (e.g., "2025-01-01T00:00:00.5Z")

**Returns:**

- integer - | nil UNIX timestamp, or nil if parsing failed
- string - Error message on failure
