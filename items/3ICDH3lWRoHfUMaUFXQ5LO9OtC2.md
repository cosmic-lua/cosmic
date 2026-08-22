## Goal

G5 — adversarial verification, via the cosmic.fuzz epic (3I1j7yQA). The
VM instruction budget (#1291) exists so a non-terminating property fails
with its input named instead of hanging the suite. Shrinking runs with
the hook off, so the moment a budget failure is minimized the guarantee
is gone: the run hangs, or burns to the child's wall clock and reports
an empty input. A backstop that stops working at the exact moment it is
needed is worse than none, because the suite looks protected.

## Evidence

2026-08-20 audit, re-measured and re-reproduced 2026-08-22 against
`origin/main` at `2ee12b3e` on a built tree.

`_fuzz/driver.tl` disarms before it shrinks. `run_in_process` calls
`disarm_budget()` (driver.tl:157) and only then
`shrink.shrink(opts.gen, opts.check, rec.draws)` (driver.tl:170).
`_fuzz/shrink.tl`'s `still_fails` (shrink.tl:35-46) pcalls `prop.check`
on every candidate with no hook armed and no per-call bound:
`MAX_SHRINK_ATTEMPTS = 20000` (shrink.tl:14) bounds the CALL COUNT, not
what one call may spend.

**Reproduced, both directions.** A probe test placed at
`_fuzz/zzhang_test.tl`, running `driver.run_unisolated` inside the
file's `without_coverage` helper (the collector owns the VM's one hook
slot, so the budget stands down under the instrumented stage):

- Property `looper_that_draws` — `gen = driver.bytes(src, 8)`,
  `check = while true do end`, `budget = 100000`. On `main`,
  `timeout 120 o/bin/cosmic --make test _fuzz/zzhang_test.tl` was
  **Terminated at 120s**. The first iteration's check is caught by the
  budget as designed; shrink then reruns the same loop unbudgeted and
  never returns.
- Property `candidate_loops` — the same gen, `budget = 100000`, and a
  check that returns `false, "too big"` on inputs of 4 bytes or more
  but loops below that. The generated input fails ORDINARILY (no
  budget involved), and only a shrink CANDIDATE loops. Also
  **Terminated**, at 90s. So this is not only a budget-failure bug: any
  property whose check can loop on a smaller input hangs the same way.

Under `run_unisolated` there is no wall clock at all, so both hang
forever. Under `run()` the child burns to its wall-clock backstop and
reports `hung: exceeded <n>ms` with an empty input — the attribution
loss the budget was landed to prevent.

**The existing tests pass only by construction.**
`driver_test.tl`'s two looping-budget tests —
`test_a_looping_property_fails_within_its_budget` (lines 245-265) and
`test_the_budget_hook_is_cleared_between_runs` (lines 287-314) — both
use `gen = function(_src) return "input" end`, which draws NOTHING.
`rec.draws` is empty, `shrink_structure`'s `granularity <= #current`
guard is false immediately, `shrink_values` iterates an empty list, and
`prop.check` is never called. Give either test a gen that draws and it
hangs, which is exactly what the probe above did.

**Measured headroom** (`wc -l`, on `origin/main` at `2ee12b3e`):

```
_fuzz/driver.tl       390
_fuzz/driver_test.tl  406
_fuzz/shrink.tl       237
_fuzz/shrink_test.tl  106
```

**Callers of the function this change touches.** `shrink.shrink` has
five call sites, none of whose signatures move under the Change below
(`git grep -n "shrink.shrink" -- _fuzz`): `driver.tl:170`, and
`shrink_test.tl` lines 32, 57, 81, 103.

## Change

Two files. `_fuzz/shrink.tl` is NOT touched: the budget hook is the
driver's (it owns `arm_budget`/`disarm_budget` and the one VM hook
slot), and shrink.tl cannot require driver.tl without a circular
require. The driver therefore hands shrink a check that is already
budget-capped, which needs no signature change anywhere and leaves
shrink's four test call sites alone.

### 1. `_fuzz/driver.tl` — pass shrink a budgeted check

