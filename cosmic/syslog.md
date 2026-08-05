# syslog

 System logging.
 Wraps unix.syslog() for writing to the system log. The severity is
 a string enum (api-review-8: was eight LOG_* integer constants plus
 eight per-level wrapper functions) — one write(), with the level
 named in words, like cosmic.log.

## Types

### SyslogModule

```teal
local record SyslogModule
  write: function(level: Level, message: string)
end
```

## Functions

### write

```teal
function write(level: Level, message: string)
```

 Write a message to the system log.
 "error" | "warning" | "notice" | "info" | "debug"

**Parameters:**

- `level` (Level) - Severity: "emergency" | "alert" | "critical" |
- `message` (string) - The message to log
