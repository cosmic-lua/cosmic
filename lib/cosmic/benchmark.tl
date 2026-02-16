--- Go-style benchmark testing.
--- Parses Benchmark_* functions from Teal files, runs them, and reports timing.
--- Similar to Go's testing.B but simplified: functions are called N times automatically.

local os_clock = os.clock

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
  error: string
end

--- Result from running all benchmarks in a file.
local record RunResult
  exit_code: integer
  results: {BenchmarkResult}
  error: string
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

  -- Track line numbers
  local function count_lines(s: string, start_pos: integer, end_pos: integer): integer
    local count = 0
    for i = start_pos, end_pos do
      if s:sub(i, i) == "\n" then
        count = count + 1
      end
    end
    return count
  end

  while true do
    -- Find next Benchmark_* function definition
    local func_start, func_end, func_name = source:find("local%s+function%s+(Benchmark[%w_]*)%s*%(%s*%)", pos)
    if not func_start then
      break
    end

    line_num = line_num + count_lines(source, pos, func_start)
    local benchmark_line = line_num

    -- Find the function body - need to track nested end keywords
    local body_start = func_end + 1
    local depth = 1
    local i = body_start

    -- Keywords that increase depth
    local block_starts: {string: boolean} = {
      ["function"] = true,
      ["if"] = true,
      ["for"] = true,
      ["while"] = true,
      ["repeat"] = true,
    }

    while i <= #source and depth > 0 do
      -- Skip strings
      if source:sub(i, i) == '"' or source:sub(i, i) == "'" then
        local quote = source:sub(i, i)
        i = i + 1
        while i <= #source do
          if source:sub(i, i) == "\\" then
            i = i + 2
          elseif source:sub(i, i) == quote then
            i = i + 1
            break
          else
            i = i + 1
          end
        end
        -- Skip long strings
      elseif source:sub(i, i + 1) == "[[" then
        local close = source:find("]]", i + 2, true)
        i = close and close + 2 or #source + 1
        -- Skip comments
      elseif source:sub(i, i + 1) == "--" then
        if source:sub(i + 2, i + 3) == "[[" then
          local close = source:find("]]", i + 4, true)
          i = close and close + 2 or #source + 1
        else
          local newline = source:find("\n", i)
          i = newline and newline + 1 or #source + 1
        end
      else
        -- Check for keywords
        local word_start, word_end, word = source:find("(%a+)", i)
        if word_start == i then
          if block_starts[word] then
            -- Make sure it's not part of "end" check (e.g., "endif")
            -- and that "function" is not just a type annotation
            if word == "function" then
              -- Check if this is an anonymous function or function type
              local before = source:sub(math.max(1, i - 1), i - 1)
              if before ~= ":" and before ~= ">" then
                depth = depth + 1
              end
            else
              depth = depth + 1
            end
          elseif word == "until" then
            depth = depth - 1
          elseif word == "end" then
            depth = depth - 1
          end
          i = word_end + 1
        else
          i = i + 1
        end
      end
    end

    local body_end = i - 4 -- Before "end"
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

--- Minimum benchmark duration in seconds (like Go's default 1s)
local MIN_DURATION = 1.0

--- Run a single benchmark and measure timing.
--- Executes the benchmark code repeatedly, auto-calibrating iterations.
--- @param benchmark Benchmark The benchmark to run
--- @param _file_path string Path to the source file (unused, for API consistency)
--- @return BenchmarkResult Result with timing statistics
local function run_benchmark(benchmark: Benchmark, _file_path: string): BenchmarkResult
  local result: BenchmarkResult = {
    name = benchmark.name,
    iterations = 0,
    ns_per_op = 0,
    total_ns = 0,
    error = nil,
  }

  -- Build a script that returns the benchmark function
  local script = [[
require("tl").loader()
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

  if type(bench_fn) ~= "function" then
    result.error = "benchmark did not return a function"
    return result
  end

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

  -- Auto-calibrate: start with N=1 and increase until we reach MIN_DURATION
  local n = 1
  local elapsed = 0.0

  while elapsed < MIN_DURATION do
    -- Warm up / calibrate
    local start = os_clock()
    for _ = 1, n do
      local run_ok, run_err: boolean, any = pcall(bench_fn as function())
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
    elapsed = os_clock() - start

    if elapsed < MIN_DURATION then
      -- Estimate iterations needed to reach MIN_DURATION
      if elapsed > 0 then
        local estimate = math.ceil(n * MIN_DURATION / elapsed)
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

--- Run all benchmarks in a file, optionally filtered by pattern.
--- Parses and executes Benchmark_* functions, returning aggregated results.
--- @param file_path string Path to the Teal file containing benchmarks
--- @param filter string Optional Lua pattern to filter benchmark names (e.g., "concat" matches Benchmark_string_concat)
--- @return RunResult Result with exit code (0=pass, 1=fail, 2=skip), results, and errors
local function run(file_path: string, filter?: string): RunResult
  local f, err = io.open(file_path, "r")
  if not f then
    return {
      exit_code = 1,
      results = {},
      error = "cannot open file: " .. (err or "unknown"),
    }
  end

  local source = f:read("*a")
  f:close()

  local all_benchmarks = parse_benchmarks(source)

  -- Filter benchmarks by pattern if provided
  local benchmarks: {Benchmark} = {}
  if filter then
    for _, benchmark in ipairs(all_benchmarks) do
      if benchmark.name:find(filter) then
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
        error = "no benchmarks matching '" .. filter .. "' (found " .. #all_benchmarks .. " total)",
      }
    end
    return {
      exit_code = 2,
      results = {},
      error = nil,
    }
  end

  local results: {BenchmarkResult} = {}
  local has_error = false

  for _, benchmark in ipairs(benchmarks) do
    local result = run_benchmark(benchmark, file_path)
    table.insert(results, result)
    if result.error then
      has_error = true
    end
  end

  return {
    exit_code = has_error and 1 or 0,
    results = results,
    error = nil,
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

  if run_result.error then
    table.insert(lines, file_path .. ": ERROR: " .. run_result.error)
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
  run: function(file_path: string, filter?: string): RunResult
  parse_benchmarks: function(source: string): {Benchmark}
  format_results: function(file_path: string, run_result: RunResult): string
end

local M: BenchmarkModule = {
  run = run,
  parse_benchmarks = parse_benchmarks,
  format_results = format_results,
}

return M
