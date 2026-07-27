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
  error: string
end
```

### RunResult

 Result from running all benchmarks in a file.

```teal
local record RunResult
  exit_code: integer
  results: {BenchmarkResult}
  error: string
end
```

### BenchmarkModule

```teal
local record BenchmarkModule
  run: function(file_path: string, filter?: string): RunResult
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
function run(file_path: string, filter?: string): RunResult
```

 Run all benchmarks in a file, optionally filtered by pattern.
 Parses and executes Benchmark_* functions, returning aggregated results.

**Parameters:**

- `file_path` (string) - Path to the Teal file containing benchmarks
- `filter` (string) - Optional SUBSTRING of the benchmark name, matched plainly (e.g. "concat" matches Benchmark_string_concat)

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
