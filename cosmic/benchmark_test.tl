#!/usr/bin/env cosmic
-- test cosmic.benchmark module

local check = require("cosmic.check")
local fs = require("cosmic.fs")
local spawn = require("cosmic.child")
local benchmark = require("cosmic.benchmark")
local env = require("cosmic.env")

local cosmic = fs.join(os.getenv("TEST_BIN"), "cosmic")
local tmpdir = os.getenv("TEST_TMPDIR")

-- This file exercises the RUNNER (discovery, naming, iteration counting,
-- formatting, error handling, selection) through real Benchmark_* runs,
-- not the quality of any one timing. Go-style calibration toward
-- DEFAULT_MIN_SECONDS (~1s) would cost ~1s per real benchmark run below
-- for no assertion this shrinks: a tiny floor proves the runner works
-- exactly as well at 10ms as at 1s. Direct benchmark.run() calls get
-- an explicit Options.min_seconds; the two tests that spawn `cosmic
-- --benchmark` as a child (which has no Options to pass) instead set
-- COSMIC_BENCHMARK_MIN_SECONDS here so the child inherits it.
local TINY_SECONDS = 0.01
local TINY: benchmark.Options = {min_seconds = TINY_SECONDS}
check.must(env.set("COSMIC_BENCHMARK_MIN_SECONDS", tostring(TINY_SECONDS)))

local function write_temp(name: string, content: string): string
  local filepath = fs.join(tmpdir, name)
  fs.write(filepath, content)
  return filepath
end

