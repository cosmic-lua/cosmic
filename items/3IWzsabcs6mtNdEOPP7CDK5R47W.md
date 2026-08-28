## CORRECTION 2026-08-28 — this item's premise is false; ended not-planned

The class described below does not exist. Under
[D29](docs/decisions/d29-tests-run-because-defined.md) a `*_test.tl`
with NO self-calls is **runner mode**: the toolchain appends a
generated tail at the compile/check seam and every `test_*` runs. The
evidence below was gathered by running the file as a BARE SCRIPT, which
is precisely the path that skips that tail.

Re-run through the runner, in a clean export of PR #1480's merged tree
with `_perf/baserun.tl` removed from `release.yml`:

```
$ ./o/bin/cosmic _build/workflows_test.tl          # bare script — the wrong method
all workflow ratchet tests passed
exit=0

$ ./o/bin/cosmic --make test _build/workflows_test.tl
8 checks: 7 passed, 1 failed        # test_the_release_baseline_runs_the_trees_perf
test: FAIL (1 of 1 file)
```

And `origin/main`'s `_perf/skew_test.tl` (1 definition, 0 self-calls)
with `assert(false)` injected into its body: `1 checks: 0 passed, 1
failed`. It was never inert.

The proposed countermeasure — a lint requiring a self-call after every
`test_*` — would contradict D29 outright and fight the tree's migration
to runner mode (`3IOCdooE`); `call-after-define` already fails the one
shape that must (mixed).

The real, narrower gap this hunt did find is filed as **`3IY0HUUk`**:
`_build/workflows_test.tl`'s unconditional trailing
`print("all workflow ratchet tests passed")` makes a bare run read
green, and AGENTS.md still states the self-call rule as absolute with
no mention of runner mode — which is what produced the false finding.

Everything below is the original, falsified spec, kept as the record.

---

## Goal

G4 — zero-config project gates: one command must give a MEANINGFUL
`PASS`/`FAIL`. A `_test.tl` that defines `test_*` functions and never
calls them passes every gate cosmic has while asserting nothing, so the
verdict is not meaningful — it is a report about a file that ran no
assertions.

AGENTS.md already states the rule ("test files call each test where they
define it: a `test_*` function in a `_test.tl` is called on the line
after its `end`"). Nothing enforces it.

## Evidence — measured 2026-08-28 at origin/main b0aeb1dd

Two ratchet files in the tree are wholly inert, and both were found only
by reading them:

```
git show origin/main:_build/workflows_test.tl | grep -c '^local function test_'   # 7
git show origin/main:_build/workflows_test.tl | grep -c 'test_[a-z_]*()' \
  | grep -v 'local function'                                                      # 0 call sites
git show origin/main:_perf/skew_test.tl | tail -1                                 # "end" — no call
```

Demonstrated, not inferred. In a clean export of the tree, with
`_perf/baserun.tl` deleted from every line of `.github/workflows/release.yml`:

```
$ sed -i 's|_perf/baserun.tl|_perf/NOPE.tl|g' .github/workflows/release.yml
$ o/bin/cosmic _build/workflows_test.tl
all workflow ratchet tests passed
exit=0
```

The file's seven assertions — one container digest across every
workflow, the digest is a digest, every build job containerised,
`--privileged`, non-root builder, the perf-compare verdict propagates —
none of them run. `_build/workflows_test.tl`'s own header explains why
those pins matter ("a lane that stops testing what it was built to test
stays green either way"); the file is itself an instance.

The gates that should have caught it, run on those exact files, all pass:

```
o/bin/cosmic --check fmt  _build/workflows_test.tl   # Format check passed
o/bin/cosmic --check lint _build/workflows_test.tl   # Style check passed
o/bin/cosmic --check types ...                       # no unused-variable error
```

`--check types` does not flag the uncalled `local function test_*` as
unused, and `--check lint` has no rule for it. `_tool/testrun.tl` counts
`test_*` functions by STATIC scan of `^local function (test_[%w_]+)`
(`_tool/testrun.tl:165`), so the runner's own `N tests: N passed` line
reports definitions, not executions — an inert file reports full green.

## Why now — the same wrong turn twice

- `_perf/skew_test.tl` landed inert in #1427 (item `3ITdgu6f`) and stayed
  inert until PR #1480 restored the call by hand.
- `_build/workflows_test.tl` has been inert since it landed, and PR #1480
  added an EIGHTH uncalled test to it while fixing the identical bug one
  file away. That PR earned a `request changes` for it.

Two occurrences, one of them inside the fix for the other: review.md's
rule makes the countermeasure non-optional.

## Change (sketch — the refine owns the shape)

A pure lint check in `_tool/lint.tl`, since that is where the file-cap
and cast-justification rules live and it runs in `--make ci` for every
project cosmic builds: in a `*_test.tl`, every `local function
test_<name>` must have a call `test_<name>()` at file scope. Report the
defining line. Helpers are already distinguishable by not matching
`test_*`; `Example_*` functions are the example runner's and are not
`_test.tl`.

Landing it requires fixing the two inert files in the same PR (7 + 1
calls), which is what makes the check worth having: turning them on will
either pass or reveal an assertion that was never true.

An alternative worth pricing in the refine: have `_tool/testrun.tl`
report EXECUTED tests rather than defined ones, so `N tests: N passed`
stops being a count of `local function` lines. The two are complementary
— the lint moves the failure to the PR, the runner stops overstating.

## Non-goals

- No change to how tests assert, and no test framework.
- Not a coverage rule: an uncalled test is a structural fact readable
  from the source, and the coverage ratchet already lets a 0%-covered
  file sit at its floor.

## Acceptance

- A `*_test.tl` with a defined-but-uncalled `test_*` fails
  `cosmic --check lint`, naming file and line.
- The same file with the call added passes.
- A helper (`local function make_tmp()`) and an `Example_*` function are
  not flagged.
- `bin/cosmic --make ci` ends `ci: PASS` with the two currently-inert
  files fixed.
- `grep -c 'test_[a-z_]*()' _build/workflows_test.tl` counts one call per
  defined test.
