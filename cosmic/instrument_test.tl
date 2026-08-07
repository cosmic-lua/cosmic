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

-- finish always measures: with instrumentation off it still returns
-- the data (it just writes no stderr line).

local function test_finish_measures_when_disabled()
  assert(env.unset("COSMIC_INSTRUMENTATION"))
  local span = instrument.begin("compile", "test.tl")
  local data = instrument.finish(span, 0)
  assert(data ~= nil, "expected data even when instrumentation is off")
  assert(data.op == "compile", "expected op=compile, got " .. tostring(data.op))
  assert(data.file == "test.tl", "expected file, got " .. tostring(data.file))
  assert(data.exit == 0, "expected exit=0")
  assert(data.wall_ms >= 0, "expected wall_ms >= 0")
end
test_finish_measures_when_disabled()

-- test finish data formats to a line via format_line

local function test_finish_and_format_line()
  local span = instrument.begin("check-types", "cosmic/fs.tl")
  assert(time.sleep(0, 1000000)) -- sleep 1ms to get measurable time
  local data = instrument.finish(span, 0)
  local line = instrument.format_line(data)
  assert(line:match("^cosmic:"), "expected 'cosmic:' prefix, got: " .. line)
  assert(line:match("op=check%-types"), "expected op=check-types in: " .. line)
  assert(line:match("file=cosmic/fs%.tl"), "expected file= in: " .. line)
  assert(line:match("exit=0"), "expected exit=0 in: " .. line)
  assert(line:match("wall_ms=%d+"), "expected wall_ms= in: " .. line)
end
test_finish_and_format_line()

-- test finish captures cpu_ms and maxrss_kb

local function test_finish_includes_cpu_and_maxrss()
  local span = instrument.begin("test", "x.tl")
  -- do some cpu work
  local sum = 0
  for i = 1, 10000 do sum = sum + i end
  local _ = sum
  local data = instrument.finish(span, 0)
  assert(data.cpu_ms >= 0, "expected cpu_ms >= 0")
  assert(data.maxrss_kb > 0, "expected maxrss_kb > 0")
end
test_finish_includes_cpu_and_maxrss()

-- test finish with non-zero exit code

local function test_finish_nonzero_exit()
  local span = instrument.begin("compile", "bad.tl")
  local data = instrument.finish(span, 1)
  assert(data.exit == 1, "expected exit=1, got " .. tostring(data.exit))
end
test_finish_nonzero_exit()

-- test is_enabled() reflects env var

local function test_is_enabled()
  assert(env.unset("COSMIC_INSTRUMENTATION"))
  assert(not instrument.is_enabled(), "expected disabled when unset")
  assert(env.set("COSMIC_INSTRUMENTATION", "1"))
  assert(instrument.is_enabled(), "expected enabled when set to 1")
  assert(env.set("COSMIC_INSTRUMENTATION", "0"))
  assert(not instrument.is_enabled(), "expected disabled when set to 0")
  assert(env.set("COSMIC_INSTRUMENTATION", "true"))
  assert(instrument.is_enabled(), "expected enabled when set to true")
  assert(env.unset("COSMIC_INSTRUMENTATION"))
end
test_is_enabled()

-- test format_line/parse_line round-trip on real measured data

local function test_round_trip()
  local span = instrument.begin("test", "cosmic/sqlite_test.tl")
  assert(time.sleep(0, 1000000))
  local data = instrument.finish(span, 0)
  local line = instrument.format_line(data)
  local parsed = check.must(instrument.parse_line(line), "expected parsed result")
  assert(parsed.op == "test", "expected op=test, got " .. tostring(parsed.op))
  assert(parsed.file == "cosmic/sqlite_test.tl",
    "expected file, got " .. tostring(parsed.file))
  assert(parsed.exit == 0, "expected exit=0, got " .. tostring(parsed.exit))
  assert(parsed.wall_ms == data.wall_ms, "wall_ms must round-trip exactly")
  assert(parsed.cpu_ms == data.cpu_ms, "cpu_ms must round-trip exactly")
  assert(parsed.maxrss_kb == data.maxrss_kb, "maxrss_kb must round-trip exactly")
end
test_round_trip()

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
  local span = instrument.begin("test", "cosmic/my file.tl")
  local line = instrument.format_line(instrument.finish(span, 0))
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
-- misinterpreted as an escape sequence introduced by the encoder.
local function test_file_with_percent_round_trips()
  local span = instrument.begin("test", "cosmic/100%.tl")
  local line = instrument.format_line(instrument.finish(span, 0))
  local parsed = check.must(instrument.parse_line(line), "expected parsed result")
  assert(parsed.file == "cosmic/100%.tl",
    "expected the percent to survive round-trip, got: " .. tostring(parsed.file))
end
test_file_with_percent_round_trips()

-- The emitted stderr line is gated on COSMIC_INSTRUMENTATION, and it
-- is exactly format_line of the returned data.
local function test_emission_gated_on_env()
  assert(env.set("COSMIC_INSTRUMENTATION", "1"))
  local span = instrument.begin("test", "gated.tl")
  local data = instrument.finish(span, 0)
  assert(env.unset("COSMIC_INSTRUMENTATION"))
  local line = instrument.format_line(data)
  assert(line:find("file=gated.tl", 1, true), "got: " .. line)
end
test_emission_gated_on_env()
