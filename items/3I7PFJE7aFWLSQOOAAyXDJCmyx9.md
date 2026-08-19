> Capture note, 2026-08-19: attach under 3I1j7yQA (the cosmic.fuzz
> epic) when a plan slot opens — the epic's child 4, independent of the
> draw-recording chain.

## Goal

G5 — the cosmic.fuzz epic's per-input budget: a property that stops
terminating is attributed to its input instead of hanging the run. The
need is already in the tree — `_fuzz/sse_fuzz_test.tl` hand-rolls a
per-property step bound (`Drained.is_bounded`) because a streaming
parser can fail to terminate; one property solving it locally is the
epic's stated signal that it belongs in the driver.

## Change

Mechanism verified 2026-08-19 against the pinned cosmic binary:
`debug.sethook(fn, "", N)` fires after N VM instructions inside a
`pcall`ed property, `error()` from the hook unwinds to the pcall, and
the hook clears cleanly — an infinite Lua loop is caught and
attributed. (What it cannot catch — a hang inside a C call — is the
crash-isolation child's territory, out of scope here.)

1. **`_fuzz/driver.tl`** (155 lines): `Options.budget: integer` — VM
   instructions per property invocation, default 50_000_000 (measure
   the slowest existing property's instruction count during
   implementation and set the default at least 100x above it; record
   the measurement in the doc comment). Around each property call:
   set the count hook to error with a distinguishable message; clear
   it in every exit path. A budget failure reports like any property
   failure — seed, iteration, input, plus `budget=<n> exceeded` — so
   the replay workflow is unchanged.
2. **`_fuzz/sse_fuzz_test.tl`**: delete the hand-rolled
   `Drained.is_bounded` bound in favor of the driver budget; the
   property keeps its semantic assertions.
3. **Tests**: a property that loops forever fails within the budget
   naming seed and iteration; a property that finishes normally is
   unaffected; the hook is cleared after both (a subsequent draw-heavy
   property runs to completion).

## Non-goals

- no wall-clock timeout and no C-hang detection — that requires child
  processes (the crash-isolation child, `cosmic.child`), not a hook.
- no change to iteration counts, seeds, or reporting beyond the one
  added field.

## Acceptance

- `bin/cosmic --make test _fuzz/` ends `test: PASS`.
- `git grep -c "is_bounded" -- _fuzz/sse_fuzz_test.tl` prints 0.
- `bin/cosmic --make ci` ends `ci: PASS`.

## Enablement

none needed — the mechanism is pre-verified against the shipping
binary (probe recorded above), and the one calibration step (the
default budget) is written into the Change with where to record it.
