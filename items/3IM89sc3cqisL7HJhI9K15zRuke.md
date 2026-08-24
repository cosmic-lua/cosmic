Split out of 3IK8EOci during its 2026-08-24 refinement, which took only
the token-copy hypothesis so the diff stays one hypothesis.

## Problem
`mark_type_params` (`cosmic/format/init.tl:36`, measured 2026-08-24 at
9bcb0f7d) walks a line's items looking for `function ... < ... > (` and
marks the span `_tight_before`. It is called per line from inside the
emit loop (line 271), so every line is scanned twice: once by this pass
and once by the emit walk that immediately follows it.

## Hypothesis
Fold the marking into the single emit walk, or hoist it to run once over
the whole item list before the loop. Its own comment says `needs_space`
alone cannot tell `f<T>(` from a `<` comparison in its four-token
window, so whatever shape this takes must keep that lookahead intact.

Acceptance shape is 3IK8EOci's: `--make ci` (the fmt stage re-formats
every tracked source and fails on any byte difference) plus the
`format_module_source` row. Expected win is smaller than the token-copy
one — measure first, and record a rejection rather than landing a
neutral change.
