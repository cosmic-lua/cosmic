# perf_types

 Shared type definitions for the perf harness (lib/perf).
 The harness measures end-to-end scenarios (JSON, SQLite, HTTP, fs,
 process startup) so that changes in cosmic wrappers or the underlying
 cosmo/cosmopolitan runtime show up in the same numbers.

## Types

### Scenario

 One benchmark scenario.
 setup runs once before timing and its return value is passed to every
 fn/check/teardown call. fn performs exactly one operation per call.
 check validates the workload output before and after timing — an
 "optimization" that changes behavior fails the benchmark instead of
 producing a bogus win. Every scenario must define check.

```teal
local record Scenario
  name: string
  setup: function(): any, string
  fn: function(any): any
  check: function(any, any): boolean, string
  teardown: function(any)
end
```

### Options

 Harness knobs. samples is the number of timed samples per scenario;
 min_sample_secs is the minimum wall-clock duration of one sample.

```teal
local record Options
  samples: integer
  min_sample_secs: number
end
```

### Measurement

 Timing result for one scenario.
 wall_ns is the median wall-clock ns per operation across samples;
 cpu_ns is the mean CPU ns per operation (cpu/wall ratio well below 1
 means the scenario is I/O- or syscall-bound). alloc_kb is a
 best-effort estimate of Lua-side allocation per operation.

```teal
local record Measurement
  name: string
  iterations: integer
  samples_ns: {number}
  wall_ns: number
  cpu_ns: number
  min_ns: number
  max_ns: number
  spread_pct: number
  alloc_kb: number
  error: string
end
```

### Meta

 Environment metadata recorded alongside each results file.

```teal
local record Meta
  timestamp: number
  bin: string
  cosmic_version: string
  cosmos_version: string
  os: string
  isa: string
  nproc: number
  samples: integer
  min_sample_secs: number
end
```

### Results

 The on-disk results format (JSON).

```teal
local record Results
  meta: Meta
  results: {Measurement}
end
```

### Delta

 One row of a baseline-vs-current comparison.
 verdict is one of: "ok", "faster", "regression", "new", "missing",
 "error". noise_pct is the bar a delta must clear to count as real:
 max(threshold, baseline spread, current spread).

```teal
local record Delta
  name: string
  base_ns: number
  cur_ns: number
  delta_pct: number
  noise_pct: number
  verdict: string
end
```

### BenchModule

 Interface every lib/perf/bench/*_bench.tl module returns.
 scenarios() may allocate shared resources (temp dirs, databases,
 server processes) held in module upvalues; cleanup() releases them.

```teal
local record BenchModule
  scenarios: function(): {Scenario}, string
  cleanup: function()
end
```

### perf_types
