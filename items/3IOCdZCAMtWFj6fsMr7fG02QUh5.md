## Goal
G5 — adversarial verification, through `3IOCIBGe` (test runner: tests run
because they are defined). D29 landed the runner and the compile seam; a
failing run still names only the FILE. This slice gives the report per-test
identity, so one run says which tests failed rather than which files did.

Design context, durable: `docs/decisions/d29-tests-run-because-defined.md`
(in the tree, status `active`; its consequences paragraph names the `.tests`
sidecar and the filter) and the diff of closed PR **whilp/cosmic#1366**,
which carries the full design chart as `docs/design/test-runner.md`. That
file was never merged — `ls docs/design/` lists `casts.md`, `make/`,
`nil-flow-sites.tsv`, `nil-flow.md` and nothing else — so read it from the
PR diff, not from the tree. The branch `claude/cosmic-test-runner-rgb819`
this item used to cite is deleted and unreachable; do not look for it.

Re-measured at pull, 2026-08-27, against `origin/main` `2724a719`: every
line reference below still resolves, `_tool/records.tl` is still 309 lines
and `_tool/testrun.tl` still 337, `cmd/cosmic/main.tl` is still 499 and
`_make/init.tl` still 498, and the runner-mode count is still zero — now
out of 276 `*_test.tl` files rather than 275. Detail only; the shape holds.

A concurrent refinement overwrote this sidecar four minutes after the
`ready` move with a version that re-added `--filter` (which item `3IUCW3Wj`
owns) and pointed the summary counts line at tests. That second premise is
measurably wrong — `_make/stage.tl:221` renders every stage verdict as
`stage_detail(summary, #files, "file")` and all six stages share one
`--report` (`embed/cosmic.mk:158,199,222,243,266,294`) — so this, the text
the `ready` move was made against, is restored as the spec.

## Change

Two files change, both under `_tool/`.

**1. `_tool/records.tl` — the parser and the new line, beside their
inverses.** This module is already the one home of the output grammar and
already carries `parse_counts` as the inverse of `counts`; the child's
per-test output is the same kind of thing, so it is parsed here and not in
the runner. Measured now: `wc -l < _tool/records.tl` is 309, 191 lines of
headroom under the 500-line cap.

Add two functions and their entries in `RecordsModule` / `M`:

- `parse_cases(names: {string}, out: string): {Status} | nil, string` —
  attribute one `Status` per name, in the order given, from a child's
  stdout. It is pure: no fs, no cwd. The rules, exactly:
  1. The **last non-empty line** of `out` must match `^%d+ checks: `.
     If it does not, return `nil, "no trailing counts line"`. This is the
     legacy/runner discriminator and the reason no mode check is needed:
     `cosmic/test.tl:157` writes the counts line last and the seam's tail
     is `os.exit(...)`, so a runner-mode child always ends on it, and a
     legacy-mode child (a plain script) never does.
  2. Parse that ONE line with `parse_counts`. Require `c.skipped == 0` —
     `cosmic.test`'s `counts` (`cosmic/test.tl:102-108`) has no skipped
     clause, so a nonzero one means the line came from somewhere else.
  3. A name is `"fail"` when a line of `out` is EXACTLY
     `ICONS.fail .. " " .. name` for a name in `names`. Membership-gated
     on purpose: `report()` prints rows with the same icon, and a test
     that calls `testrun.report` writes them to its own stdout
     (`_tool/testrun_test.tl:164,177,190,213,227,237` do exactly this) —
     but those rows name FILE paths, never `test_*` names, so the gate
     excludes them. `cosmic/test.tl:153` indents every traceback line four
     spaces, so a traceback can never match either.
  4. Require `c.passed + c.failed == #names` and
     `c.failed == <number of names matched in step 3>`; otherwise return
     `nil, "counts do not account for the cases"`. This is what makes a
     filtered run, a mid-run `os.exit`, and a crash fall back rather than
     invent statuses.
  5. Return `{Status}` — `"fail"` for a matched name, `"pass"` for the
     rest — in the order of `names`.
- `test_counts(passed: integer, failed: integer): string` — the line
  `N tests: P passed[, F failed]`, without its newline. Deliberately
  spelled `tests:` and not `checks:`, and deliberately carrying NO
  `skipped` clause: see the Non-goals wall on `parse_counts`.

**2. `_tool/testrun.tl` — write statuses, and total by test.** Measured
now: `wc -l < _tool/testrun.tl` is 337, 163 lines of headroom.

- In `run()`, at the existing `.tests` write (`_tool/testrun.tl:159-177`):
  keep the source scan for `^local function (test_[%w_]+)` exactly as it
  is, keep the `#test_names > 0` guard, and keep writing only for the
  `test` and `coverage` stages. After building `test_names`, call
  `records.parse_cases(test_names, stdout_content)`. When it returns a
  status list, write one `name .. "\t" .. status` line per name; when it
  returns nil, write today's bytes unchanged (`name` per line). Keep the
  write best-effort — a failure warns on stderr and does not fail the run.
