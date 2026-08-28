## Goal

G4 — zero-config project gates: one command must give a MEANINGFUL
`PASS`/`FAIL`, and the tree's own prose must not teach a reader to read
a green line that means nothing.

Since [D29](docs/decisions/d29-tests-run-because-defined.md) a
`*_test.tl` with NO self-calls is runner mode: `cosmic --make test`
appends a generated tail at the compile/check seam and every `test_*`
runs. Running the same file as a BARE script skips that tail — so a
runner-mode file invoked as `cosmic path/to/x_test.tl` asserts nothing
and exits 0. Two things in the tree make that trap easy to fall into,
and it has now cost one wrong `request changes` verdict.

## Evidence — measured 2026-08-28 at origin/main b0aeb1dd

**1. `_build/workflows_test.tl` prints a green line for a run that
executed nothing.** Its last statement is an unconditional
`print("all workflow ratchet tests passed")` — no assertion behind it.
In a clean export of the merged tree of PR #1480, with
`_perf/baserun.tl` removed from every line of `release.yml`:

```
$ ./o/bin/cosmic _build/workflows_test.tl        # bare script
all workflow ratchet tests passed
exit=0

$ ./o/bin/cosmic --make test _build/workflows_test.tl   # the runner
8 checks: 7 passed, 1 failed
test: FAIL (1 of 1 file)
```

The runner catches the mutation; the bare run prints a sentence saying
the opposite. That sentence is the whole defect: without it the bare
run would be silent and no one would read it as a pass.

**2. AGENTS.md states the self-call rule as absolute.** Under
"Language and Conventions":

> **test files call each test where they define it**: a `test_*`
> function in a `_test.tl` is called on the line after its `end`, so a
> failing run names the function.

Nothing there mentions runner mode, D29, or that the tree is migrating
AWAY from self-calls (`3IOCdooE`). A reader who checks a file against
AGENTS.md concludes an uncalled `test_*` is dead code. That is exactly
the inference that produced the false blocking finding on PR #1480
(board `3IVF3HbV`), reversed at re-review.

**3. The class the retired `3IWzsabc` claimed does not exist.** Proved
by mutation: `origin/main`'s `_perf/skew_test.tl` (1 definition, 0
self-calls) with `assert(false)` injected into the test body →
`--make test` reports `1 checks: 0 passed, 1 failed`. Runner-mode files
run. A lint demanding self-calls would contradict D29 and fight
`3IOCdooE`.

## Change (sketch — the refine owns the shape)

Two edits, independent, both small:

- **Delete the unconditional print** at the end of
  `_build/workflows_test.tl`, and sweep for the same shape elsewhere
  (`grep -rn 'print(".*passed")' --include='*_test.tl'`). A test file's
  verdict is the runner's, never a `print`.
- **Amend AGENTS.md's convention bullet** to state both modes and which
  way the tree is going: a file is all-or-nothing, mixed is a lint
  failure, runner mode is the target, and a `_test.tl` run as a bare
  script does not execute its cases.

## Non-goals

- No lint requiring self-calls — D29 forbids it and `call-after-define`
  already covers the one shape that must fail (mixed).
- No migration of any test file to runner mode; that is `3IOCdooE`.
- No change to `cosmic/test.tl`, the compile seam, or the exit grammar.

## Acceptance

- `grep -c 'all workflow ratchet tests passed' _build/workflows_test.tl`
  → 0.
- Repeat evidence 1's mutation: the bare run prints nothing and the
  runner still fails.
- AGENTS.md names runner mode and links D29 in the test-convention
  bullet.
- `bin/cosmic --make ci` ends `ci: PASS`.
