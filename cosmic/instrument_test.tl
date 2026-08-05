#!/usr/bin/env cosmic
local instrument = require("cosmic.instrument")
local check = require("cosmic.check")
local env = require("cosmic.env")
local time = require("cosmic.time")

-- test Span record fields

local function test_begin_returns_span()
  local span = instrument.begin("test", "cosmic/foo_test.tl")
  assert(span ~= nil, "expected span")
  assert(span.op == "test", "expected op=test, got " .. tostring(span.op))
  assert(span.file == "cosmic/foo_test.tl",
    "expected file, got " .. tostring(span.file))
  assert(span.start_wall > 0, "expected positive start_wall")
end
test_begin_returns_span()

-- test finish emits nothing when COSMIC_INSTRUMENTATION is unset

local function test_finish_silent_by_default()
  env.unset("COSMIC_INSTRUMENTATION")
  local span = instrument.begin("compile", "test.tl")
  -- finish should return the line but not write to stderr when disabled
  local line = instrument.finish(span, 0)
  assert(line == nil, "expected nil when instrumentation disabled, got: " .. tostring(line))
end
test_finish_silent_by_default()

-- test finish returns formatted line when COSMIC_INSTRUMENTATION=1

local function test_finish_returns_line_when_enabled()
  env.set("COSMIC_INSTRUMENTATION", "1")
  local span = instrument.begin("check-types", "cosmic/fs.tl")
  time.sleep(0, 1000000) -- sleep 1ms to get measurable time
  local line = check.must(instrument.finish(span, 0))
  env.unset("COSMIC_INSTRUMENTATION")
  assert(line ~= nil, "expected instrumentation line")
  assert(line:match("^cosmic:"), "expected 'cosmic:' prefix, got: " .. line)
  assert(line:match("op=check%-types"), "expected op=check-types in: " .. line)
  assert(line:match("file=cosmic/fs%.tl"), "expected file= in: " .. line)
  assert(line:match("exit=0"), "expected exit=0 in: " .. line)
  assert(line:match("wall_ms=%d+"), "expected wall_ms= in: " .. line)
end
test_finish_returns_line_when_enabled()

-- test finish captures cpu_ms

local function test_finish_includes_cpu_ms()
  env.set("COSMIC_INSTRUMENTATION", "1")
  local span = instrument.begin("test", "x.tl")
  -- do some cpu work
  local sum = 0
  for i = 1, 10000 do sum = sum + i end
  local _ = sum
  local line = check.must(instrument.finish(span, 0))
  env.unset("COSMIC_INSTRUMENTATION")
  assert(line ~= nil, "expected line")
  assert(line:match("cpu_ms=%d+"), "expected cpu_ms= in: " .. line)
end
test_finish_includes_cpu_ms()

-- test finish captures maxrss_kb

local function test_finish_includes_maxrss()
  env.set("COSMIC_INSTRUMENTATION", "1")
  local span = instrument.begin("test", "x.tl")
  local line = check.must(instrument.finish(span, 0))
  env.unset("COSMIC_INSTRUMENTATION")
  assert(line ~= nil, "expected line")
  assert(line:match("maxrss_kb=%d+"), "expected maxrss_kb= in: " .. line)
end
test_finish_includes_maxrss()

-- test finish with non-zero exit code

local function test_finish_nonzero_exit()
  env.set("COSMIC_INSTRUMENTATION", "1")
  local span = instrument.begin("compile", "bad.tl")
  local line = check.must(instrument.finish(span, 1))
  env.unset("COSMIC_INSTRUMENTATION")
  assert(line ~= nil, "expected line")
  assert(line:match("exit=1"), "expected exit=1 in: " .. line)
end
test_finish_nonzero_exit()

-- test enabled() reflects env var

local function test_enabled()
  env.unset("COSMIC_INSTRUMENTATION")
  assert(not instrument.enabled(), "expected disabled when unset")
  env.set("COSMIC_INSTRUMENTATION", "1")
  assert(instrument.enabled(), "expected enabled when set to 1")
  env.set("COSMIC_INSTRUMENTATION", "0")
  assert(not instrument.enabled(), "expected disabled when set to 0")
  env.set("COSMIC_INSTRUMENTATION", "true")
  assert(instrument.enabled(), "expected enabled when set to true")
  env.unset("COSMIC_INSTRUMENTATION")
