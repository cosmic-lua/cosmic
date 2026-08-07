--- Scenario benchmark harness: wall-clock timing with functional checks.
--- Runs Scenario specs (setup/fn/check/teardown): calibrates an iteration
--- count so each sample lasts at least min_sample_secs, takes several timed
--- samples, and reports per-operation statistics (median wall ns, CPU ns,
--- spread, best-effort allocation).
---
--- Guardrails built into every run:
--- - check() is executed before and after timing; a workload whose output
---   is wrong fails the benchmark instead of reporting a bogus win.
--- - setup/fn/check/teardown crashes are captured into Measurement.error
---   so one broken scenario never aborts the whole run.
---
--- Unlike cosmic.benchmark (Go-style Benchmark_* micro runner using CPU
--- time), this harness times wall clock, which is what end-to-end scenarios
--- (HTTP, SQLite, process startup) actually cost.

local stats = require("_perf.stats")
local time = require("cosmic.time")
local pt = require("_perf.perf_types")

local DEFAULT_SAMPLES = 5
local DEFAULT_MIN_SAMPLE_SECS = 0.15
local MAX_ITERATIONS = 1000000000
local ALLOC_PROBE_CAP = 1000

-- Monotonic nanoseconds; exact integer math via cosmic.time.
local monotonic_ns = time.monotonic_ns

--- Run fn n times, timing wall clock and CPU time.
--- @param fn function The per-operation function
--- @param ctx any Context from setup, passed to fn
--- @param n integer Number of iterations
--- @return number Total wall nanoseconds
--- @return number Total CPU nanoseconds
--- @return any The last value returned by fn
local function run_ops(fn: function(any): any, ctx: any, n: integer): number, number, any
  local last: any
  local cpu0 = os.clock()
  local wall0 = monotonic_ns()
  for _ = 1, n do
    last = fn(ctx)
  end
  local wall1 = monotonic_ns()
  local cpu1 = os.clock()
  return wall1 - wall0, (cpu1 - cpu0) * 1e9, last
end

--- Find an iteration count whose sample lasts at least min_secs.
--- @param fn function The per-operation function
--- @param ctx any Context from setup
--- @param min_secs number Minimum sample duration in seconds
--- @return integer The calibrated iteration count
local function calibrate(fn: function(any): any, ctx: any, min_secs: number): integer
  local n: integer = 1
  local target_ns = min_secs * 1e9
  while n < MAX_ITERATIONS do
    local wall = run_ops(fn, ctx, n)
    if wall >= target_ns then
      return n
    end
    local grown: integer
    if wall <= 0 then
      grown = n * 10
    else
      -- Overshoot by 20% so the next probe usually lands past the target,
      -- but never grow more than 10x at once.
      local estimate = math.ceil((n * target_ns * 1.2) / wall)
      grown = math.min(estimate, n * 10)
    end
    if grown <= n then
      grown = n + 1
    end
    n = grown
  end
  return MAX_ITERATIONS
end

--- Estimate Lua-side allocation per operation in KB (best-effort).
--- Runs with the collector stopped so the count delta approximates
--- allocation rather than live-set growth.
--- @param fn function The per-operation function
--- @param ctx any Context from setup
--- @param n integer Calibrated iteration count (capped for the probe)
--- @return number Allocated KB per operation
local function alloc_probe(fn: function(any): any, ctx: any, n: integer): number
  local iters = math.min(n, ALLOC_PROBE_CAP)
  collectgarbage("collect")
  collectgarbage("stop")
  local before = collectgarbage("count")
  for _ = 1, iters do
    fn(ctx)
  end
  local after = collectgarbage("count")
  collectgarbage("restart")
  collectgarbage("collect")
  return (after - before) / iters
end

--- Run a scenario's check hook against a result, if one is defined.
--- @param scenario Scenario The scenario
--- @param ctx any Context from setup
--- @param result any The value returned by fn
--- @return string An error message, or nil if the check passed
local function run_check(scenario: pt.Scenario, ctx: any, result: any): string
  if not scenario.check then
    return nil
  end
  local ok, passed, cerr = pcall(scenario.check, ctx, result)
  if not ok then
    return "check crashed: " .. tostring(passed)
  end
  if not passed then
    return "check failed: " .. tostring(cerr or "no reason given")
  end
  return nil
end

--- Mark a measurement as failed.
--- @param m Measurement The measurement to fail
--- @param msg string The error message
--- @return Measurement The same measurement, for tail returns
local function fail(m: pt.Measurement, msg: string): pt.Measurement
  m.error = msg
  return m
end

