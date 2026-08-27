`_tool/records.tl`'s `parse_cases` silently drops a whole file from the
per-test totals line when the file's naive `.tests` sidecar disagrees with
the trailing counts line its run actually printed. `parse_cases` refuses
with "counts do not account for the cases" whenever
`c.passed + c.failed ~= #names`, the caller falls back to the naive
"(N test functions)" row label, and the file contributes ZERO to
`test_counts`'s total — so the totals line under-reports with no warning
anywhere. Measured on batch 1 of the runner-mode migration (3IU6AZEx) at
`267c2a4d` plus that batch's deletions: `--make test _build _docs _types 3p
_fuzz _eval _perf _tool` ends `test: PASS (65 files)` and prints
`474 tests: 474 passed`, where discover finds `478` real cases across the
same 65 files. The missing four are `_tool/seam_test.tl`'s, whose
long-bracket fixtures put eight names in
`o/_tool/seam_test.tl.test.tests` (`test_addition`, `test_strings`,
`test_addition`, the four real cases, `test_broken`) against the
`4 checks: 4 passed` in `o/_tool/seam_test.tl.test.out`; the cases run and
pass, and the row shows `✓`, but the total loses them. The other 64 files
reconcile and sum to exactly `478 - 4 = 474`. The consequence is that the
totals line cannot be used as the no-test-lost guard it was introduced to
be (#1456): a file can stop running its cases and the number can move for
either reason, indistinguishably. Two candidate fixes: derive `.tests` from
`_tool/discover` (a real lexer, which already reports 4 for this file)
rather than the naive scan that cannot see into strings, or make a
non-reconciling file a loud failure instead of a silent zero. The first
also fixes the row label, which reads "8 test functions" for a file with
four.
