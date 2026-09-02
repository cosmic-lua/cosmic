## Evidence

Reported by the builder of cosmic-lua/cosmic#1607 (hold marker, on the
`board` branch, built under the pinned cosmic release via `bin/cosmic`).
A runner-mode test file (D29 shape: top-level `local function test_*`
defined, never called) is nondeterministically green under `--make ci`:

- When the test stage's compile seam (which appends the generated
  calls) ran first, `check` reports the file "already proved by their
  strict compile" and passes.
- When `check` type-checks the raw file cold, it fails with
  `warning: unused function test_...` for every case
  (`_work/githold_test.tl:21:1` in the builder's run, since warnings are
  errors).

Every existing `_work/*_test.tl` self-calls its cases, which sidesteps
the gap; #1607's new file was made to self-call for the same reason,
against AGENTS.md's "write new files in runner mode" rule.

### Measured 2026-09-02 (cosmic main 33ab3733; board 777abb92)

Three binaries, two trees, both orders, each order in a fresh copy.
Trees: (a) `_make/testdata/runner` (one runner-mode file, `test_one`);
(b) the board branch with `_work/githold_test.tl` made runner-mode by
`sed -i -E '/^test_[a-z_]+\(\)$/d'` (3 cases, self-calls removed).
Binaries: BOARD-PIN = the board branch's `bin/cosmic.pin`
(`whilp/cosmic 2026-08-27-555873e`, cosmos 2026.08.27-13977f2ef, Lua
5.4); MAIN-PIN = main's `bin/cosmic.pin` (`cosmic-lua/cosmic
2026-08-31-a5b36f4`, cosmos 2026.08.31-6dfa6728a, Lua 5.5); TREE =
`o/bin/cosmic` built from main 33ab3733.

| binary    | tree            | test -> check                                   | check (cold) -> test                                    |
|-----------|-----------------|------------------------------------------------|--------------------------------------------------------|
| BOARD-PIN | runner fixture  | `check: 2 of 2 already proved...` `check: PASS`  | `check: FAIL (1 of 2 files)` `main_test.tl:4:1: warning: unused function test_one` |
| BOARD-PIN | board + githold | `check: 67 of 67 already proved...` `check: PASS` | `check: FAIL (1 of 67 files)` `_work/githold_test.tl:21:1`, `:42:1`, `:59:1` unused function |
| MAIN-PIN  | runner fixture  | `2 of 2 already proved` `check: PASS`          | `check: PASS (2 files)`                                |
| MAIN-PIN  | board + githold | `67 of 67 already proved` `check: PASS`        | `check: PASS (67 files)`                               |
| TREE      | runner fixture  | `2 of 2 already proved` `check: PASS`          | `check: PASS (2 files)`                                |
| TREE      | board + githold | `67 of 67 already proved` `check: PASS`        | `check: PASS (67 files)`                               |

`--make test` passes (`test: PASS (1 file)`) in every cell. The
faithful sequence under BOARD-PIN on tree (b): `--make test
_work/githold_test.tl` then `--make ci` ends `ci: PASS (4 stages)`
(check line: `67 of 67 already proved`); a cold `--make ci` on a fresh
copy ends `ci: FAIL (check)` with the three warnings above. (The
report's wording had the two inverted: test-first is the green run,
cold is the red one.)

**Root cause: the board's pin predates #1561, not the proof cache.**
`git show 555873e:_make/check.tl` -> `check_files` calls
`teal.check_file(f.path, {include_dirs = include_dirs})` raw;
`git show 555873e:_cli/build/work.tl` line 210 already compiles through
`require("_tool.seam")`. That release is exactly the `3IU4umVT` state
(compile seam misses `--make check`). #1561 (c211a1e0, 2026-08-30)
routed `check_files` through `seam.augment` + `teal.check(aug.source,
...)`; `git merge-base --is-ancestor a5b36f4 HEAD` holds and `git log
a5b36f4..HEAD -- _make/check.tl _tool/seam.tl _cli/build/work.tl
_tool/discover.tl` is empty, so main's pin a5b36f4 carries the fix.
The board's `bin/cosmic.pin` (`whilp/cosmic 2026-08-27-555873e`) is
three days older than #1561, and the board's `board.yml` gate runs
`bin/cosmic --make ci` under that pin.

**The proof cache is sound on main.** `proved_by_graph`
(`_make/check.tl:88`) keys on the mtimes of the source, its import
closure, `o/.stamp/compile` and `o/_types/types_gen.stamp`; the compile
stamp hashes the embedded bytes of the verb's closure plus every
`*_pin.tl` (`_make/stamp.tl` header), so a seam or checker change
moves it. The cache can only lie when `check` and the compile disagree
on semantics, which is the state #1561 removed: on main both go through
`seam.augment`, and the table above shows no order dependence under
MAIN-PIN or TREE. Nothing to fix in `_make/check.tl`.

**What main already pins, and what it does not.**
`_make/fixtures_test.tl:116` `fixture("runner", ...)` runs `--make check`
cold before any build, so a check that bypasses the seam fails the gate
(3IU4umVT's countermeasure). No test runs `test` THEN `check` and asserts
the proof path was taken, so the "same verdict both orders" invariant
this item names is observed only by the converged `--make ci` on this
repo (267 of the tree's `*_test.tl` are runner-mode today, counted with
`grep -c '^local function test_'` vs `grep -cE '^test_\w+\(\)'` over
`find . -name '*_test.tl'`).

Capacity: `wc -l _make/fixtures_test.tl` = 212 (288 headroom);
`_make/check.tl` = 242. `_make/testdata/runner/cmd/runner/main_test.tl`
is 6 lines with one case. `fixtures_test.tl` is runner-mode (4 cases),
and `staged(name)` does `remove_all` before copying, so restaging
"runner" yields a fresh tree; `fixture("runner", ...)`'s return is not
captured by any later test.

Bumping the board's pin is measured separately (see the sibling item
"board pin predates the check seam"): under MAIN-PIN a cold `--make ci`
on the board tree ends `check: PASS (67 files)` but `coverage: FAIL` on
the ratchet (`_work/review.tl: coverage declined 100.0% -> 95.9% (71/74,
baseline 65/65)` — the newer tool counts lines differently); after
`--make coverage --baseline` (32 rows before and after, none vanished)
`--make ci` ends `ci: PASS (4 stages)`.

## Change

One mechanism already exists on main (#1561): `--make check` applies
the seam exactly as the compile does. This item adds the test that
locks the invariant the report names — the order of `test` and `check`
cannot change `check`'s verdict — so a future call site that bypasses
the seam fails a gate in BOTH directions, not only cold.

1. `_make/fixtures_test.tl`, directly after `fixture("runner", {runner
   = "hello from runner"})` (line 116): add one runner-mode case

   ```
   -- Order cannot change `check`'s verdict. `--make test` compiles a
   -- runner-mode file through the seam and the graph's proof then
   -- lets `check` skip it ("already proved"), so a check that
   -- bypassed the seam would pass after `test` and fail cold. Both
   -- orders on fresh copies, one verdict; the proof line is asserted
   -- so the skip path is known to be the one taken.
   local function test_check_verdict_does_not_depend_on_test_order()
     local root = staged("runner")
     local code, out = make(root, "check")
     assert(code == 0, "check-first: cold check passes:\n" .. out)
     assert(not out:find("already proved", 1, true),
       "nothing is proved before any graph verb:\n" .. out)
     code, out = make(root, "test")
     assert(code == 0, "check-first: test passes:\n" .. out)

     root = staged("runner")
     code, out = make(root, "test")
     assert(code == 0, "test-first: test passes:\n" .. out)
     code, out = make(root, "check")
     assert(code == 0, "test-first: check passes, same verdict:\n" .. out)
     assert(out:find("already proved by their strict compile", 1, true),
       "the seam's compile is the proof check accepted:\n" .. out)
   end
   ```

   Measured under TREE on the fixture: cold `--make check` prints
   `check: PASS (2 files)` and no proof line; after `--make test` it
   prints `check: 2 of 2 already proved by their strict compile` then
   `check: PASS (2 files)` — the two strings the assertions read.

2. No change to `_make/check.tl`, `_tool/seam.tl`, or the fixture.

The symptom the builder hit is closed by the sibling item that bumps
the board branch's `bin/cosmic.pin` to main's release (precedent:
3Ib5S8KI, PR #1505); this item does not touch the board branch.

## Non-goals

No change to `proved_by_graph`'s key or to the compile stamp — the
cache is measured sound once check and compile share the seam. No
board-branch change (pin, `.cosmic-coverage`, `_work/**`) rides here;
those are the sibling items. No new fixture directory: the existing
`_make/testdata/runner` is the runner-mode project.

## Acceptance

- `bin/cosmic --make ci` ends `ci: PASS`.
- `bin/cosmic --make test _make/fixtures_test.tl` passes with the new
  case listed (5 cases).
- The test fails against the state it guards: pointed at BOARD-PIN's
  behaviour (a `check` that bypasses the seam), the check-first half
  fails with `unused function test_one` — the same output the table
  above records for BOARD-PIN on the fixture.
- `wc -l _make/fixtures_test.tl` <= 500.