Add one local, directly above `failure()`:

```teal
--- Wrap a property's check so each call runs under the budget hook.
--- Shrinking reruns check on every candidate, and it must not do so
--- unbudgeted: the candidate that loops is the very input the budget
--- exists to attribute. A throw becomes a false return, which is what
--- shrink's still_fails already makes of one, so a budget-exceeded
--- candidate reads as still failing and is kept.
--- @param check function The property's check
--- @param budget integer VM instructions one call may spend
--- @return function The same contract, budget-capped per call
local function budgeted(
    check: function(input: string): boolean, string, budget: integer
  ): function(input: string): boolean, string
  return function(input: string): boolean, string
    local armed = arm_budget(budget)
    local ok, held, why = pcall(check, input)
    if armed then
      disarm_budget()
    end
    if not ok then
      return false, tostring(held)
    end
    if not held then
      return false, tostring(why or "no detail")
    end
    return true
  end
end
```

Then change the one call site (driver.tl:170) from

```teal
local minimized_draws = shrink.shrink(opts.gen, opts.check, rec.draws)
```

to

```teal
local minimized_draws = shrink.shrink(
  opts.gen, budgeted(opts.check, budget), rec.draws)
```

`opts.gen` is deliberately NOT wrapped: `run_in_process` already calls
it outside the budget (driver.tl:153, before `arm_budget`), and this
item does not change where the budget's edge sits.

Correct the `disarm_budget()` call site's surroundings only insofar as
the doc comment on `Options.budget` claims the budget bounds "one
check() invocation" — it now bounds every check invocation including
shrink's candidates. Amend that clause; change no other prose.

### 2. `_fuzz/driver_test.tl` — make the two dead tests live, and add the candidate case

- `test_a_looping_property_fails_within_its_budget` (line 245): replace
  `gen = function(_src: source.Recorder): string return "input" end`
  with `gen = function(src: source.Recorder): string return
  driver.bytes(src, 8) end`. Every existing assertion in the test
  stands unchanged (`seed=`, `iteration=1`, `budget=100000 exceeded`) —
  measured with the fix applied, the message is
  `looper_that_draws: seed=1 iteration=1 input(base64)= draws=6:
  budget=100000 exceeded`.
- `test_the_budget_hook_is_cleared_between_runs` (line 287): the same
  substitution for its `arms_a_tiny_budget` property's gen. Its second
  half (`draw_heavy_afterwards`) is unchanged.
- Add `test_a_shrink_candidate_that_loops_is_caught`, called on the line
  after its `end`, inside `without_coverage`: `gen = driver.bytes(src,
  8)`, `budget = 100000`, and a check that loops on inputs shorter than
  4 bytes and returns `false, "too big"` otherwise. Assert the run
  returns false and that the message contains `too big` — the ORIGINAL
  failure's detail, not the candidate's — which is what pins that a
  looping candidate is caught without changing what gets reported.

## Non-goals

- **`_fuzz/shrink.tl` is not touched.** No new parameter on
  `shrink.shrink`, no arm/disarm callbacks threaded through it, no new
  leaf module for the hook. The four `shrink_test.tl` call sites stay
  as they are.
- **`MAX_SHRINK_ATTEMPTS` is not changed**, and no per-candidate
  wall-clock bound is added. The VM instruction budget is the only
  mechanism this item touches.
- **The failure message's shape does not move.** `failure()`'s
  signature, the `"budget=%d exceeded"` text and the
  `seed=/iteration=/input(base64)=/draws=` grammar are unchanged;
  `driver_test.tl` asserts substrings of all of them.
- **Not the minimized-input/detail pairing.** A shrunk run still
  reports the ORIGINAL iteration's detail and the minimized input's
  draw count. That mismatch is item 3ICDHHW7 and must not be fixed
  here.
