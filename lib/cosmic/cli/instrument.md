# instrument

 CLI instrumentation for timing and resource usage.
 Emits structured key=value lines to stderr when COSMIC_INSTRUMENTATION
 is set to "1" or "true". Used by main_handlers and testrun to report
 wall time, CPU time, and peak memory for each operation.

## Types

### InstrumentData

 Parsed instrumentation data from a cosmic: line.

```teal
local record InstrumentData
  op: string
  file: string
  exit: integer
  wall_ms: integer
  cpu_ms: integer
  maxrss_kb: integer
end
```

### Span

 A timing span capturing start state for an operation.

```teal
local record Span
  op: string
  file: string
  start_wall: number
  start_wall_ns: number
  start_utime_s: number
  start_utime_ns: number
  start_stime_s: number
  start_stime_ns: number
end
```

### InstrumentModule

```teal
local record InstrumentModule
  enabled: function(): boolean
  begin: function(op: string, file: string): Span
  finish: function(span: Span, exit_code: integer): string
  parse_line: function(line: string): InstrumentData
  parse_lines: function(content: string): {InstrumentData}
end
```

## Functions

### parse_line

```teal
function parse_line(line: string): InstrumentData
```

 Parse a single instrumentation line.
 Returns nil if the line is not a valid cosmic: instrumentation line.

**Parameters:**

- `line` (string) - A line from stderr

**Returns:**

- InstrumentData?

### parse_lines

```teal
function parse_lines(content: string): {InstrumentData}
```

 Parse multiple lines of stderr, extracting instrumentation data.

**Parameters:**

- `content` (string) - Full stderr content

**Returns:**

- {InstrumentData}
