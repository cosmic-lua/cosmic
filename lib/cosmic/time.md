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