- In `report()`, where `.tests` is read (`_tool/testrun.tl:245-252`):
  keep `test_count` as the count of LINES (the row annotation must not
  move). Additionally, per line, match `^([^\t]+)\t(%S+)$`; a line that
  matches contributes to `tests_passed` / `tests_failed`, and a `fail`
  contributes its name to that result's failing-test list. Carry the
  failing names on `TestResult` as a new `failing_tests: {string}` field
  (`{}` when none) — a record field, not a third return.
- Print `records.test_counts(tests_passed, tests_failed)` on its own line
  **after** the existing `records.counts(...)` line and **before** the
  `wall:` line, and ONLY when `tests_passed + tests_failed > 0`. Zero
  statused rows means no line, which is the whole tree today (see the
  runner-mode measurement below), so `--make ci` output does not move.
- In the `Failures:` block (`_tool/testrun.tl:302-322`), for a failing
  result whose `failing_tests` is non-empty, print before the `stderr:`
  block:

  ```
    failing tests:
      test_trim
      test_split
  ```

  (two-space `failing tests:`, four-space names, source order.)

Nothing in this slice runs in the tree today: measured, **0 of 276
`*_test.tl` files are in runner mode** —

```
for f in $(find . -name '*_test.tl' -not -path './o/*'); do \
  d=$(grep -c '^local function test_' "$f"); c=$(grep -c '^test_' "$f"); \
  if [ "$d" -gt 0 ] && [ "$c" -eq 0 ]; then echo "$f"; fi; done | wc -l
```

prints `0`. The migration batches under `3IOCdooE` are what make the new
paths live. So the new behaviour is proved by unit tests over synthetic
child output and a `TEST_TMPDIR` fixture, not by the tree's own summary —
see Acceptance.

## Non-goals

- **`--filter` is NOT in this slice.** It was in the item's title; it is
  cut, and the reason is measured: the flag has nowhere to be spelled.
  `wc -l cmd/cosmic/main.tl` is **499** and `wc -l _make/init.tl` is
  **498**, against a hard cap of 500 (`_tool/lint.tl:31`, refusing
  `n > limit`) — one and two lines of headroom, so neither
  `cosmic --test … --filter` nor `--make test … --filter` can be added
  without splitting a file first. And the capability substantially exists:
  `_tool/testrun.tl:59-69` copies the whole parent environment to the
  child, excluding only `COSMIC_COVERAGE` and `COSMIC_MAKE_ROOT`, so an
  ambient `COSMIC_TEST_FILTER` already reaches `cosmic/test.tl:47-62`,
  which already honours it. What is genuinely missing is the flag spelling
  and graph invalidation (nothing declares `COSMIC_TEST_FILTER`, so
  `_make/envstamp.tl` does not make its value a prerequisite and a
  narrowed re-run replays cached `.got` files). Filed separately as
  **3IUCW3Wj**. Do not add a `filter` parameter to `testrun.run` here: with
  no caller it is dead surface, and `parse_cases` already falls back
  correctly under an ambient filter.
- **`records.counts` and the summary's `N checks:` line stay FILE-based.**
  `_make/stage.tl:221` derives every stage verdict from that line via
  `records.stage_detail(summary, #files, "file")`, and all six stages share
  one `--report` (`embed/cosmic.mk:158,199,222,243,266,294`). Re-pointing
  it at tests would print `test: FAIL (4 of 2786 files)`. The tests line is
  ADDITIONAL and must sit after the checks line, because
  `parse_counts`' `", (%d+) failed"` and `", (%d+) skipped"` patterns are
  unanchored and take the first match in the text.
- **The row format does not move.** `records.row(status, name, count,
  "test functions", wall_ms)` and its `✓ path (14 test functions) 12ms`
  rendering stay byte-identical; `test_count` stays a count of `.tests`
  lines.
- **`.tests` stays one line per test.** That invariant is what the
  existing in-tree consumer at `_tool/testrun.tl:247` counts, and it is the
  only consumer — `grep -rn '\.tests' --include=*.tl --include=*.mk . |
  grep -v '^./o/'` returns 5 hits, all in `_tool/testrun.tl`, two of them
  comments and one a diagnostic string.
- **`cosmic/test.tl` is not touched.** It is PUBLIC API frozen by D29, and
  quiet-on-pass is a stated property: do NOT add a per-test pass line to
  make parsing easier. `_tool/records_test.tl`'s existing agreement between
  the two spellings stays as it is.
- **`_tool/discover.tl` is not required from `testrun.tl`.** Its token walk
  and the existing `^local function (test_[%w_]+)` regex can disagree on a
  definition whose `end` the walk loses (`_tool/discover.tl:113-118`), and
  swapping them would silently change the `(N test functions)` annotation
  on some file. Keep the regex.
