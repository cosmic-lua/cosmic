# log

 Leveled logging.
 A small structured logger for scripts and services: four severity
 levels, a module-wide threshold, and optional key=value fields per
 line. Lines go to stderr by default; redirect with set_output (for
 tests, or to ship lines elsewhere). For writing to the system log
 daemon instead, see cosmic.syslog.

 Example usage:
   local log = require("cosmic.log")
   log.info("server started", {port = 8080})
   log.set_level("debug")
   log.debug("cache miss", {key = "user:42"})

 Line format: `<iso8601-utc> <LEVEL> <message> <key=value ...>` with
 fields sorted by key so output is deterministic. Logging is
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
  warn: function(message: string, fields?: {string: any})
  error: function(message: string, fields?: {string: any})
  format: function(level: Level, message: string, fields?: {string: any}): string
  set_level: function(level: Level): boolean, string
  level: function(): Level
  set_output: function(out?: function(line: string))
end
```

## Functions

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
 table lookup) when the level ranks below the current threshold.

**Parameters:**

- `level` (Level) - The severity level
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

### warn

```teal
function warn(message: string, fields?: {string: any})
```

 Log a warning message.

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
function set_output(out?: function(line: string))
```

 Redirect where formatted lines go. The function receives each line
 without a trailing newline. Call with no argument to restore the
 default stderr output.

**Parameters:**

- `out` (function(line:) - string)? The new output, or nil for stderr
