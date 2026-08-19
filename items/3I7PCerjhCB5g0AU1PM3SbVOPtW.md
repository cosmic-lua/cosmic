> Capture note, 2026-08-19: attach under 3I1j7yQA (the cosmic.fuzz
> epic) when a plan slot opens — it is that epic's child 2, unblocked
> now that the seedable source (3I1iGY7Z, PR #1277) has landed.

## Goal

G5 — the cosmic.fuzz epic's minimization substrate: a fuzz input is a
recorded sequence of draws, so shrinking (the epic's child 3) can
operate on the choice sequence instead of on opaque output bytes.

## Change

Measured 2026-08-19 at `bff1007`: `cosmic/rand.tl` (230 lines) landed
`Source` (`int`, `float`, seedable via `insecure_source(seed)`, line
170); `_fuzz/driver.tl` (155 lines) still seeds GLOBAL `math.random`
and its `Options.gen` is `function(): string` — the migration the
epic's child 1 named is this slice's first half.

1. **New `_fuzz/source.tl`**: `record Recorder` wrapping a
   `rand.Source` — same `int`/`float` surface, appending each draw
   (`{kind, lo, hi, value}`) to a `draws` list; `replay(draws)` returns
   a source that feeds the recorded values back in order (and fails
   loudly past the end). Internal to `_fuzz` — the epic forbids
   publishing before minimization exists.
2. **`_fuzz/driver.tl`**: `Options.gen` becomes
   `function(src: source.Recorder): string`; the driver creates one
   `Recorder` per iteration from `rand.insecure_source(seed +
   iteration)` and stops touching `math.random`/`math.randomseed`
   entirely. The failure message keeps seed and iteration, drops
   nothing, and adds `draws=<n>` (the recorded sequence length —
   minimization's future input). Base64 input reporting stays.
3. **Migrate the six `_fuzz/*_fuzz_test.tl` generators** mechanically:
   `math.random(a, b)` → `src:int(a, b)`, `math.random()` →
   `src:float()`. Property bodies untouched.
4. **Tests** (`_fuzz/driver_test.tl` or beside it, matching the
   existing test layout): same seed → identical draw sequence and
   identical generated input; `replay` of a recorded sequence
   regenerates the same input with the generator function itself;
   over-reading a replay fails with a message naming the position.

## Non-goals

- no shrinking (child 3), no timeout/budget (a sibling), no corpus
  files, no `cosmic.fuzz` publishing, no property-body rewrites.
- reproducibility across cosmic RELEASES stays explicitly unpromised
  (rand.tl's own doc, lines 162–164).

## Acceptance

- `bin/cosmic --make test _fuzz/` ends `test: PASS` over all fuzz
  files.
- `git grep -c "math.random" -- _fuzz/` prints 0.
- `FUZZ_SEED=7 bin/cosmic --make test _fuzz/json_fuzz_test.tl` twice
  produces byte-identical output (determinism proof).
- `bin/cosmic --make ci` ends `ci: PASS`.

## Enablement

none needed — the landed `rand.Source` is the enabler this waited for;
the six generator call sites migrate by the two mechanical rewrites
named above.
