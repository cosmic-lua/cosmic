## Goal
Cut cosmic.fuzzy.find_similar's per-op cost with an identical result
set — serves the parent perf outcome (3HyRcd9F). Scouting evidence
(research pass 2026-08-23, os.clock loops, medians of 3+, NOT the
_perf gate): the `fuzzy_find_similar` scenario at ~608µs/52KB, probed
579.5µs → 354.5µs (−39%) from the change below with an identical
match set. Accept/reject is the harness at pull time, not these
numbers.

## Change
Edit `cosmic/fuzzy.tl` only (measured `wc -l cosmic/fuzzy.tl` = 134,
so ~366 lines of headroom under the 500-line cap; the change adds
~30 lines).

1. Add two module-level scratch arrays shared across calls, declared
   once near the top of the module:
   `local dp_prev: {integer} = {}` and `local dp_curr: {integer} = {}`.
   They replace the two fresh `{}` tables allocated per call at
   `cosmic/fuzzy.tl:25-26`.

2. Add an internal helper
   `local function distance_within(a: string, b: string, max_distance: integer): integer`.
   It is the current two-row Levenshtein of `distance()` (`fuzzy.tl:11-50`)
   with two changes:
   - it fills and reads `dp_prev`/`dp_curr` (indices `0..lb`) instead of
     allocating; because every read is of a cell written earlier in the
     same call (init loop writes `prev[0..lb]`; each row writes
     `curr[0..lb]` before the next row reads it), reused arrays carry no
     stale value into any read, and cells past `lb` are never read.
   - after computing each row `i`, it takes that row's minimum over
     `j = 0..lb`; if the minimum is `> max_distance` it returns
     `max_distance + 1` immediately (early abort). This is sound: once
     every cell of a row exceeds `max_distance`, every cell of every
     later row does too, so the final distance also exceeds it — the
     helper only substitutes a sentinel in the regime where the true
     distance is already past the threshold, and returns the exact
     distance whenever it is `<= max_distance`.
   Keep the existing early returns (`la==0`, `lb==0`, `a==b`) and the
   shorter-string swap.

3. In `find_similar` (`fuzzy.tl:74-120`), replace the
   `local dist = distance(query_lower, candidate_lower)` call at
   `fuzzy.tl:95` with
   `local dist = distance_within(query_lower, candidate_lower, max_distance)`.
   The surrounding `if dist <= max_distance then` guard, the
   length-difference gate (`fuzzy.tl:94`), the dedup-on-lowercase, the
   sort, and the limit trim all stay exactly as they are. Because
   `distance_within` returns the exact distance for every candidate that
   passes `dist <= max_distance`, the stored `distance` field and the
   whole result set (values, distances, order) are unchanged.

The public `distance()` function keeps its current body and contract
(it is a separate callable from the helper).

## Non-goals
- Do NOT change the public `distance()` function's signature, body, or
  observable behavior. Its callers (`_cli/require_hints.tl:114-115`
  and `cosmic/fuzzy_test.tl`) must stay green unchanged. `distance()`
  is not switched to the shared arrays or the early abort — those live
  only in the internal helper for `find_similar`.
- Do NOT change `find_similar`'s observable behavior: same match set,
  same per-match `distance`, same sort (distance then value), same
  dedup-on-lowercase, same `limit` semantics. Its callers
  (`cosmic/doc/show.tl:408,438`) must see identical results.
- Do NOT implement the Ukkonen / diagonal-band variant — that is a
  separate, larger algorithmic change and is out of scope for this
  slice.
- Do NOT weaken, rename, or edit the `fuzzy_find_similar` scenario or
  its `check()` in `_perf/bench/fuzzy_bench.tl`.
- The helper must not yield (no coroutine boundary): the shared arrays
  are safe only under the single-threaded VM assumption.

## Acceptance
- Correctness/style floor: `bin/cosmic --make ci` ends `ci: PASS`.
- Behavior preserved (narrow check): `bin/cosmic --make test
  cosmic/fuzzy_test.tl` passes — the existing distance and
  find_similar tests (exact match, typo, case-insensitive, sorted,
  tiebreaker, no-match, dedup, default max_distance, limit) pin the
  result contract.
- Scenario still returns the pinned match set: `bin/cosmic --make run
  _perf/run.tl --only fuzzy --out o/perf/current.json` runs the
  `fuzzy_find_similar` scenario whose own `check()` requires exactly
  one match, value `install`, distance `1`; a wrong-but-fast matcher
  fails it.
- Performance gate (optimize skill loop): from a clean tree, baseline
  the unmodified build into `o/perf/baseline.json`, apply the change,
  rebuild, then `bin/cosmic --make run _perf/gate.tl compare
  o/perf/baseline.json o/perf/current.json o/perf/selfb.json` ends
  `perf-compare: PASS` with `fuzzy_find_similar` improved beyond its
  noise bar and no scenario regressed. (Baselines are machine-specific
  and live only in `o/`; never commit `o/perf/*.json`.)

## Enablement
none needed — the change is confined to one existing public module
under conventions already in AGENTS.md; the `fuzzy_test.tl` suite and
the `_perf` scenario's `check()` already gate the exact result
contract this change must preserve, so a wrong pruning is caught by a
command the Acceptance cites rather than at review.
