# testrun's per-case sidecar is built by a naive grep, so a test file with `local function test_` inside a string loses its whole file's statuses

`_tool/testrun.tl:159-171` builds the `.tests` sidecar's name list by
scanning the SOURCE line-by-line for `^local function (test_[%w_]+)`.
That match cannot see strings, while `_tool/discover` — a real lexer,
and the walk the compile seam and the `call-after-define` lint both
use — can. When the naive list is LONGER than what the runner-mode
tail actually reported, `records.parse_cases` refuses the file and
testrun falls back to writing bare names with no `\t<status>` column.
Only a statused line contributes to the aggregate
(`_tool/testrun.tl:281-292`), so the file's real cases silently drop
out of the `N tests: N passed` totals line while its row still shows
the inflated naive count.

Measured on `origin/main` at `267c2a4d` with batch 1 of the runner-mode
migration (3IU6AZEx) applied: `_tool/seam_test.tl` has 4 real cases and
4 more `local function test_*` lines inside its `LEGACY_SRC` /
`RUNNER_SRC` long-bracket fixtures. Its row prints
`✓ _tool/seam_test.tl (8 test functions)`, its sidecar
`o/_tool/seam_test.tl.test.tests` holds 8 bare unstatused lines, and
`--make ci` ends `474 tests: 474 passed` where the in-scope case total
measured by discover is 478 — the missing 4 are seam_test's, and the
file passed. A sweep of every in-scope sidecar
(`find o/_build o/_docs o/_types o/3p o/_fuzz o/_eval o/_perf o/_tool
-name '*_test.tl.test.tests'`, checking each for a tab) finds
seam_test's as the only unstatused one.

The consequence is that the totals line is not the no-test-lost check
it reads as: a case that stopped running inside such a file is
indistinguishable from this artifact. The likely fix is to source the
name list from `_tool/discover` rather than the grep, which would make
the sidecar agree with the seam about what a file's cases are; the
row's `N test functions` annotation would then also stop over-counting.
Out of scope for the migration batches, which are deletions only.
