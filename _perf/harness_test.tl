local harness = require("_perf.harness")
local pt = require("_perf.perf_types")

-- Tiny options so tests stay fast.
local FAST: pt.Options = {samples = 2, min_sample_secs = 0.001}

local function test_run_scenario_measures_and_checks()
  local calls = 0
  local m = harness.run_scenario({
      name = "counting",
      fn = function(_: any): any
        calls = calls + 1
        return "value"
      end,
      check = function(_: any, res: any): boolean, string
        if res as string ~= "value" then -- cast: from any
          return false, "unexpected result"
        end
        return true
      end,
    }, FAST)
  assert(m.error == nil, "unexpected error: " .. tostring(m.error))
  assert(m.name == "counting", "name wrong")
  assert(calls > 0, "fn never ran")
  assert(m.iterations >= 1, "iterations missing")
  assert(#m.samples_ns == 2, "expected 2 samples, got " .. #m.samples_ns)
  assert(m.wall_ns ~= nil and m.wall_ns >= 0, "wall_ns missing")
  assert(m.min_ns <= m.wall_ns and m.wall_ns <= m.max_ns, "stats out of order")
end
test_run_scenario_measures_and_checks()

local function test_setup_result_reaches_fn_and_teardown()
  local torn_down: any = nil
  local m = harness.run_scenario({
      name = "ctx",
      setup = function(): any, string
        return {token = "abc"}
      end,
      fn = function(ctx: any): any
        return (ctx as {string: string}).token -- cast: from any
      end,
      check = function(_: any, res: any): boolean, string
        -- cast: from any
        return res as string == "abc", "token did not flow through"
      end,
      teardown = function(ctx: any)
        torn_down = ctx
      end,
    }, FAST)
  assert(m.error == nil, "unexpected error: " .. tostring(m.error))
  assert(torn_down ~= nil, "teardown never ran")
end
test_setup_result_reaches_fn_and_teardown()

local function test_failing_check_fails_measurement()
  local m = harness.run_scenario({
      name = "bad_check",
      fn = function(_: any): any
        return 42
      end,
      check = function(_: any, _res: any): boolean, string
        return false, "wrong answer"
      end,
    }, FAST)
  assert(m.error ~= nil, "expected check failure")
  assert(m.error:find("wrong answer", 1, true), "reason lost: " .. m.error)
end
test_failing_check_fails_measurement()

local function test_crashing_fn_fails_measurement()
  local torn_down = false
  local m = harness.run_scenario({
      name = "crash",
      fn = function(_: any): any
        error("boom")
      end,
      check = function(_: any, _res: any): boolean, string
        return true
      end,
      teardown = function(_: any)
        torn_down = true
      end,
    }, FAST)
  assert(m.error ~= nil, "expected crash to be captured")
  assert(m.error:find("boom", 1, true), "crash message lost: " .. m.error)
  assert(torn_down, "teardown must run even on crash")
end
test_crashing_fn_fails_measurement()

local function test_failing_setup_fails_measurement()
  local m = harness.run_scenario({
      name = "bad_setup",
      setup = function(): any, string
        return nil, "no resources"
      end,
      fn = function(_: any): any
        return 1
      end,
      check = function(_: any, _res: any): boolean, string
        return true
      end,
    }, FAST)
  assert(m.error ~= nil, "expected setup failure")
  assert(m.error:find("no resources", 1, true), "setup reason lost: " .. m.error)
end
test_failing_setup_fails_measurement()

local function test_run_all_reports_each_scenario()
  local seen: {string} = {}
  local results = harness.run_all({
      {
        name = "one",
        fn = function(_: any): any return 1 end,
        check = function(_: any, _r: any): boolean, string return true end,
      },
      {
        name = "two",
        fn = function(_: any): any return 2 end,
        check = function(_: any, _r: any): boolean, string return true end,
      },
    }, FAST, function(m: pt.Measurement)
      table.insert(seen, m.name)
    end)
  assert(#results == 2, "expected 2 results")
  assert(seen[1] == "one" and seen[2] == "two", "callback order wrong")
end
test_run_all_reports_each_scenario()

local function test_format_helpers()
  assert(harness.format_ns(12) == "12.0 ns", "ns format wrong")
  assert(harness.format_ns(1500) == "1.50 µs", "µs format wrong")
  assert(harness.format_ns(2500000) == "2.50 ms", "ms format wrong")
  assert(harness.format_ns(3.2e9) == "3.20 s", "s format wrong")
  local line = harness.format_line({
      name = "x", iterations = 10, samples_ns = {},
      wall_ns = 100, cpu_ns = 50, spread_pct = 1.5, alloc_kb = 0.5,
    })
  assert(line:find("x", 1, true) and line:find("100.0 ns", 1, true), "line missing fields: " .. line)
  local fail_line = harness.format_line({name = "y", samples_ns = {}, error = "broke"})
  assert(fail_line:find("FAIL", 1, true) and fail_line:find("broke", 1, true),
    "fail line wrong: " .. fail_line)
end
test_format_helpers()

print("OK harness_test")