-- Test parsing benchmarks from source
local function test_parse_benchmarks()
  local source = [[
local function Benchmark_basic()
  local x = 1 + 1
end
]]

  local benchmarks = benchmark.parse_benchmarks(source)
  assert(#benchmarks == 1, "should find one benchmark")
  assert(benchmarks[1].name == "Benchmark_basic", "name should match")
end
test_parse_benchmarks()

-- Test parsing multiple benchmarks
local function test_parse_multiple_benchmarks()
  local source = [[
local function Benchmark_first()
  local x = 1
end

local function Benchmark_second()
  local y = 2
end
]]

  local benchmarks = benchmark.parse_benchmarks(source)
  assert(#benchmarks == 2, "should find two benchmarks")
  assert(benchmarks[1].name == "Benchmark_first", "first benchmark name")
  assert(benchmarks[2].name == "Benchmark_second", "second benchmark name")
end
test_parse_multiple_benchmarks()

-- Test running benchmark
local function test_run_benchmark()
  local input = write_temp("bench.tl", [[
local function Benchmark_add()
  local x = 1 + 1
end
]])
  local result = benchmark.run(input, nil, TINY)
  assert(result.exit_code == 0, "should pass")
  assert(#result.results == 1, "should have one result")
  assert(result.results[1].iterations > 0, "should have iterations")
  assert(result.results[1].ns_per_op > 0, "should have timing")
end
test_run_benchmark()

-- Test file with no benchmarks (skip)
local function test_run_no_benchmarks()
  local input = write_temp("none_bench.tl", [[
local function regular_function()
  return 42
end
]])
  local result = benchmark.run(input)
  assert(result.exit_code == 2, "should return skip code")
  assert(#result.results == 0, "should have no results")
end
test_run_no_benchmarks()

-- Test missing file
local function test_run_missing_file()
  local result = benchmark.run("/nonexistent/file.tl")
  assert(result.exit_code == 1, "should fail")
  assert(result.error:find("cannot open"), "should have error message")
end
test_run_missing_file()

-- Test cosmic --benchmark command
local function test_cosmic_benchmark()
  local input = write_temp("cmd_bench.tl", [[
local function Benchmark_cmd()
  local x = 1 + 1
end
]])
  local h1 = check.must(spawn.spawn({cosmic, "--benchmark", input}))
  local __r1 = check.must(h1:wait())
  local ok, out = __r1.ok, __r1.stdout
  assert(ok, "cosmic --benchmark should succeed")
  assert(out:find("Benchmark_cmd"), "output should contain benchmark name")
  assert(out:find("ns/op") or out:find("µs/op") or out:find("ms/op"), "output should show timing")
end
test_cosmic_benchmark()

-- Test cosmic --benchmark with skip
local function test_cosmic_benchmark_skip()
  local input = write_temp("cmd_bench_skip.tl", [[
local x = 1
]])
  local r = check.must(spawn.run({cosmic, "--benchmark", input}))
  assert(r.code == 2, "should return skip code 2")
  assert(r.stdout:find("SKIP"), "output should show SKIP")
end
test_cosmic_benchmark_skip()

-- Test benchmark with nested blocks
local function test_nested_blocks()
  local input = write_temp("nested_bench.tl", [[
local function Benchmark_nested()
  for i = 1, 10 do
    if i > 5 then
      local x = i * 2
    end
  end
end
]])
  local result = benchmark.run(input, nil, TINY)
  assert(result.exit_code == 0, "should handle nested blocks")
  assert(result.results[1].iterations > 0, "should run iterations")
end
test_nested_blocks()

-- Test format_results output
local function test_format_results()
  local input = write_temp("format_bench.tl", [[
local function Benchmark_fmt()
  local x = 1
end
]])
  local result = benchmark.run(input, nil, TINY)
  local formatted = benchmark.format_results(input, result)
  assert(formatted:find("Benchmark_fmt"), "should contain benchmark name")
  assert(formatted:find("PASS"), "should show PASS status")
end
test_format_results()

-- Test benchmark with runtime error
local function test_runtime_error()
  local input = write_temp("error_bench.tl", [[
local function Benchmark_error()
  error("intentional error")
end
]])
  local result = benchmark.run(input, nil, TINY)
  assert(result.exit_code == 1, "should fail on runtime error")
  assert(result.results[1].error:find("runtime error"), "should capture error")
end
test_runtime_error()

-- Test filter: run specific benchmark by pattern
local function test_filter_matching()
  local input = write_temp("filter_bench.tl", [[
local function Benchmark_string_concat()
  local s = "a" .. "b"
end

local function Benchmark_table_insert()
  local t = {}
  t[1] = "x"
end

local function Benchmark_math_add()
  local x = 1 + 2
end
]])
  -- Filter to only run "string" benchmarks
  local result = benchmark.run(input, "string", TINY)
  assert(result.exit_code == 0, "should pass")
  assert(#result.results == 1, "should run only one benchmark")
  assert(result.results[1].name == "Benchmark_string_concat", "should run matching benchmark")
end
test_filter_matching()

-- Test filter: no benchmarks match
local function test_filter_no_match()
  local input = write_temp("filter_nomatch.tl", [[
local function Benchmark_foo()
  local x = 1
end
]])
  local result = benchmark.run(input, "nonexistent")
  assert(result.exit_code == 2, "should return skip code")
  assert(result.error:find("no benchmarks matching"), "should show filter error")
end
test_filter_no_match()

-- Test that a variable/local named with a keyword prefix (`end_time`)
-- is not lexed as the keyword `end`: a bare `%a+` word match stops at
-- the `_`, so the scanner used to close the body right there.
local function test_end_time_not_truncated()
  local source = [[
local function Benchmark_time_tracking()
  local start_time = 1
  local end_time = 2
  local elapsed = end_time - start_time
end
]]
  local benchmarks = benchmark.parse_benchmarks(source)
  assert(#benchmarks == 1, "should find one benchmark")
  assert(benchmarks[1].body:find("elapsed", 1, true),
    "body should include the statement after end_time, not stop early")
end
test_end_time_not_truncated()

-- Test that a variable named with a block-opening keyword prefix
-- (`for_each`) is not lexed as `for`: that would open a phantom nesting
-- level, needing an extra `end` to close and swallowing whatever
-- benchmark comes next.
local function test_for_each_prefix_not_over_extended()
  local source = [[
local function Benchmark_for_each()
  local for_each = function(t) return #t end
  local n = for_each({1, 2, 3})
end

local function Benchmark_after_for_each()
  local x = 1
end
]]
  local benchmarks = benchmark.parse_benchmarks(source)
  assert(#benchmarks == 2, "should find two separate benchmarks, not merge them")
  assert(benchmarks[1].name == "Benchmark_for_each", "first benchmark name")
  assert(benchmarks[2].name == "Benchmark_after_for_each", "second benchmark name")
  assert(not benchmarks[1].body:find("Benchmark_after_for_each", 1, true),
    "for_each's body must not swallow the next benchmark")
end
test_for_each_prefix_not_over_extended()

-- Test that a bare `do ... end` block (not attached to a for/while)
-- opens its own nesting level: `do` was missing from the depth-tracking
-- keyword set, so its `end` was mistaken for the function's own.
local function test_bare_do_end_block()
  local source = [[
local function Benchmark_bare_do()
  do
    local x = 1
  end
  local y = 2
end

local function Benchmark_after_do()
  local z = 3
end
]]
  local benchmarks = benchmark.parse_benchmarks(source)
  assert(#benchmarks == 2, "should find two benchmarks")
  assert(benchmarks[1].body:find("y = 2", 1, true),
    "body should include the statement after the bare do-block")
  assert(benchmarks[2].name == "Benchmark_after_do", "next benchmark parsed separately")
end
test_bare_do_end_block()

-- Test a nested (anonymous) function definition inside the benchmark
-- body: unaffected by either bug, but a regression guard for the
-- shared scanner now that all three extractors share it.
local function test_nested_function_definition()
  local source = [[
local function Benchmark_nested_fn()
  local adder = function(a, b)
    return a + b
  end
  local result = adder(1, 2)
end
]]
  local benchmarks = benchmark.parse_benchmarks(source)
  assert(#benchmarks == 1, "should find one benchmark")
  assert(benchmarks[1].body:find("result", 1, true),
    "body should include the statement after the nested function")
end
test_nested_function_definition()

-- Test cosmic --benchmark with filter syntax
local function test_cosmic_benchmark_filter()
  local input = write_temp("cmd_filter.tl", [[
local function Benchmark_alpha()
  local x = 1
end

local function Benchmark_beta()
  local y = 2
end
]])
  local h2 = check.must(spawn.spawn({cosmic, "--benchmark", input .. ":alpha"}))
  local __r2 = check.must(h2:wait())
  local ok, out = __r2.ok, __r2.stdout
  assert(ok, "cosmic --benchmark with filter should succeed")
  assert(out:find("Benchmark_alpha"), "output should contain matching benchmark")
  assert(not out:find("Benchmark_beta"), "output should not contain non-matching benchmark")
end
test_cosmic_benchmark_filter()

print("All benchmark tests passed!")