--- Run one scenario: setup, verify, calibrate, sample, re-verify, teardown.
--- Never throws; failures are reported via Measurement.error.
--- @param scenario Scenario The scenario to run
--- @param opts Options? Harness options (defaults: 5 samples, 0.15s each)
--- @return Measurement Timing statistics or an error
local function run_scenario(scenario: pt.Scenario, opts?: pt.Options): pt.Measurement
  local samples = DEFAULT_SAMPLES
  local min_secs = DEFAULT_MIN_SAMPLE_SECS
  if opts then
    samples = opts.samples or samples
    min_secs = opts.min_sample_secs or min_secs
  end

  local m: pt.Measurement = {
    name = scenario.name,
    iterations = 0,
    samples_ns = {},
  }

  local ctx: any
  if scenario.setup then
    local sok, sctx, serr = pcall(scenario.setup)
    if not sok then
      return fail(m, "setup crashed: " .. tostring(sctx))
    end
    if sctx == nil and serr ~= nil then
      return fail(m, "setup failed: " .. tostring(serr))
    end
    ctx = sctx
  end

  local function teardown()
    if scenario.teardown then
      pcall(scenario.teardown, ctx)
    end
  end

  -- Warm up once and verify the workload before timing anything.
  local wok, wres = pcall(scenario.fn, ctx)
  if not wok then
    teardown()
    return fail(m, "fn crashed: " .. tostring(wres))
  end
  local cerr = run_check(scenario, ctx, wres)
  if cerr then
    teardown()
    return fail(m, cerr)
  end

  local last: any
  local function measure(): boolean
    local n = calibrate(scenario.fn, ctx, min_secs)
    m.iterations = n
    local cpu_total = 0.0
    for i = 1, samples do
      local wall, cpu, res = run_ops(scenario.fn, ctx, n)
      m.samples_ns[i] = wall / n
      cpu_total = cpu_total + cpu
      last = res
    end
    m.cpu_ns = cpu_total / (samples * n)
    m.alloc_kb = alloc_probe(scenario.fn, ctx, n)
    return true
  end
  local rok, rerr = pcall(measure)
  if not rok then
    teardown()
    return fail(m, "run crashed: " .. tostring(rerr))
  end

  -- Re-verify after timing: catches workloads that only work once.
  cerr = run_check(scenario, ctx, last)
  if cerr then
    teardown()
    return fail(m, cerr)
  end
  teardown()

  m.wall_ns = stats.median(m.samples_ns)
  m.min_ns = stats.min(m.samples_ns)
  m.max_ns = stats.max(m.samples_ns)
  m.spread_pct = stats.spread_pct(m.samples_ns)
  return m
end

--- Run a list of scenarios in order.
--- @param scenarios {Scenario} The scenarios to run
--- @param opts Options? Harness options applied to every scenario
--- @param on_result function? Called with each Measurement as it completes
--- @return {Measurement} All measurements, in scenario order
local function run_all(scenarios: {pt.Scenario}, opts?: pt.Options, on_result?: function(pt.Measurement)): {pt.Measurement}
  local out: {pt.Measurement} = {}
  for _, s in ipairs(scenarios) do
    local m = run_scenario(s, opts)
    table.insert(out, m)
    if on_result then
      on_result(m)
    end
  end
  return out
end

--- Format nanoseconds with a readable unit.
--- @param ns number Nanoseconds
--- @return string For example "1.25 µs"
local function format_ns(ns: number): string
  if ns == nil then
    return "?"
  end
  if ns < 1000 then
    return string.format("%.1f ns", ns)
  elseif ns < 1000000 then
    return string.format("%.2f µs", ns / 1000)
  elseif ns < 1000000000 then
    return string.format("%.2f ms", ns / 1000000)
  end
  return string.format("%.2f s", ns / 1000000000)
end

--- Format one measurement as a human-readable report line.
--- @param m Measurement The measurement
--- @return string A single line: name, iterations, ns/op, spread, cpu/wall, alloc
local function format_line(m: pt.Measurement): string
  if m.error then
    return string.format("%-28s FAIL: %s", m.name, m.error)
  end
  local ratio = 0.0
  if m.cpu_ns and m.wall_ns and m.wall_ns > 0 then
    ratio = m.cpu_ns / m.wall_ns
  end
  return string.format("%-28s %10d x %12s/op  ±%5.1f%%  cpu/wall %4.2f  alloc %8.2f KB",
    m.name, m.iterations, format_ns(m.wall_ns), m.spread_pct, ratio, m.alloc_kb or 0)
end

local record harness
  DEFAULT_SAMPLES: integer
  DEFAULT_MIN_SAMPLE_SECS: number
  run_scenario: function(scenario: pt.Scenario, opts?: pt.Options): pt.Measurement
  run_all: function(scenarios: {pt.Scenario}, opts?: pt.Options, on_result?: function(pt.Measurement)): {pt.Measurement}
  format_ns: function(ns: number): string
  format_line: function(m: pt.Measurement): string
end

local M: harness = {
  DEFAULT_SAMPLES = DEFAULT_SAMPLES,
  DEFAULT_MIN_SAMPLE_SECS = DEFAULT_MIN_SAMPLE_SECS,
  run_scenario = run_scenario,
  run_all = run_all,
  format_ns = format_ns,
  format_line = format_line,
}

return M
