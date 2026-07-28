--- Shared type definitions for the perf harness (_perf).
--- The harness measures end-to-end scenarios (JSON, SQLite, HTTP, fs,
--- process startup) so that changes in cosmic wrappers or the underlying
--- cosmo/cosmopolitan runtime show up in the same numbers.

local record perf_types

  --- One benchmark scenario.
  --- setup runs once before timing and its return value is passed to every
  --- fn/check/teardown call. fn performs exactly one operation per call.
  --- check validates the workload output before and after timing — an
  --- "optimization" that changes behavior fails the benchmark instead of
  --- producing a bogus win. Every scenario must define check.
  record Scenario
    name: string
    setup: function(): any, string
    fn: function(any): any
    check: function(any, any): boolean, string
    teardown: function(any)
  end

  --- Harness knobs. samples is the number of timed samples per scenario;
  --- min_sample_secs is the minimum wall-clock duration of one sample.
  record Options
    samples: integer
    min_sample_secs: number
  end

  --- Timing result for one scenario.
  --- wall_ns is the median wall-clock ns per operation across samples;
  --- cpu_ns is the mean CPU ns per operation (cpu/wall ratio well below 1
  --- means the scenario is I/O- or syscall-bound). alloc_kb is a
  --- best-effort estimate of Lua-side allocation per operation.
  record Measurement
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

  --- Environment metadata recorded alongside each results file.
  record Meta
    timestamp: number
    bin: string
    --- The measured binary's sha256, hex. The identity, where `bin` is
    --- only a name: two runs forty commits apart both say
    --- `o/bin/cosmic`. Absent when the binary could not be read, which
    --- is a results file that cannot name its subject.
    bin_sha: string
    cosmic_version: string
    cosmos_version: string
    os: string
    isa: string
    nproc: number
    samples: integer
    min_sample_secs: number
  end

  --- The on-disk results format (JSON).
  record Results
    meta: Meta
    results: {Measurement}
  end

  --- One row of a baseline-vs-current comparison.
  --- verdict is one of: "ok", "faster", "regression", "noise", "new",
  --- "missing", "error". "noise" is a regression that an A/A self-check
  --- reclassified as run-to-run variance (see compare.triage); it does
  --- not fail the gate. noise_pct is the bar a delta must clear to count
  --- as real: max(threshold, baseline spread, current spread).
  record Delta
    name: string
    base_ns: number
    cur_ns: number
    delta_pct: number
    noise_pct: number
    verdict: string
  end

  --- Interface every _perf/bench/*_bench.tl module returns.
  --- scenarios() may allocate shared resources (temp dirs, databases,
  --- server processes) held in module upvalues; cleanup() releases them.
  record BenchModule
    scenarios: function(): {Scenario}, string
    cleanup: function()
  end
end

return perf_types
