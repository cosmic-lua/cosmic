# log

 Leveled logging.
 A small structured logger for scripts and services: four severity
 levels, a module-wide threshold, and optional key=value fields per
 line. Lines go to stderr by default; redirect with set_output (for
 tests, or to ship lines elsewhere). To write to the system log
 daemon instead, install the bundled sink:
 log.set_output(log.syslog_output).

 Example usage:
   local log = require("cosmic.log")
   log.info("server started", {port = 8080})
   log.set_level("debug")
   log.debug("cache miss", {key = "user:42"})

 Line format: `<iso8601-utc> <LEVEL> <message> <key=value ...>` with
 fields sorted by key so output is deterministic. Field values use
 the shared `key=value` grammar (`cosmic._fields`) — the same one
 cosmic.instrument emits and parses, so instrument.parse-style
 readers and `grep key=value` both work on log output: a value
 never contains a bare space or newline. Logging is
 infallible: emitters return nothing and never throw; a message
 below the threshold costs one map lookup and no formatting.

 The initial threshold is "info", or the value of the
 COSMIC_LOG_LEVEL environment variable when it names a valid level.

 Reserved names: log.with(fields): Logger (a child logger carrying
 context fields) and log.new(options): Logger (independent logger
 instances) are reserved for a post-stable battery. Do not reuse
 these names for anything else.

## Types

### LogModule

```teal
local record LogModule
  log: function(level: Level, message: string, fields?: {string: any})
  debug: function(message: string, fields?: {string: any})
  info: function(message: string, fields?: {string: any})
  warning: function(message: string, fields?: {string: any})
  error: function(message: string, fields?: {string: any})
  format: function(level: Level, message: string, fields?: {string: any}): string
  set_level: function(level: Level): boolean, string
  level: function(): Level
  set_output: function(out?: Sink)
  syslog_output: Sink
end
```

### Sink

 An output sink: receives each formatted line (without a trailing
 newline) together with its severity, so a destination that speaks
 severities — the system log, a filtering shim — need not re-parse
 the line. A sink that only wants the line just takes one parameter.

alias of `function`

## Functions

### syslog_output

```teal
function syslog_output(line: string, level: Level)
```

 An output sink that writes each line to the system log daemon.
 Install with log.set_output(log.syslog_output). The level maps onto the RFC
 5424 wire severity (debug=7, info=6, warning=4, error=3); delivery
 is whatever the host does with syslog(3) — syslogd on Linux and
 NetBSD, ReportEvent() on Windows, silently dropped elsewhere. An
 unknown level smuggled in through a cast is dropped rather than
 thrown (never throw from library code; mirrors log()).

**Parameters:**

- `line` (string) - The formatted log line
- `level` (Level) - The line's severity

### format

```teal
function format(level: Level, message: string, fields?: {string: any}): string
```

 Format a log line without emitting it. Exposed so custom outputs
 and tests can reuse the exact format. The timestamp is the current
 UTC time in ISO 8601; fields are rendered sorted by key.

**Parameters:**

- `level` (Level) - The severity level
- `message` (string) - The log message
- `fields` ({string:any}?) - Optional key=value context fields

**Returns:**

- string - The formatted line, without a trailing newline

### log

```teal
function log(level: Level, message: string, fields?: {string: any})
```

 Log a message at the given level. Suppressed (at the cost of one
 table lookup) when the level ranks below the current threshold. An
 unknown level (a runtime string smuggled in through a cast) is also
 suppressed rather than thrown: severity[level] would be nil, and
 `nil < number` throws (never throw from library code; mirrors set_level).

**Parameters:**

- `level` (Level) - The severity level
- `message` (string) - The log message
- `fields` ({string:any}?) - Optional key=value context fields

### debug

```teal
function debug(message: string, fields?: {string: any})
```

 Log a debug message (suppressed unless the threshold is "debug").

**Parameters:**

- `message` (string) - The log message
- `fields` ({string:any}?) - Optional key=value context fields

### info

```teal
function info(message: string, fields?: {string: any})
```

 Log an informational message.

**Parameters:**

- `message` (string) - The log message
- `fields` ({string:any}?) - Optional key=value context fields

### warning

```teal
function warning(message: string, fields?: {string: any})
```

 Log a warning message.

**Parameters:**

- `message` (string) - The log message
- `fields` ({string:any}?) - Optional key=value context fields

### error

```teal
function error(message: string, fields?: {string: any})
```

 Log an error message.

**Parameters:**

- `message` (string) - The log message
- `fields` ({string:any}?) - Optional key=value context fields

### set_level

```teal
function set_level(level: Level): boolean, string
```

 Set the minimum level that gets emitted. The Level enum checks
 literals statically; runtime strings smuggled in through casts get
 false, err rather than corrupting the threshold (never throw from
 library code).

**Parameters:**

- `level` (Level) - The new threshold

**Returns:**

- boolean - True when the threshold was set
- string? - Error message when the level is not a valid Level

### level

```teal
function level(): Level
```

 Get the current minimum level.

**Returns:**

- Level - The current threshold

### set_output

```teal
function set_output(out?: Sink)
```

 Redirect where formatted lines go. The sink receives each line
 without a trailing newline, plus the line's level. Call with no
 argument to restore the default stderr output.

**Parameters:**

- `out` (Sink?) - The new output, or nil for stderr
