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

## Bounced 2026-08-20: the hook slot is not free under the coverage stage

Implemented as specced and measured; the mechanism works exactly as
pre-verified in a plain run, and fails structurally in an instrumented
one. `bin/cosmic --make test _fuzz/` passed with the budget armed
(including a looping-property test failing at `budget=100000 exceeded`
naming seed and iteration), but the Acceptance's `--make ci` cannot
pass: a Lua VM has ONE debug-hook slot per thread, and the coverage
stage owns it.

- Under `--make coverage` the collector is `cosmo.cov`'s C hook
  (`cosmic/coverage/init.tl:48,143`); `debug.gethook()` then returns the
  string `"external hook"`, which Lua can neither call (forwarding
  crashes: `attempt to call a string value`) nor reinstall. Plain
  clobbering measured: `_fuzz/driver.tl` coverage 98.2% -> 76.5%,
  `_fuzz/source.tl` 75.6% -> 35.7%, ratchet FAIL — arming the budget
  turns coverage off for the rest of the process.
- Forwarding works only for a Lua incumbent; the instrumented stage's
  incumbent is C. Verified by implementing it: the seven fuzz files
  then crash under `--make coverage` as above.

Useful measurements to keep: costliest property invocation in the tree
is tar_mutation_totality at <23k VM instructions (count hook,
1000-instruction granularity, 2026-08-20), so the spec's 50M default is
>2000x headroom. tl's `debug.gethook` declaration returns only
(HookFunction, integer) — the runtime's second value is the mask string
and the third (count) is undeclared.

The decision the re-refine must settle — who owns the hook slot when
both the budget and the collector want it:

1. **Stand down under an occupied slot**: budget arms only when
   `debug.gethook()` is nil. Cost: the ci coverage stage (where CI runs
   tests) gets no hang protection, and deleting sse's hand-rolled bound
   then REGRESSES that stage (the old bound caught yield-forever loops
   everywhere); the budget tests must skip under instrumentation, which
   lowers committed coverage floors for driver_test.tl.
2. **Sandwich**: `coverage.stop()` / arm / run / disarm /
   `coverage.start()`. Cost: every property body's lines drop out of
   instrumented coverage — the six fuzz test files' committed floors
   crater; a gate materially weakened.
3. **C-side budget**: `cosmo.cov`'s hook already fires per line; give
   the C collector an instruction/line budget (or hook composition)
   upstream in whilp/cosmopolitan, and the driver uses it when present.
   Cross-repo — the board's `repo:` field (PR #1286, in rework) is the
   vehicle; correct long-term, not a one-slice fix here.

Option 1 with the sse deletion NARROWED (keep sse's bound until the
budget is armed everywhere) is the smallest honest slice; option 3 is
where this wants to end up. Neither is this implementer's call to make
mid-slice.
