# harness

 Scenario benchmark harness: wall-clock timing with functional checks.
 Runs Scenario specs (setup/fn/check/teardown): calibrates an iteration
 count so each sample lasts at least min_sample_secs, takes several timed
 samples, and reports per-operation statistics (median wall ns, CPU ns,
 spread, best-effort allocation).

 Guardrails built into every run:
 - check() is executed before and after timing; a workload whose output
   is wrong fails the benchmark instead of reporting a bogus win.
 - setup/fn/check/teardown crashes are captured into Measurement.error
   so one broken scenario never aborts the whole run.

 Unlike cosmic.benchmark (Go-style Benchmark_* micro runner using CPU
 time), this harness times wall clock, which is what end-to-end scenarios
 (HTTP, SQLite, process startup) actually cost.

## Types

### harness

```teal
local record harness
  DEFAULT_SAMPLES: integer
  DEFAULT_MIN_SAMPLE_SECS: number
  run_scenario: function(scenario: pt.Scenario, opts?: pt.Options): pt.Measurement
  run_all: function(scenarios: {pt.Scenario}, opts?: pt.Options, on_result?: function(pt.Measurement)): {pt.Measurement}
  format_ns: function(ns: number): string
  format_line: function(m: pt.Measurement): string
end
```
