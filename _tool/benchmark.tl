--- Go-style benchmark testing.
--- Parses Benchmark_* functions from Teal files, runs them, and reports timing.
--- Similar to Go's testing.B but simplified: functions are called N times automatically.

local time = require("cosmic.time")
local scan = require("_tool.doc.scan")
local env = require("cosmic.env")

-- Timing uses time.monotonic_ns (CLOCK_MONOTONIC) so IO-bound
-- benchmarks (which block rather than burn CPU) are measured by
-- elapsed wall time, not CPU time. Measuring CPU time via os.clock()
-- would leave `elapsed` near zero on such benchmarks and make the
-- calibration loop grow iterations without bound.
local monotonic_ns = time.monotonic_ns

--- A parsed benchmark function.
local record Benchmark
  name: string
  body: string
  line: integer
end

--- Result from running a single benchmark.
local record BenchmarkResult
  name: string
  iterations: integer
  ns_per_op: number
  total_ns: number
  error: string | nil
end

--- Result from running all benchmarks in a file. `message` is the
--- runners' shared shape: what went wrong with the RUN; per-benchmark
--- failures are on each result.
local record RunResult
  exit_code: integer
  results: {BenchmarkResult}
  message: string | nil
end

--- Parse a .tl file and extract Benchmark_* functions.
--- Finds all local functions named Benchmark_* and extracts their code.
--- @param source string The source code to parse
--- @return {Benchmark} List of parsed benchmarks
local function parse_benchmarks(source: string): {Benchmark}
  local benchmarks: {Benchmark} = {}

  -- Pattern to find local function Benchmark_* definitions
  local pos = 1
  local line_num = 1

  while true do
    -- Find next Benchmark_* function definition
    local func_start, func_end, func_name = source:find("local%s+function%s+(Benchmark[%w_]*)%s*%(%s*%)", pos)
    if not func_start then
      break
    end

    line_num = line_num + scan.count_lines(source, pos, func_start)
    local benchmark_line = line_num

    -- Find the function body - need to track nested end keywords
    local body_start = func_end + 1
    local body_end, i = scan.find_block_end(source, body_start)
    local body = source:sub(body_start, body_end)

    table.insert(benchmarks, {
        name = func_name,
        body = body,
        line = benchmark_line,
      })

    pos = i
  end

  return benchmarks
end

