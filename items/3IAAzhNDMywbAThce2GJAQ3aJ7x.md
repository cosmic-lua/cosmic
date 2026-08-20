> Capture note, 2026-08-20: this is the cosmic.fuzz epic's child 3
> (3I1j7yQA), specced now that child 2 (3I7PCerj, draw-recording
> source + replay) has landed — its own refinement note said child 3
> "is specced next AFTER 2 lands... its shape depends on the
> recorded-draw structure 2 commits to."

## Goal

G5 — the cosmic.fuzz epic's minimization deliverable: a failing fuzz
run reports a *minimized* input instead of the raw generated one, so a
user does not hand-bisect a multi-hundred-byte failure (epic
3I1j7yQA, "Children" item 3).

## Change

Measured 2026-08-20 at `d97cb5f0`: `_fuzz/driver.tl` is 211 lines (289
lines of headroom under the 500-line cap) and `_fuzz/source.tl` is 101
lines, unchanged by this slice. `_fuzz/source.tl`'s `Draw` record
already carries `kind`, `lo`, `hi`, `ivalue`, `fvalue` — everything a
shrinker needs to read and rewrite a draw — and `source.replay(draws)`
already turns a draw list back into a `Recorder`-shaped source, so no
new source-level primitive is required.

1. **New `_fuzz/shrink.tl`** exporting
   `shrink(opts: driver.Options, draws: {source.Draw}): {source.Draw}, integer`
   (minimized draws, attempts spent). Internal helper
   `still_fails(opts, draws): boolean, string, string` (still-fails,
   regenerated input, failure detail) that:
   - calls `source.replay(draws)` to get a `Recorder`, then
     `pcall(opts.gen, rec)` — a throw here (replay ran out of draws,
     or hit a draw of the wrong kind because a shortened/edited
     sequence changed the generator's control flow) means the
     candidate is **invalid**, not failing, and `still_fails` returns
     `false`.
   - on a valid regenerated input, calls `pcall(opts.check, input)`
     exactly as `driver.run` does: a thrown error OR a `false` return
     both count as "still fails" (this slice does not distinguish
     *which* invariant broke — see Non-goals).
2. **Structural shrink**: ddmin (Zeller) chunk deletion over the draw
   list — start at granularity 2, try removing each contiguous chunk
   of `ceil(#draws/granularity)` draws, keep the first removal for
   which `still_fails` holds, reset granularity to `max(granularity -
   1, 2)` on a successful removal, else double it; stop when
   granularity exceeds the remaining draw count.
3. **Value shrink**: one left-to-right pass over the (now structurally
   minimal) draws. For each `kind == "int"` draw, binary-search
   between its `lo` and its current `ivalue` for the smallest value
   that still fails (replace just that one draw, re-run
   `still_fails`); for each `kind == "float"` draw, try `0.0` first,
   then bisect between `0.0` and the current `fvalue` the same way.
   Keep the smallest/closest-to-zero value found; a draw the search
   cannot shrink keeps its original value.
4. **Attempt budget**: a package-level `MAX_SHRINK_ATTEMPTS = 20000`
   (every `still_fails` call — structural or value — counts one),
   chosen above the costliest generator in the tree today:
   `_fuzz/compress_fuzz_test.tl`'s round-trip generator draws up to
   4097 values per input (`ROUND_TRIP_MAX_LEN = 4096`, line 12). One
   counter is threaded through both the structural and value-shrink
   phases (a single running total, not a per-phase budget); `shrink`
   stops and returns the best draws found so far the moment the
   budget is spent, never throws for running out of budget.
   Neither phase is guaranteed to find a global minimum — binary
   search over an int/float draw assumes the failure is monotonic in
   that value, which need not hold for an arbitrary property; this
   slice reports whatever the bounded search converges to, not a
   provably-smallest input.
5. **`_fuzz/driver.tl` wiring**: in `run`, on a failing iteration,
   call `shrink.shrink(opts, rec.draws)`, replay the returned draws
   through `opts.gen` once more to get the minimized input, and report
   *that* input and its draw count in the failure message in place of
   the raw ones — same `failure()` shape and field order (seed,
   iteration, input, draws, detail), so existing message-shape
   assertions in `_fuzz/driver_test.tl` keep passing; only the values
   substituted into `input=` and `draws=` change.

## Non-goals

- no corpus persistence (`testdata/`, a sibling child), no crash
  isolation via `cosmic.child` (a sibling child), no coverage-guided
  generation, no discard accounting (`assume()`), no `cosmic.fuzz`
  publishing move. `_fuzz/shrink.tl` stays internal to `_fuzz`, same
  as `_fuzz/source.tl`.
- does not classify failures by cause: a candidate that fails `check`
  for *any* reason (a different assertion, a different thrown error,
  even a budget-exceeded from `driver.arm_budget`) counts as "still
  fails" during shrinking. A shrunk report describing a different
  failure than the original is a known limitation of this slice, not
  a bug to fix here.
- does not change `_fuzz/source.tl` — `Draw`, `new`, and `replay` are
  read-only inputs to this slice.
- does not touch the six `*_fuzz_test.tl` generator bodies.
- no change to `Options`, `bytes`, or `mutate`.

## Acceptance

- `bin/cosmic --make test _fuzz/` ends `test: PASS` over all fuzz
  files, including new tests in `_fuzz/shrink_test.tl`:
  - a property that fails whenever `driver.bytes(src, 64)` produces a
    string longer than 5 bytes shrinks to an input of exactly 6 bytes.
  - a property that fails whenever a drawn `src:int(0, 1000)` exceeds
    200 shrinks that draw to exactly 201.
  - a property whose generator diverges under replay (draws a variable
    number of values depending on an earlier draw) shrinks without
    throwing — `shrink` returns normally, not an error.
  - a stress case whose original draws exceed 5000 entries shrinks
    within `MAX_SHRINK_ATTEMPTS` calls to `still_fails` (assert
    `attempts <= 20000`).
- `bin/cosmic --make test _fuzz/driver_test.tl` still passes unchanged
  (message-shape assertions unaffected) plus a new
  `test_failure_message_reports_a_minimized_input` asserting the
  reported `input=` is no longer than a small bound (≤ 8 base64 bytes)
  for a property that fails on any input longer than 2 bytes, given a
  256-byte-capable generator.
- `git grep -c "MAX_SHRINK_ATTEMPTS" -- _fuzz/shrink.tl` prints 1.
- `bin/cosmic --make ci` ends `ci: PASS`.

## Enablement

none needed — `_fuzz/source.tl`'s `Draw` record and `replay` (landed
by child 2, 3I7PCerj, PR #1290) are the only prerequisites and both
are already on `main`.