- **Not the wall-clock backstop.** Item 3ICDGiWd (PR #1309) owns the
  child timeout; this diff must not touch `DEFAULT_TIMEOUT_MS`,
  `TIMEOUT_PER_ITER_MS` or `timeout_for`.
- **`opts.gen` stays outside the budget**, as it is today.
- **No `.cosmic-coverage` regeneration is expected.** Both files
  already carry a row and no file is added. If the ratchet does
  complain, run exactly the regen command its failure message prints
  (`bin/cosmic --make coverage --baseline`) and commit the result —
  never weaken the gate any other way.

## Acceptance

Every command is run from the repository root and must print the
literal verdict line quoted after it.

1. **The full gate holds.**

       bin/cosmic --make ci

   Verdict line ends `ci: PASS`.

2. **The driver's tests pass, including the new one.**

       bin/cosmic --make test _fuzz/driver_test.tl

   Verdict line ends `test: PASS`. The runner's `✓` line reports one
   more test function than `main`'s count for that file, and the whole
   file completes in under 10 seconds — on `main`, giving either
   looping test a drawing gen never terminates, so a bounded wall time
   IS the regression check. Quote the `✓` line with its wall time.

3. **Shrinking is not the slow part.** The two live looping tests
   measured 25ms and 42ms as probes with the fix applied; the file as a
   whole measured 302ms before this change.

       bin/cosmic --make test _fuzz/shrink_test.tl

   Verdict line ends `test: PASS` — shrink.tl is untouched, and this
   proves it.

4. **Every fuzz property still passes at the default depth.**

       bin/cosmic --make test _fuzz

   Verdict line ends `test: PASS`.

5. **`_fuzz/shrink.tl` is byte-identical to its base.**

       git diff --stat origin/main -- _fuzz/shrink.tl

   Prints nothing.

6. **Caps hold.**

       wc -l _fuzz/driver.tl _fuzz/driver_test.tl

   Both under 500. Measured budget: `driver.tl` 390 + ~27 = ~417, and
   `driver_test.tl` 406 + ~22 = ~428, both with room. If PR #1309 lands
   first it adds 31 lines to `driver.tl` and 30 to `driver_test.tl`
   (`~448` and `~458`) — still under, but re-run this command rather
   than trusting the arithmetic.

## Enablement

None needed, and no blocker. Every decision is settled to one point,
and the pick was verified before it was written down rather than
reasoned about:

- **The fix shape is proven, not proposed.** The `budgeted` wrapper
  above was applied to `_fuzz/driver.tl` on 2026-08-22, built, and run
  against both probe properties: `looper_that_draws` returned
  `budget=100000 exceeded` in **25ms** (from Terminated-at-120s), and
  `candidate_loops` returned `too big` in **42ms** (from
  Terminated-at-90s). Reverting the wrapper and rebuilding restored the
  hang. The Change section's code is that verified body verbatim.
- **Why a wrapper and not a signature change**: `still_fails` already
  turns a throw into "still fails", so a budget throw needs no new
  contract — returning `false` from the wrapper reaches the same
  `not held` branch. That is why shrink.tl needs no parameter, no
  callbacks and no leaf module, and why the four `shrink_test.tl` call
  sites are untouched.
- **No cast is needed.** The wrapper never returns `pcall`'s `any`
  values in a boolean slot: it branches and returns literal `false` or
  `true`, so the `-- cast:` justification rule has nothing to bite on.
- **The coverage interaction is settled**: the collector owns the VM's
  single debug-hook slot, so `arm_budget` returns false under the
  instrumented stage and the wrapper's `if armed then disarm_budget()
  end` is the same guard the driver's own loop uses. Every budget test
  in the file already runs inside `without_coverage`, and the new one
  must too.

**Sequencing.** This item and 3ICDGiWd (PR #1309, in `check`) both
touch `_fuzz/driver.tl` and `_fuzz/driver_test.tl`, in disjoint
regions: #1309 adds `TIMEOUT_PER_ITER_MS`, `timeout_for` and one line in
`isolate()`, while this one adds `budgeted` and changes the
`shrink.shrink` call inside `run_in_process`. No `blocked_by` edge is
warranted — whichever lands second merges `main` and re-runs its own
acceptance, and Acceptance #6 says to re-measure rather than trust the
arithmetic.