--- Default minimum benchmark duration in seconds (like Go's default 1s).
local DEFAULT_MIN_SECONDS = 1.0

--- Options for `run`. The runners share this shape; example honors
--- `filter` with the same substring contract.
local record RunOptions
  --- Run only benchmarks whose name contains this SUBSTRING, matched
  --- plainly (e.g. "concat" matches Benchmark_string_concat).
  filter: string
  --- Minimum calibrated duration per benchmark, in integer
  --- milliseconds. Defaults to 1000 (Go's 1s convention) when unset. A
  --- real timing measurement should leave this at the default; a test
  --- of the RUNNER itself (discovery, naming, iteration counting,
  --- formatting, error handling) is the intended user of a small
  --- value here, since 1s of looping proves nothing a 10ms run
  --- doesn't.
  min_ms: integer
end

--- Resolve the minimum calibration duration for a run: an explicit
--- `Options.min_ms` wins; otherwise the COSMIC_BENCHMARK_MIN_MS
--- environment variable, when it parses as a number, lets a caller with
--- no Options to pass (the `--benchmark` CLI flag spawns no sub-options,
--- so this is how its own tests shrink calibration through a spawned
--- `cosmic --benchmark` child); otherwise DEFAULT_MIN_SECONDS.
--- @param opts RunOptions? Run options
--- @return number Minimum duration in seconds
local function resolve_min_seconds(opts: RunOptions): number
  if opts and opts.min_ms then
    return opts.min_ms / 1000
  end
  local from_env = env.get("COSMIC_BENCHMARK_MIN_MS")
  if from_env then
    local n = tonumber(from_env)
    if n then
      return n / 1000
    end
  end
  return DEFAULT_MIN_SECONDS
end

--- Run a single benchmark and measure timing.
--- Executes the benchmark code repeatedly, auto-calibrating iterations.
--- @param benchmark Benchmark The benchmark to run
--- @param min_seconds number Minimum calibrated duration, in seconds
--- @return BenchmarkResult Result with timing statistics
local function run_benchmark(benchmark: Benchmark, min_seconds: number): BenchmarkResult
  local result: BenchmarkResult = {
    name = benchmark.name,
    iterations = 0,
    ns_per_op = 0,
    total_ns = 0,
    error = nil,
  }

  -- Build a script that returns the benchmark function. No loader
  -- prelude: the cosmic dispatcher's runtime .tl searcher already
  -- resolves require statements in benchmark bodies.
  local script = [[
return function()
]] .. benchmark.body .. [[
end
]]

  -- Load the benchmark function
  local chunk, load_err = load(script, benchmark.name)
  if not chunk then
    result.error = "load error: " .. (load_err or "unknown")
    return result
  end

  local ok, bench_fn = pcall(chunk)
  if not ok then
    result.error = "load error: " .. tostring(bench_fn)
    return result
  end

  if not (bench_fn is function()) then
    result.error = "benchmark did not return a function"
    return result
  end
  local run_fn: function() = bench_fn

  -- Redirect stdout/stderr to /dev/null during benchmark
  -- Note: print() uses C-level stdout directly, so we also override it
  local old_stdout = io.stdout
  local old_stderr = io.stderr
  local old_print = _G.print
  local devnull = io.open("/dev/null", "w")
  if devnull then
    io.stdout = devnull
    io.stderr = devnull
    io.output(devnull)
    _G.print = function() end
  end

  -- Auto-calibrate: start with N=1 and increase until we reach min_seconds
  local n = 1
  local elapsed = 0.0

  while elapsed < min_seconds do
    -- Warm up / calibrate
    local start = monotonic_ns()
    for _ = 1, n do
      local run_ok, run_err: boolean, any = pcall(run_fn)
      if not run_ok then
        -- Restore stdout/stderr before returning
        if devnull then
          io.stdout = old_stdout
          io.stderr = old_stderr
          io.output(old_stdout)
          _G.print = old_print
          devnull:close()
        end
        result.error = "runtime error: " .. tostring(run_err)
        return result
      end
    end
    elapsed = (monotonic_ns() - start) / 1e9

    if elapsed < min_seconds then
      -- Estimate iterations needed to reach min_seconds
      if elapsed > 0 then
        local estimate = math.ceil(n * min_seconds / elapsed)
        -- Don't grow too fast - cap at 10x
        n = math.min(estimate, n * 10)
      else
        n = n * 10
      end
    end
  end

  -- Restore stdout/stderr
  if devnull then
    io.stdout = old_stdout
    io.stderr = old_stderr
    io.output(old_stdout)
    _G.print = old_print
    devnull:close()
  end

  -- Calculate results
  result.iterations = n
  result.total_ns = elapsed * 1e9
  result.ns_per_op = result.total_ns / n

  return result
end

--- Run all benchmarks in a file, optionally filtered.
--- Parses and executes Benchmark_* functions, returning aggregated results.
--- @param file_path string Path to the Teal file containing benchmarks
--- @param opts RunOptions? filter substring and min_ms calibration floor
--- @return RunResult Result with exit code (0=pass, 1=fail, 2=skip), results, and a message
local function run(file_path: string, opts?: RunOptions): RunResult
  local f, err = io.open(file_path, "r")
  if not f then
    return {
      exit_code = 1,
      results = {},
      message = "cannot open file: " .. (err or "unknown"),
    }
  end

  local source = f:read("*a")
  f:close()

  local all_benchmarks = parse_benchmarks(source)
  local filter = opts and opts.filter

  -- Filter by plain SUBSTRING, not by pattern: a benchmark name is
  -- `Benchmark_string_concat`, and a filter a user types is not a
  -- regex they were asked to write.
  local benchmarks: {Benchmark} = {}
  if filter then
    for _, benchmark in ipairs(all_benchmarks) do
      if benchmark.name:find(filter, 1, true) then
        table.insert(benchmarks, benchmark)
      end
    end
  else
    benchmarks = all_benchmarks
  end

  if #benchmarks == 0 then
    -- No benchmarks found (or none matched filter) - this is a skip (exit code 2)
    if filter and #all_benchmarks > 0 then
      return {
        exit_code = 2,
        results = {},
        message = "no benchmarks matching '" .. filter .. "' (found " .. #all_benchmarks .. " total)",
      }
    end
    return {
      exit_code = 2,
      results = {},
      message = nil,
    }
  end

  local results: {BenchmarkResult} = {}
  local has_error = false
  local min_seconds = resolve_min_seconds(opts)

  for _, benchmark in ipairs(benchmarks) do
    local result = run_benchmark(benchmark, min_seconds)
    table.insert(results, result)
    if result.error then
      has_error = true
    end
  end

  return {
    exit_code = has_error and 1 or 0,
    results = results,
    message = nil,
  }
end

--- Format a number with appropriate units for readability.
--- @param ns number Nanoseconds
--- @return string Formatted time string
local function format_time(ns: number): string
  if ns < 1000 then
    return string.format("%.2f ns/op", ns)
  elseif ns < 1000000 then
    return string.format("%.2f µs/op", ns / 1000)
  elseif ns < 1000000000 then
    return string.format("%.2f ms/op", ns / 1000000)
  else
    return string.format("%.2f s/op", ns / 1000000000)
  end
end

--- Format results for human-readable output (Go-style).
--- Creates formatted benchmark output showing iterations and ns/op.
--- @param file_path string Path to the file that was benchmarked
--- @param run_result RunResult Results from running benchmarks
--- @return string Formatted output for display
local function format_results(file_path: string, run_result: RunResult): string
  local lines: {string} = {}

  if run_result.message then
    table.insert(lines, file_path .. ": ERROR: " .. run_result.message)
    return table.concat(lines, "\n")
  end

  if run_result.exit_code == 2 then
    table.insert(lines, file_path .. ": SKIP (no benchmarks)")
    return table.concat(lines, "\n")
  end

  -- Header (Go-style)
  table.insert(lines, "pkg: " .. file_path)

  for _, result in ipairs(run_result.results) do
    if result.error then
      table.insert(lines, result.name .. ": FAIL")
      table.insert(lines, "  error: " .. result.error)
    else
      -- Go-style output: BenchmarkName    N    ns/op
      local iter_str = tostring(result.iterations)
      local time_str = format_time(result.ns_per_op)
      -- Right-align iterations to ~10 chars for readability
      local padding = string.rep(" ", math.max(1, 10 - #iter_str))
      table.insert(lines, result.name .. padding .. iter_str .. "    " .. time_str)
    end
  end

  table.insert(lines, "PASS")

  return table.concat(lines, "\n")
end

local record BenchmarkModule
  type RunOptions = RunOptions
  type RunResult = RunResult

  run: function(file_path: string, opts?: RunOptions): RunResult
  parse_benchmarks: function(source: string): {Benchmark}
  format_results: function(file_path: string, run_result: RunResult): string
end

local M: BenchmarkModule = {
  run = run,
  parse_benchmarks = parse_benchmarks,
  format_results = format_results,
}

return M
