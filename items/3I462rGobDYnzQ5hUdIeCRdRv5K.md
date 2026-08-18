## Goal

G8 — the flow system. A parallel implementer session working from a nested
worktree has to export `COSMIC_MAKE_ROOT` (the escape hatch
`skills/work/parallel.md` documents), and doing so turns `--make ci` red on
tests that have nothing to do with its diff. That is a flow tax paid in
misdiagnosis time by every session that hits it, on work the board asked for.

## Change

Drop `COSMIC_MAKE_ROOT` from the environment the test runner hands each test
process, in `_tool/testrun.tl`.

The runner already builds the child environment by copying `env.all()` with
one key handled specially: `COSMIC_COVERAGE` is intercepted rather than
inherited, so each test gets its own coverage directory instead of the outer
one. Add `COSMIC_MAKE_ROOT` to that same loop as a key the child never
inherits — the root a test resolves must come from its own cwd (or from a
value the test sets for itself), never from whatever the outer `--make`
invocation was told.

Concretely, in the `for key, val in pairs(env.all())` loop that fills
`child_env`, treat `COSMIC_MAKE_ROOT` like `COSMIC_COVERAGE`'s existing
branch: skip it, so it is never appended to `child_env`. Extend the loop's
comment to say why — an inherited root would override the cwd every fixture
project depends on.

Add a test to `_tool/testrun_test.tl` named
`test_make_root_is_not_inherited`: set `COSMIC_MAKE_ROOT` in the calling
process, run a trivial script through `testrun.run` that prints whether
`os.getenv("COSMIC_MAKE_ROOT")` is set, assert the child saw nothing, and
restore the outer value.

**Why the runner and not the two tests.** The finding that produced this item
named `_make/check_test.tl` and `_cli/main_handlers_test.tl` as the files to
scrub. They are the two that were observed failing, but they are not the
boundary: five spawn sites across them inherit the full parent environment
(`_make/check_test.tl:63`, `:310`, `:409`, `_cli/main_handlers_test.tl:34`,
`:158`), and any future fixture spawn would inherit it too. Fixing it at the
runner closes all five and every later one in one place. It is also the only
fix that fits: `_make/check_test.tl` is 488 lines against the hard 500-line
cap, so the seven-line hermetic env list its sibling `_make` tests each define
in-file cannot be added at three sites there.

**Why this is safe.** No test reads an inherited `COSMIC_MAKE_ROOT`. Every
test that wants one sets it for itself — either in-process via
`cosmic.env.set`/`unset` around the call, or explicitly in a child's `env`
table (`_make/check_test.tl:326`, which is `test_root_override` and stays
green because it passes the value rather than inheriting it).
`_make/root_test.tl:71-79` saves and unsets the variable and restores it only
if it was set, so it is correct under either state.

```facts
$ grep -c COSMIC_COVERAGE _tool/testrun.tl
2
$ grep -c COSMIC_MAKE_ROOT _tool/testrun.tl
0
$ wc -l < _tool/testrun.tl
328
$ wc -l < _make/check_test.tl
488
$ wc -l < _cli/main_handlers_test.tl
255
$ grep -c child.start _make/check_test.tl
4
$ grep -n "child.start" _cli/main_handlers_test.tl
34:  local h = check.must(child.start(argv))
158:  local h = check.must(child.start({cosmic, "--make", "check", "a.tl"},
```

## Non-goals

Do not touch `_make/check_test.tl` or `_cli/main_handlers_test.tl`. Both sit
near the 500-line cap (488 and 255 above), the fix does not need them, and a
second scrub at the call site would be a duplicate of the runner's.

Do not add a shared test-helper module for spawning fixture children. The
per-file hermetic env list is the established house idiom in `_make/*_test.tl`
and consolidating it is a separate question, not this slice's.

Do not change `_make/root.tl`. `COSMIC_MAKE_ROOT` overriding cwd discovery is
the documented, correct behaviour for a caller that cannot chdir; the defect
is that a test child is not such a caller, which is the runner's to decide.

Do not filter any other `COSMIC_*` variable. `COSMIC_COVERAGE` keeps its
existing interception; `COSMIC_MAKE`, `COSMIC_NO_WELCOME`, `COSMIC_FENCE` and
the rest keep flowing through, and widening the filter beyond the one
variable with evidence behind it is scope this slice does not own.

Do not change the `test: PASS`/`test: FAIL` verdict line format — the gate
reader and several spec Acceptance sections parse it.

## Acceptance

- `bin/cosmic --make ci` ends `ci: PASS`.
- `bin/cosmic --make test _tool/testrun_test.tl` ends `test: PASS (1 file)`,
  including the new `test_make_root_is_not_inherited`.
- The runner filters the variable — this command prints exactly `1` (its
  pre-change value is `0`, recorded as a fact above):
  `grep -c COSMIC_MAKE_ROOT _tool/testrun.tl`
- The two named test files are untouched — this command prints exactly
  `clean`:
  `git diff --quiet origin/main -- _make/check_test.tl _cli/main_handlers_test.tl && echo clean`
- The whole gate is green with the outer variable set, which is the scenario
  the defect was reported from — run from the repo root, this ends `ci: PASS`:
  `COSMIC_MAKE_ROOT="$PWD" bin/cosmic --make ci`

## Enablement

none needed. The change is one branch in a loop that already has exactly the
branch it needs to copy (`COSMIC_COVERAGE`'s), the safety argument is settled
above rather than left to be rediscovered, and the one decision an
implementer would otherwise have to make — whether to fix the runner or the
two test files the finding named — is made in `Change` with its reasoning and
walled off in `Non-goals`.
