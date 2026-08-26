## Capture

Observed 2026-08-26 while fixing 3ISWHWQT. `cosmic --fix` on
_perf/run.tl containing

  if version_fn is function(): any then
    local v = version_fn()
    ...
  end

reflowed the guard body to column 2 and pulled the trailing `end` and
the following `return meta` to column 0 — the formatter's block-depth
walk reads the `function` keyword inside the TYPE (`is function():
any`) as opening a function body, the same keyword-in-type-position
miscount as _cli lint's end_line_of on `as function(any, any)`
(3IP9ijhv). The output is still valid source and is its own fmt
fixpoint, so the gate passes on mangled indentation rather than
refusing. Reproduce: write the shape above in any .tl, run
`cosmic --format`. The fix likely shares whatever token-context
answer 3IP9ijhv lands (a `function` token preceded by `is`/`as`/`:`
type context opens no block); fixing either without the other leaves
the class half-closed — consider one slice covering both walkers.
