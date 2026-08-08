--- Examples for the cosmic.instrument module.
--- A span times one operation and emits a `cosmic: key=value` line to
--- stderr; the parser reads those lines back. The two ends are what
--- make the format an interface rather than a private convention, so
--- both are shown here.

-- Example_is_enabled demonstrates the gate. The stderr line is off
-- unless COSMIC_INSTRUMENTATION is exactly "1" or "true", so an unset
-- or unrecognised value costs nothing at runtime.
local function Example_is_enabled()
  local instrument = require("cosmic.instrument")
  local env = require("cosmic.env")
  assert(env.unset("COSMIC_INSTRUMENTATION"))
  print(instrument.is_enabled())
  assert(env.set("COSMIC_INSTRUMENTATION", "yes"))
  print(instrument.is_enabled())
  assert(env.set("COSMIC_INSTRUMENTATION", "1"))
  print(instrument.is_enabled())
  assert(env.unset("COSMIC_INSTRUMENTATION"))
  -- Output:
  -- false
  -- false
  -- true
end

-- Example_span demonstrates timing an operation. finish() always
-- returns the measured data — the gate controls only the stderr line —
-- so a caller can use the numbers (or format_line them) without
-- checking the gate itself.
local function Example_span()
  local instrument = require("cosmic.instrument")
  local env = require("cosmic.env")
  assert(env.unset("COSMIC_INSTRUMENTATION"))
  local span = instrument.begin("compile", "hello.tl")
  local data = instrument.finish(span, 0)
  print(data.op, data.file, data.exit)
  -- Output:
  -- compile	hello.tl	0
end

-- Example_format_line demonstrates the pure writer half: format_line
-- renders measured data as the one-line format parse_line reads back.
local function Example_format_line()
  local instrument = require("cosmic.instrument")
  local check = require("cosmic.check")
  local line = instrument.format_line({
      op = "test",
      file = "fs_test.tl",
      exit = 0,
      wall_ms = 42,
      cpu_ms = 37,
      maxrss_kb = 8192,
    })
  print(line)
  local data = check.must(instrument.parse_line(line))
  print(data.op, data.wall_ms)
  -- Output:
  -- cosmic: op=test file=fs_test.tl exit=0 wall_ms=42 cpu_ms=37 maxrss_kb=8192
  -- test	42
end

-- Example_parse demonstrates reading instrumentation back. This is how
-- the build test runner attributes wall time, CPU time and peak memory to each
-- test it spawned: the child emits, the parent parses its stderr.
local function Example_parse()
  local instrument = require("cosmic.instrument")
  local check = require("cosmic.check")
  local data = check.must(instrument.parse_line(
      "cosmic: op=test file=fs_test.tl exit=0 wall_ms=42 cpu_ms=37 maxrss_kb=8192"))
  print(data.op, data.file, data.exit, data.wall_ms, data.maxrss_kb)
  print(instrument.parse_line("ordinary stderr output"))
  -- Output:
  -- test	fs_test.tl	0	42	8192
  -- nil
end

-- Example_parse_lines demonstrates extracting every measurement from a
-- captured stderr stream, ignoring everything that is not one.
local function Example_parse_lines()
  local instrument = require("cosmic.instrument")
  local stderr = table.concat({
      "warning: something happened",
      "cosmic: op=compile file=a.tl exit=0 wall_ms=10 cpu_ms=9 maxrss_kb=1024",
      "cosmic: op=compile file=b.tl exit=1 wall_ms=20 cpu_ms=18 maxrss_kb=2048",
    }, "\n")
  local all = instrument.parse_lines(stderr)
  print(#all)
  for _, d in ipairs(all) do
    print(d.file, d.exit)
  end
  -- Output:
  -- 2
  -- a.tl	0
  -- b.tl	1
end

-- Suppress unused warnings for examples
local _ = {Example_is_enabled, Example_span, Example_format_line,
  Example_parse, Example_parse_lines}
