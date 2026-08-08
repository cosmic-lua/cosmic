--- Instrumentation for timing and resource usage: wrap an operation in
--- a span, and get one structured `key=value` line per span on stderr
--- when `COSMIC_INSTRUMENTATION` is `1` or `true`.
---
--- Both halves are here on purpose. A span EMITS (`begin`/`finish`,
--- with `format_line` as the pure writer), and `parse_line`/
--- `parse_lines` READ what a child process emitted — which is how
--- `_tool.testrun` attributes wall time, CPU time and peak RSS to
--- each test it spawned. Emitting without a reader would make the
--- format a private convention between two files; both ends being
--- public is what makes it an interface. Field values use the shared
--- `key=value` grammar (`cosmic._fields`), the same one cosmic.log
--- renders with.
---
--- Public since 3h, and the caller set is what settled it: the CLI
--- dispatcher (`_cli/`) times every operation it runs, and lives
--- outside `cosmic/` now, so a module marked internal to `cosmic/`
--- could not answer it. Same rule as `cosmic.searcher` in 3g — who
--- requires a module decides whether it is internal.
local unix = require("cosmo.unix")
local env = require("cosmic.env")
local fields = require("cosmic._fields")

--- Parsed instrumentation data from a cosmic: line.
local record InstrumentData
  op: string
  file: string
  exit: integer
  wall_ms: integer
  cpu_ms: integer
  maxrss_kb: integer
end

--- A timing span capturing start state for an operation.
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

--- Check whether instrumentation is enabled.
--- Returns true when COSMIC_INSTRUMENTATION is "1" or "true".
--- @return boolean
local function is_enabled(): boolean
  local val = env.get("COSMIC_INSTRUMENTATION")
  return val == "1" or val == "true"
end

--- Begin a new instrumentation span.
--- Captures monotonic wall time and CPU usage at the start.
--- @param op string Operation name (e.g. "test", "compile", "check-types")
--- @param file string File being operated on
--- @return Span
local function begin_span(op: string, file: string): Span
  local wall_s, wall_ns = unix.clock_gettime(unix.CLOCK_MONOTONIC)
  local ru = unix.getrusage(unix.RUSAGE_SELF)
  local ut_s, ut_ns = 0.0, 0.0
  local st_s, st_ns = 0.0, 0.0
  if ru then
    local r = ru
    ut_s, ut_ns = r:utime()
    st_s, st_ns = r:stime()
  end
  return {
    op = op,
    file = file,
    start_wall = wall_s,
    start_wall_ns = wall_ns,
    start_utime_s = ut_s,
    start_utime_ns = ut_ns,
    start_stime_s = st_s,
    start_stime_ns = st_ns,
  }
end

--- Format an instrumentation line from measured data — the pure
--- inverse of parse_line. Field values are encoded with the shared
--- grammar, so a file path with a space or "%" round-trips whole.
--- @param data InstrumentData The measurement to render
--- @return string The formatted line, without a trailing newline
local function format_line(data: InstrumentData): string
  return string.format(
    "cosmic: op=%s file=%s exit=%d wall_ms=%d cpu_ms=%d maxrss_kb=%d",
    fields.encode(data.op), fields.encode(data.file), data.exit,
    data.wall_ms, data.cpu_ms, data.maxrss_kb)
end

--- Finish a span: measure, and emit when instrumentation is enabled.
--- Always returns the measured data — turning instrumentation off
--- stops the stderr line, not the measurement — so a caller can use
--- the numbers (or format_line them) regardless of the gate.
--- @param span Span The span from begin()
--- @param exit_code integer The exit code of the operation
--- @return InstrumentData The measured data for the span
local function finish_span(span: Span, exit_code: integer): InstrumentData
  local wall_s, wall_ns = unix.clock_gettime(unix.CLOCK_MONOTONIC)
  local ru = unix.getrusage(unix.RUSAGE_SELF)
  local ut_s, ut_ns = 0.0, 0.0
  local st_s, st_ns = 0.0, 0.0
  local maxrss = 0
  if ru then
    local r = ru
    ut_s, ut_ns = r:utime()
    st_s, st_ns = r:stime()
    maxrss = math.floor(r:maxrss()) as integer -- cast: number to integer
  end

  -- wall time delta in ms
  local wall_delta = (wall_s - span.start_wall) * 1000
  + (wall_ns - span.start_wall_ns) / 1000000
  local wall_ms = math.floor(wall_delta) as integer -- cast: number to integer

  -- cpu time delta in ms (utime + stime)
  local utime_delta = (ut_s - span.start_utime_s) * 1000
  + (ut_ns - span.start_utime_ns) / 1000000
  local stime_delta = (st_s - span.start_stime_s) * 1000
  + (st_ns - span.start_stime_ns) / 1000000
  -- cast: number to integer
  local cpu_ms = math.floor(utime_delta + stime_delta) as integer

  local data: InstrumentData = {
    op = span.op,
    file = span.file,
    exit = exit_code,
    wall_ms = wall_ms,
    cpu_ms = cpu_ms,
    maxrss_kb = maxrss,
  }

  if is_enabled() then
    io.stderr:write(format_line(data) .. "\n")
  end
  return data
end

--- Parse a single instrumentation line.
--- Returns nil if the line is not a valid cosmic: instrumentation line.
--- @param line string A line from stderr
--- @return InstrumentData?
local function parse_line(line: string): InstrumentData | nil
  if not line:match("^cosmic: ") then
    return nil
  end
  local op = line:match("op=(%S+)")
  local file = line:match("file=(%S+)")
  local exit_str = line:match("exit=(%d+)")
  local wall_str = line:match("wall_ms=(%d+)")
  local cpu_str = line:match("cpu_ms=(%d+)")
  local maxrss_str = line:match("maxrss_kb=(%d+)")
  if not op or not file or not exit_str then
    return nil
  end
  return {
    op = fields.decode(op),
    file = fields.decode(file),
    exit = (tonumber(exit_str) or 0) as integer, -- cast: number to integer
    wall_ms = (tonumber(wall_str) or 0) as integer, -- cast: number to integer
    cpu_ms = (tonumber(cpu_str) or 0) as integer, -- cast: number to integer
    maxrss_kb = (tonumber(maxrss_str) or 0) as integer, -- cast: number to integer
  }
end

--- Parse multiple lines of stderr, extracting instrumentation data.
--- @param content string Full stderr content
--- @return {InstrumentData}
local function parse_lines(content: string): {InstrumentData}
  local results: {InstrumentData} = {}
  for line in content:gmatch("[^\n]+") do
    local data = parse_line(line)
    if data then
      results[#results + 1] = data
    end
  end
  return results
end

local record InstrumentModule
  --- Exported so callers can name begin()'s and finish()'s results.
  type Span = Span
  type InstrumentData = InstrumentData

  is_enabled: function(): boolean
  begin: function(op: string, file: string): Span
  finish: function(span: Span, exit_code: integer): InstrumentData
  format_line: function(data: InstrumentData): string
  parse_line: function(line: string): InstrumentData | nil
  parse_lines: function(content: string): {InstrumentData}
end

local M: InstrumentModule = {
  is_enabled = is_enabled,
  begin = begin_span,
  finish = finish_span,
  format_line = format_line,
  parse_line = parse_line,
  parse_lines = parse_lines,
}

return M
