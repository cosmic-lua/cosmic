#!/usr/bin/env cosmic
-- test cosmic.benchmark module

local fs = require("cosmic.fs")
local spawn = require("cosmic.child")
local cio = require("cosmic.io")
local benchmark = require("cosmic.benchmark")

local cosmic = fs.join(os.getenv("TEST_BIN"), "cosmic")
local tmpdir = os.getenv("TEST_TMPDIR")

local function write_temp(name: string, content: string): string
  local filepath = fs.join(tmpdir, name)
  cio.barf(filepath, content)
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
  local result = benchmark.run(input)
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
  local h1 = spawn.spawn({cosmic, "--benchmark", input})
  local __r1 = (h1 as spawn.Handle):wait() as spawn.Result
  local ok, out = __r1.ok, __r1.stdout
  assert(ok, "cosmic --benchmark should succeed")
  assert((out as string):find("Benchmark_cmd"), "output should contain benchmark name")
  assert((out as string):find("ns/op") or (out as string):find("µs/op") or (out as string):find("ms/op"), "output should show timing")
end
test_cosmic_benchmark()

-- Test cosmic --benchmark with skip
local function test_cosmic_benchmark_skip()
  local input = write_temp("cmd_bench_skip.tl", [[
local x = 1
]])
  local r = spawn.run({cosmic, "--benchmark", input}) as spawn.Result
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
  local result = benchmark.run(input)
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
  local result = benchmark.run(input)
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
  local result = benchmark.run(input)
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
  local result = benchmark.run(input, "string")
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
  local h2 = spawn.spawn({cosmic, "--benchmark", input .. ":alpha"})
  local __r2 = (h2 as spawn.Handle):wait() as spawn.Result
  local ok, out = __r2.ok, __r2.stdout
  assert(ok, "cosmic --benchmark with filter should succeed")
  assert((out as string):find("Benchmark_alpha"), "output should contain matching benchmark")
  assert(not (out as string):find("Benchmark_beta"), "output should not contain non-matching benchmark")
end
test_cosmic_benchmark_filter()

print("All benchmark tests passed!")
