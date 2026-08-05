# benchmark

 Go-style benchmark testing.
 Parses Benchmark_* functions from Teal files, runs them, and reports timing.
 Similar to Go's testing.B but simplified: functions are called N times automatically.

## Types

### Benchmark

 A parsed benchmark function.

```teal
local record Benchmark
  name: string
  body: string
  line: integer
end
```

### BenchmarkResult

 Result from running a single benchmark.

```teal
local record BenchmarkResult
  name: string
  iterations: integer
  ns_per_op: number
  total_ns: number
  error: string | nil
end
```

### RunResult

 Result from running all benchmarks in a file.

```teal
local record RunResult
  exit_code: integer
  results: {BenchmarkResult}
  error: string | nil
end
```

### Options

 Options for `run`.

```teal
local record Options
  --  Run only benchmarks whose name contains this SUBSTRING, matched
  --  plainly (e.g. "concat" matches Benchmark_string_concat). Folded in
  --  from the old positional between the path and the options
  --  (api-review-6).
  filter: string
  --  Minimum calibrated duration per benchmark, in integer
  --  milliseconds. Defaults to 1000 (Go's 1s convention) when unset. A
  --  real timing measurement should leave this at the default; a test
  --  of the RUNNER itself (discovery, naming, iteration counting,
  --  formatting, error handling) is the intended user of a small
  --  value here, since 1s of looping proves nothing a 10ms run
  --  doesn't.
  min_ms: integer
end
```

### BenchmarkModule

```teal
local record BenchmarkModule
  run: function(file_path: string, opts?: Options): RunResult
  parse_benchmarks: function(source: string): {Benchmark}
  format_results: function(file_path: string, run_result: RunResult): string
end
```

## Functions

### parse_benchmarks

```teal
function parse_benchmarks(source: string): {Benchmark}
```

 Parse a .tl file and extract Benchmark_* functions.
 Finds all local functions named Benchmark_* and extracts their code.

**Parameters:**

- `source` (string) - The source code to parse

**Returns:**

- {Benchmark} - List of parsed benchmarks

### run

```teal
function run(file_path: string, opts?: Options): RunResult
```

 Run all benchmarks in a file, optionally filtered.
 Parses and executes Benchmark_* functions, returning aggregated results.

**Parameters:**

- `file_path` (string) - Path to the Teal file containing benchmarks
- `opts` (Options?) - filter substring and min_ms calibration floor

**Returns:**

- RunResult - Result with exit code (0=pass, 1=fail, 2=skip), results, and errors

### format_results

```teal
function format_results(file_path: string, run_result: RunResult): string
```

 Format results for human-readable output (Go-style).
 Creates formatted benchmark output showing iterations and ns/op.

**Parameters:**

- `file_path` (string) - Path to the file that was benchmarked
- `run_result` (RunResult) - Results from running benchmarks

**Returns:**

- string - Formatted output for display
