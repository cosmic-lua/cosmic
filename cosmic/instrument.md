# instrument

 Instrumentation for timing and resource usage: wrap an operation in
 a span, and get one structured `key=value` line per span on stderr
 when `COSMIC_INSTRUMENTATION` is `1` or `true`.

 Both halves are here on purpose. A span EMITS (`begin`/`finish`),
 and `parse_line`/`parse_lines` READ what a child process emitted —
 which is how `cosmic.testrun` attributes wall time, CPU time and
 peak RSS to each test it spawned. Emitting without a reader would
 make the format a private convention between two files; both ends
 being here is what makes it an interface.

 Public since 3h, and the caller set is what settled it: the CLI
 dispatcher (`_cli/`) times every operation it runs, and lives
 outside `cosmic/` now, so a module marked internal to `cosmic/`
 could not answer it. Same rule as `cosmic.searcher` in 3g — who
 requires a module decides whether it is internal.

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
