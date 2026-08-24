Split out of 3IK8EOci during its 2026-08-24 refinement, which took only
the token-copy hypothesis so the diff stays one hypothesis.

## Problem
`cosmic/format/init.tl`'s emit pass appends to one `out: {string}`
accumulator at 12 sites (`grep -c "out\[#out + 1\]"
cosmic/format/init.tl` is 12, measured 2026-08-24 at 9bcb0f7d), one
fragment per token, per space, per indent run and per newline — so a
2161-token module pushes several thousand entries into a single growing
table before one final `table.concat`.

## Hypothesis
Buffer a LINE and concat it once per line, appending the line's string
to `out`: the accumulator then grows with lines, not tokens, and the
per-line buffer table is reused across lines. Reuse the same measurement
shape 3IK8EOci uses — `format_module_source`'s `alloc_kb` (1478.08
before that item lands) is deterministic and is the honest read; wall
clock on this scenario is ±4.7%.

Unproven: the fragments are mostly existing strings (`item.tk`), so what
this removes is table growth, not string allocation. Measure before
committing to it — a run that does not move `alloc_kb` or wall clock is
a rejected hypothesis to record and end, not a diff to land.
