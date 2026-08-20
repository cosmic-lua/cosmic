## Evidence

2026-08-20 audit at main 0b2907b9, by reading. `_fuzz/shrink.tl:94-99`:
after an unsuccessful deletion pass, `granularity = granularity * 2`
with no clamp to `#current`, and the `while granularity <= #current`
guard then exits — standard ddmin clamps to `min(2g, n)`. Single-draw
chunk deletion is reached only when `#current` happens to be a power
of two on the doubling path, so results are less minimal than the
algorithm intends (no unsoundness: every accepted candidate is
verified failing). A 1-draw sequence also never tries the empty
candidate (granularity starts at 2 > 1). Related doc rot found in the
same pass: `_fuzz/source.tl:4-6` still says shrinking "is a future
slice / no shrinking exists yet", false since #1292.
