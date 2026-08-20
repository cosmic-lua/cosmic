## Goal

G5 — the cosmic.fuzz epic's per-input budget: a property that stops
terminating is attributed to its input instead of hanging the run. The
need is already in the tree — `_fuzz/sse_fuzz_test.tl` hand-rolls a
per-property step bound (`Drained.is_bounded`) because a streaming
parser can fail to terminate; one property solving it locally is the
epic's stated signal that it belongs in the driver.

## Evidence

Mechanism verified 2026-08-19 against the pinned cosmic binary:
`debug.sethook(fn, "", N)` fires after N VM instructions inside a
`pcall`ed property, `error()` from the hook unwinds to the pcall, and
the hook clears cleanly — an infinite Lua loop is caught and attributed.
(A hang inside a single C call cannot be caught this way; that is the
crash-isolation child's territory.)

**Bounce, 2026-08-20 — the hook slot is not free under the coverage
stage, and the first implementation died on it.** A Lua VM has ONE
debug-hook slot per thread, and `--make coverage` (the stage `--make
ci` runs tests through) owns it with `cosmo.cov`'s C line hook
(`cosmic/coverage/init.tl:48,143`). Measured: plain clobbering turned
coverage off for the rest of each test process (`_fuzz/driver.tl`
98.2% -> 76.5%, `_fuzz/source.tl` 75.6% -> 35.7%, ratchet FAIL);
forwarding is impossible for a C incumbent (`debug.gethook()` returns
the string `"external hook"` — calling it crashes). tl's `gethook`
declaration exposes only two returns; the runtime's second value is the
mask string.

Measurements to reuse: the costliest property invocation in the tree is
tar_mutation_totality at <23k VM instructions (count hook at
1000-instruction granularity, 2026-08-20), so a 50M default carries
>2000x headroom.

## The settled decision (this refine, 2026-08-20)

The budget arms only when the hook slot is FREE (`debug.gethook()`
returns nil): plain `--make test` runs — including pr.yml's fuzz lane
and fuzz.yml's deep fuzz, the long-running exposure — are protected;
the instrumented coverage stage stands down rather than killing
collection (one slot) or costing every property body its line counts
(a stop/arm/start sandwich). The C-side alternative — the collector's
hook also enforcing a budget, letting both coexist — is real but
cross-repo (whilp/cosmopolitan) and filed separately; it is not this
slice.

## Change

1. **`_fuzz/driver.tl`** (161 lines at `968fabb`): `Options.budget:
   integer` — VM instructions per `check()` invocation, default
   50_000_000 (the 23k measurement above, recorded in the doc comment).
   Around each `pcall(opts.check, input)`: when `debug.gethook()`
   returns nil, install
   `debug.sethook(function() error(BUDGET_MESSAGE, 0) end, "", budget)`
   and clear it in every exit path (tl's `sethook` declaration has no
   argless form; `debug.sethook(function() end, "")` is the same off
   state — Lua turns the hook off when mask and count are both zero).
   When the slot is occupied, skip arming — the occupant is the
   coverage collector, and the stand-down is documented on
   `Options.budget`. A budget failure reports like any property failure
   — seed, iteration, input, draws, plus `budget=<n> exceeded` (match
   the caught value against BUDGET_MESSAGE, raised at level 0 so the
   comparison is exact).
2. **`_fuzz/sse_fuzz_test.tl`**: delete the hand-rolled
   `Drained.is_bounded`/`steps`/`max_steps` machinery; `drain` loops to
   the terminal nil. The properties keep their semantic assertions
   (terminal_error, event comparison). Accepted, stated risk: under the
   instrumented coverage stage the budget stands down, so a
   yield-forever loop there hangs to the CI job timeout — the same
   exposure every other fuzz file already has today; the fuzz lane on
   the same commit fails fast with attribution.
3. **Tests** (`_fuzz/driver_test.tl`): (a) a property that loops
   forever fails within a small explicit budget, message naming seed,
   iteration and `budget=<n> exceeded`; (b) a property that finishes
   normally passes under an explicit budget; (c) the hook is cleared
   between runs — after the budget-failing run, a draw-heavy run whose
   total instruction count is far past the previous small budget still
   completes. Tests (a) and (c) need the slot: bracket them with
   `local was = coverage.is_running(); if was then coverage.stop() end`
   / `if was then coverage.start() end` (`cosmic.coverage`'s public
   nestable pair — stop keeps counts, a bare start() re-arms the hook,
   both verified at cosmic/coverage/init.tl:274,153,133), so they run
   meaningfully under both the plain and the instrumented suite.

## Non-goals

- no wall-clock timeout and no C-hang detection — that requires child
  processes (the crash-isolation child, `cosmic.child`), not a hook.
- no change to iteration counts, seeds, or reporting beyond the one
  added field.
- no change to `cosmic/coverage/**` and no C-side (cosmo.cov) budget —
  the cross-repo composition is its own capture, not this slice.

## Acceptance

- `bin/cosmic --make test _fuzz/` ends `test: PASS (7 files)`.
- `git grep -c "is_bounded" -- _fuzz/` prints nothing and exits 1
  (zero occurrences — `grep -c` with a pathspec emits per-file counts
  only for files that match).
- `bin/cosmic --make ci` ends `ci: PASS` — this is the gate the first
  implementation failed: it proves the budget and the instrumented
  coverage stage coexist.

## Enablement

none needed — the stand-down rule, the coverage bracketing API, the
off-state idiom, and the tl declaration quirks are all measured above;
the first implementation's failure mode is recorded so it cannot recur
unmeasured.
