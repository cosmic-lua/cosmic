--- Examples for the cosmic.instrument module.
--- A span times one operation and emits a `cosmic: key=value` line to
--- stderr; the parser reads those lines back. The two ends are what
--- make the format an interface rather than a private convention, so
--- both are shown here.

-- Example_enabled demonstrates the gate. Instrumentation is off unless
-- COSMIC_INSTRUMENTATION is exactly "1" or "true", so an unset or
-- unrecognised value costs nothing at runtime.
local function Example_enabled()
  local instrument = require("cosmic.instrument")
  local env = require("cosmic.env")
  assert(env.unset("COSMIC_INSTRUMENTATION"))
  print(instrument.enabled())
  assert(env.set("COSMIC_INSTRUMENTATION", "yes"))
  print(instrument.enabled())
  assert(env.set("COSMIC_INSTRUMENTATION", "1"))
  print(instrument.enabled())
  assert(env.unset("COSMIC_INSTRUMENTATION"))
  -- Output:
  -- false
  -- false
  -- true
end

-- Example_span demonstrates timing an operation. finish() returns the
-- line it wrote when instrumentation is enabled, and nil when it is
-- not — so a caller can hand every operation a span without checking
-- the gate itself.
local function Example_span()
  local instrument = require("cosmic.instrument")
  local env = require("cosmic.env")
  assert(env.unset("COSMIC_INSTRUMENTATION"))
  local quiet = instrument.begin("compile", "hello.tl")
  print(instrument.finish(quiet, 0))
  -- Output:
  -- nil
end

-- Example_parse demonstrates reading instrumentation back. This is how
-- cosmic.testrun attributes wall time, CPU time and peak memory to each
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
local _ = {Example_enabled, Example_span, Example_parse, Example_parse_lines}
