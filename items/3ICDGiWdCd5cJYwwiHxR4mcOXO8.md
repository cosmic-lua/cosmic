## Goal

G5, via the cosmic.fuzz epic (3I1j7yQA): the deep fuzz lane's reds mean
something. Today `_fuzz/driver.tl`'s wall-clock backstop is a constant
sized for the 256-iteration default and applied to a child running
whatever `FUZZ_ITERS` says, so `.github/workflows/fuzz.yml`'s nightly
`FUZZ_ITERS=50000` kills healthy properties and reports them as hangs
with an empty input. A lane that reds on its own depth setting teaches
everyone to ignore it.

## Evidence

2026-08-20 audit, reproduced on a local build at main 0b2907b9.
`_fuzz/driver.tl:48` sets `DEFAULT_TIMEOUT_MS = 30000`, applied at
driver.tl:256-257 to an isolated child's ENTIRE run of `iters`
iterations — sized for the 256-iteration default, while
`.github/workflows/fuzz.yml` runs the deep lane at `FUZZ_ITERS=50000`.
Measured: `tar_fuzz_test.tl` at 2000 iters is ~2s/property; at 50000
`tar_mutation_totality` is killed at exactly 30s and reported
`seed=20260820 iteration=50000 input(base64)= draws=0: hung: exceeded
30000ms` — a red lane with an EMPTY input, indistinguishable from a
real hang. `compress_fuzz_test.tl` fails the same way (30.4s); sse
measured 24.7s locally, a flake on a slower CI container. The 09:00
UTC cron of 2026-08-20 ran before child 5 (#1294) merged at 12:39 UTC,
so the next cron is the first exposed run. Also contradicts
driver.tl:44-47's claim that the wall clock is "only reached when the
VM instruction hook cannot arm … or the hang is inside a single C
call" — at deep-lane depth it is the binding constraint in normal
operation. Fix shape: scale the child timeout with the iteration
count (or set it per-lane in fuzz.yml), keeping a floor for the
default depth.

## Measurement, 2026-08-22 against `origin/main` at 2ee12b3e

Re-measured to pin the scaling constant to observed cost rather than
taste. Each `*_fuzz_test.tl` was run twice through `o/bin/cosmic --make
test`, at `FUZZ_ITERS=1000` and `FUZZ_ITERS=4000`, reading the runner's
own per-file wall; the slope over that 3000-iteration span divides out
process startup, and dividing again by the file's property count gives
the per-iteration cost of ONE child, which is what the timeout bounds.

| file | 1000 iters | 4000 iters | properties | ms/iter/property |
|------|-----------:|-----------:|-----------:|-----------------:|
| `tar_fuzz_test.tl` | 3083ms | 12461ms | 3 | 1.04 |
| `compress_fuzz_test.tl` | 2549ms | 10985ms | 3 | 0.94 |
| `sse_fuzz_test.tl` | 497ms | 1897ms | 3 | 0.16 |
| `re_fuzz_test.tl` | 295ms | 1023ms | 3 | 0.08 |
| `url_fuzz_test.tl` | 304ms | 1090ms | 4 | 0.07 |
| `json_fuzz_test.tl` | 212ms | 663ms | 3 | 0.05 |

The costliest property in the tree costs **~1.05 ms per iteration**, so
at `FUZZ_ITERS=50000` its healthy run needs ~52s against a 30s cap —
which is the observed red, and it is arithmetic, not a flake.

Two more facts the change depends on, read from `main`:

- `Options.timeout_ms` is consumed once, in `isolate()`
  (`local timeout_ms = opts.timeout_ms or DEFAULT_TIMEOUT_MS`), and
  passed on to `spawn_isolated` and `bisect_crash`. Nothing else reads
  it.
- Exactly one caller sets it: `_fuzz/driver_test.tl:362` pins
  `timeout_ms = 200` on a property with `iters = 1`, to catch a real
  2000ms C-layer sleep. An explicit value must therefore stay ABSOLUTE
  — scaling it, or treating it as a floor, breaks that test and the
  intent behind it.

Headroom: `wc -l _fuzz/driver.tl` is 390 and `_fuzz/driver_test.tl` is
406, both under the 500-line cap (`_tool/lint.tl:24`), so this change
needs no new file. PR #1308 (board item 3IBFBWtc, corpus persistence)
is in flight over `_fuzz/driver.tl` and adds ~-16 lines net; it touches
neither the timeout constant nor `isolate()`, so the two changes are
independent, but whichever lands second merges the other's `driver.tl`.

## Change

One module and one test file. The rule lives in the driver, not in the
workflow, so every project using this driver gets it and not just this
repo's lane.

### 1. `_fuzz/driver.tl` — scale the wall clock with the iteration count

- Add a constant beside `DEFAULT_TIMEOUT_MS`:

  ```teal
  --- Wall-clock allowance per iteration, in milliseconds. The costliest
  --- property in this tree (tar_mutation_totality) measured ~1.05
  --- ms/iteration on a developer machine in 2026-08; ten times that
  --- leaves room for a CI container several times slower before a
  --- healthy deep-lane run is reported as a hang.
  local TIMEOUT_PER_ITER_MS = 10
  ```

- Add one local, directly above `isolate()`:

  ```teal
  local function timeout_for(opts: Options, iters: integer): integer
    if opts.timeout_ms then
      return opts.timeout_ms
    end
    return math.max(DEFAULT_TIMEOUT_MS, iters * TIMEOUT_PER_ITER_MS)
  end
  ```

  `DEFAULT_TIMEOUT_MS` is now the FLOOR rather than the value: at the
  256-iteration default it still binds (256 × 10 = 2560 < 30000), so
  nothing about shallow runs changes, and it only gives way past 3000
  iterations.

- In `isolate()`, replace `local timeout_ms = opts.timeout_ms or
  DEFAULT_TIMEOUT_MS` with `local timeout_ms = timeout_for(opts,
  iters)`. That one line is the whole behavioral change: the value
  already flows from there into `spawn_isolated` and `bisect_crash`.

- Export `timeout_for` on `DriverModule`, beside `run` and
  `run_unisolated`, so the rule can be asserted directly instead of by
  waiting out a real timeout. `_fuzz` is internal tooling, so this
  widens no published surface.

- Correct the two doc comments the current constant makes false:
  `DEFAULT_TIMEOUT_MS`'s own comment ("Only reached when the VM
  instruction hook cannot arm … or the hang is inside a single C call")
  is wrong at deep-lane depth and should say it is the floor of a
  budget that scales with the iteration count; the module comment's
  sentence about `Options.timeout_ms` should say the same in one
  clause.

### 2. `_fuzz/driver_test.tl` — one new test

Add `test_the_child_timeout_scales_with_the_iteration_count`, called on
the line after its `end` like every other test in the file, asserting
`driver.timeout_for` at four points and nothing else (it is a pure
function; no property runs, no child spawns, no clock is read):

- at the 256-iteration default, 30000 — the floor still binds;
- at 3000 iterations, 30000 — the floor binds right up to where the
  scaled value overtakes it;
- at 50000 iterations, 500000 — the deep lane's budget, ~10x the ~52s
  the costliest property actually needs;
- with `timeout_ms = 200` set on the options and 50000 iterations, 200
  — an explicit value is absolute, never scaled and never a floor.

## Non-goals

- **No change to `.github/workflows/fuzz.yml`.** A per-lane timeout
  would fix this repo's cron and leave every other consumer of the
  driver with the same constant; the driver owns the rule.
- **`Options.timeout_ms` stays an absolute override.** Not a floor, not
  a per-iteration rate. `driver_test.tl:362` depends on 200 meaning
  200ms, and a caller who names a wall clock means it.
- **No change to the bisection probes' budget.** `bisect_crash`
  respawns with FEWER iterations under the same timeout, so a probe can
  only finish sooner than the run that produced it; scaling each probe
  down separately buys nothing and adds a second rule.
- **No change to `DEFAULT_BUDGET` or the VM instruction hook.** This
  item is the wall clock only. The two backstops are independent and
  the budget is not implicated in the observed red.
- **Not the empty-input report.** A genuine timeout still reports
  `input(base64)= draws=0`, because `isolate()` has no failing input to
  name when the child never came back — the scaling removes the FALSE
  timeouts, and whether a real one should report differently is its own
  item, not this diff.
- **No change to `failure()`, the `"hung: exceeded %dms"` text, or any
  other message shape.** `driver_test.tl`'s substring assertions and
  the workflow's log expectations both read them.

## Acceptance

Every command is run from the repository root and must print the
literal verdict line quoted after it.

1. **The full gate holds.**

       bin/cosmic --make ci

   Verdict line ends `ci: PASS`.

2. **The driver's tests pass, including the new one.**

       bin/cosmic --make test _fuzz/driver_test.tl

   Verdict line ends `test: PASS`. The runner's own line reports 18
   test functions (17 today plus
   `test_the_child_timeout_scales_with_the_iteration_count`).

3. **Every fuzz property still passes at the default depth.**

       bin/cosmic --make test _fuzz

   Verdict line ends `test: PASS`.

4. **The deep lane's costliest property passes at deep-lane depth** —
   the red this item exists to remove, reproduced and then gone. Quote
   both the command and the runner's `✓` line with its wall time:

       FUZZ_ITERS=50000 o/bin/cosmic --make test _fuzz/tar_fuzz_test.tl

   Verdict line ends `test: PASS`. Against `main` the same command
   reports `hung: exceeded 30000ms`; show both runs in the PR
   description. (This one takes a few minutes — it is the only slow
   check here, and it is the acceptance that matters.)

5. **Caps hold.** `wc -l _fuzz/driver.tl` and `wc -l
   _fuzz/driver_test.tl` are both under 500.

6. **The diff touches only `_fuzz/driver.tl` and
   `_fuzz/driver_test.tl`.** No workflow, no other module, no
   `.cosmic-coverage` row (both files already have one, and the new
   lines are covered by the new test).

## Enablement

None needed, and no blocker. Every decision is settled to one point:

- The constant is `TIMEOUT_PER_ITER_MS = 10`, derived above from a
  measured ~1.05 ms/iteration worst case with a stated 10x margin —
  not a taste call the implementer has to make.
- The floor stays `DEFAULT_TIMEOUT_MS = 30000`, unchanged, so shallow
  behavior is provably identical (256 × 10 < 30000).
- `timeout_for` is a pure function, exported, so the acceptance can
  assert the rule at four points without waiting out a real timeout;
  the one slow acceptance check (#4) exists because the false red is
  the point of the item and only a real deep run proves it gone.
- The `Options.timeout_ms` question — absolute, floor, or scaled — is
  answered by the one existing caller, cited by line above.

The only sequencing note: PR #1308 is open over `_fuzz/driver.tl` for
board item 3IBFBWtc. It changes neither the timeout constant nor
`isolate()`, so this item is not blocked on it; whichever lands second
merges main and re-runs its own acceptance.