- No new flags, no new sidecar files, no per-test wall time, no per-test
  skip, no change to the 0/2/fail exit grammar, no change to the migration
  items under `3IOCdooE`, and no edits to `docs/agent-usability.md`
  (item 6 there stays true — per-file counts and the row are unchanged).

## Acceptance

- `bin/cosmic --make ci` ends `ci: PASS`.
- `bin/cosmic --make test _tool/records_test.tl _tool/testrun_test.tl`
  ends `test: PASS (2 files)`, including these new cases:
  - `_tool/records_test.tl`: `test_parse_cases_attributes_pass_and_fail`
    — two names, stdout `"✗ test_b\n    traceback\n2 checks: 1 passed, 1 failed\n"`
    yields `{"pass", "fail"}`.
  - `_tool/records_test.tl`: `test_parse_cases_refuses_a_non_runner_tail`
    — stdout whose last non-empty line is not a counts line returns nil.
  - `_tool/records_test.tl`: `test_parse_cases_refuses_a_short_count`
    — three names with `2 checks: 2 passed` returns nil (the filtered and
    crashed cases).
  - `_tool/records_test.tl`: `test_parse_cases_ignores_a_report_row`
    — stdout containing `✗ cosmic/fs/init_test.tl` (a `report()` row) plus
    a matching counts line attributes every name `"pass"`.
  - `_tool/records_test.tl`: `test_parse_counts_ignores_the_tests_line`
    — `parse_counts` over a summary text holding
    `"19 checks: 18 passed, 1 failed\n6 tests: 4 passed, 2 failed\n"`
    returns `passed=18, failed=1, skipped=0`. This pins the frozen
    `stage_detail` contract against the new line.
  - `_tool/testrun_test.tl`: `test_tests_sidecar_carries_statuses`
    — write a two-`test_*` source at `TEST_TMPDIR/fake_test.tl`, run
    `testrun.run({cosmic_bin, script}, TEST_TMPDIR .. "/fake_test.tl.test")`
    where `script` prints one `✗` row and a matching counts line, then
    assert `fake_test.tl.test.tests` is exactly
    `"test_a\tpass\ntest_b\tfail\n"`. (`records.source_of` strips only a
    leading `o/` and the stage suffix, so an absolute `TEST_TMPDIR` base
    resolves to the fixture beside it — nothing is written into the tree.)
  - `_tool/testrun_test.tl`: `test_tests_sidecar_stays_names_only_for_legacy`
    — the same fixture with a child that prints nothing yields
    `"test_a\ntest_b\n"`, byte-identical to today.
  - `_tool/testrun_test.tl`: `test_report_totals_tests_and_names_failures`
    — `report()` over a base with a statused `.tests` and a failing `.got`
    prints a line matching `^%d+ tests: %d+ passed, %d+ failed$` and a
    `failing tests:` block naming the failing test.
- `bin/cosmic --make test` ends `test: PASS (N files)` and
  `grep -c ' tests: ' o/test-summary.txt` prints `0` — the tree is
  all-legacy, so the new line must not appear and the stage verdict must
  not move.
- `wc -l _tool/records.tl` is ≤ 500 and `wc -l _tool/testrun.tl` is ≤ 500
  (309 and 337 before this change).
- `git diff --stat` shows changes confined to `_tool/records.tl`,
  `_tool/records_test.tl`, `_tool/testrun.tl`, `_tool/testrun_test.tl`.
- If `--make coverage` fails its ratchet, run exactly the regen command its
  failure message prints and commit the result. Do not weaken the gate any
  other way.

## Enablement
none needed — no blocker item has to land first. The seam this depends on
(`3IOCdHTM`, PR #1446) is merged: `_cli/build/work.tl:204-211` calls
`_tool.seam.augment`, and `cosmic/test.tl`, `_tool/discover.tl`,
`_tool/seam.tl` are all in the tree.

The wrong turns predicted for a literal-minded session, and where each is
closed in core rather than prose: parsing the report's own `✗` rows out of
a child's stdout (closed by the membership gate in `parse_cases` step 3 and
pinned by `test_parse_cases_ignores_a_report_row`); re-pointing the
`N checks:` summary at tests and breaking every stage verdict (closed by
the Non-goals wall and pinned by `test_parse_counts_ignores_the_tests_line`);
inventing statuses under a filter or a crash (closed by the arithmetic
check in step 4 and pinned by `test_parse_cases_refuses_a_short_count`);
adding a pass line to `cosmic/test.tl` to make parsing easy (closed by the
Non-goals wall — it is frozen public API); and adding a `--filter` flag
into a file with one line of headroom (closed by the measured Non-goal and
item 3IUCW3Wj). No new lint is warranted: each wrong turn has a test that
names it, and a lint here would police one PR rather than transfer.