end
test_enabled()

-- test parse_line round-trips

local function test_parse_line()
  env.set("COSMIC_INSTRUMENTATION", "1")
  local span = instrument.begin("test", "cosmic/sqlite_test.tl")
  time.sleep(0, 1000000)
  local line = check.must(instrument.finish(span, 0))
  env.unset("COSMIC_INSTRUMENTATION")
  assert(line ~= nil, "expected line")
  local parsed = check.must(instrument.parse_line(line), "expected parsed result")
  assert(parsed.op == "test", "expected op=test, got " .. tostring(parsed.op))
  assert(parsed.file == "cosmic/sqlite_test.tl",
    "expected file, got " .. tostring(parsed.file))
  assert(parsed.exit == 0, "expected exit=0, got " .. tostring(parsed.exit))
  assert(parsed.wall_ms >= 0, "expected wall_ms >= 0")
  assert(parsed.cpu_ms >= 0, "expected cpu_ms >= 0")
  assert(parsed.maxrss_kb > 0, "expected maxrss_kb > 0")
end
test_parse_line()

-- test parse_line returns nil for non-instrument lines

local function test_parse_line_non_instrument()
  local parsed = instrument.parse_line("some random stderr output")
  assert(parsed == nil, "expected nil for non-instrument line")
  parsed = instrument.parse_line("")
  assert(parsed == nil, "expected nil for empty line")
end
test_parse_line_non_instrument()

-- test parse_lines extracts from mixed stderr content

local function test_parse_lines()
  local stderr = "some warning\n"
  .. "cosmic: op=test file=a.tl exit=0 wall_ms=100 cpu_ms=90 maxrss_kb=1024\n"
  .. "another line\n"
  .. "cosmic: op=compile file=b.tl exit=1 wall_ms=50 cpu_ms=45 maxrss_kb=2048\n"
  local results = instrument.parse_lines(stderr)
  assert(#results == 2, "expected 2 results, got " .. #results)
  assert(results[1].op == "test", "expected op=test")
  assert(results[1].file == "a.tl", "expected file=a.tl")
  assert(results[2].op == "compile", "expected op=compile")
  assert(results[2].exit == 1, "expected exit=1")
end
test_parse_lines()

-- A file path with a space must round-trip whole: the line format is
-- space-delimited key=value pairs and parse_line reads each value back
-- with a non-space (%S+) pattern, so an unescaped space in a path
-- would silently truncate it at parse time.
local function test_file_with_space_round_trips()
  env.set("COSMIC_INSTRUMENTATION", "1")
  local span = instrument.begin("test", "cosmic/my file.tl")
  local line = check.must(instrument.finish(span, 0))
  env.unset("COSMIC_INSTRUMENTATION")
  assert(line ~= nil, "expected line")
  local parsed = check.must(instrument.parse_line(line), "expected parsed result")
  assert(parsed.file == "cosmic/my file.tl",
    "expected the space to survive round-trip, got: " .. tostring(parsed.file))
  -- The line itself must have no unescaped space inside the file field,
  -- or the %S+ parse would still see it as two tokens.
  assert(line:find(" ", 1, true) ~= nil, "sanity: the line has spaces (the delimiters)")
  assert(not line:find("my file.tl", 1, true),
    "the raw space must not appear verbatim in the emitted line: " .. line)
end
test_file_with_space_round_trips()

-- A literal "%" in a path must also round-trip, and must not be
-- misinterpreted as an escape sequence introduced by escape_field.
local function test_file_with_percent_round_trips()
  env.set("COSMIC_INSTRUMENTATION", "1")
  local span = instrument.begin("test", "cosmic/100%.tl")
  local line = check.must(instrument.finish(span, 0))
  env.unset("COSMIC_INSTRUMENTATION")
  assert(line ~= nil, "expected line")
  local parsed = check.must(instrument.parse_line(line), "expected parsed result")
  assert(parsed.file == "cosmic/100%.tl",
    "expected the percent to survive round-trip, got: " .. tostring(parsed.file))
end
test_file_with_percent_round_trips()
