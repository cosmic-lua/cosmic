# compare

 Baseline-vs-current comparison gate for perf results.
 Loads two results files produced by perf.run, compares median wall ns
 per operation, and classifies each scenario. A delta only counts as a
 regression (or improvement) when it clears the noise bar:
 max(threshold, baseline spread, current spread).

 Guardrails: scenarios that error, and scenarios present in the baseline
 but missing from the current run (deleting a benchmark cannot hide a
 regression), both count as failures.

## Types

### compare

```teal
local record compare
  DEFAULT_THRESHOLD_PCT: number
  load_results: function(path: string): pt.Results, string
  diff: function(base: pt.Results, cur: pt.Results, threshold_pct?: number): {pt.Delta}, integer
  format_delta: function(d: pt.Delta): string
  format: function(deltas: {pt.Delta}): string
end
```
