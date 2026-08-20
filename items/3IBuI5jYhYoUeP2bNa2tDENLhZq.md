## Evidence

2026-08-20, PR #1297 (Board: 3IBFBWtc, head 4ec56c6a): `_fuzz/corpus.tl`
and `_fuzz/driver.tl` carried byte-identical `detail_of` function bodies
(9 lines) plus a duplicated `BUDGET_MESSAGE` constant and `env_integer`
helper, and `bin/cosmic --make ci` passed cleanly on that head (CI check
run 96490992301, conclusion success). The dup-body gate (`_build/dupes.tl`)
either does not scan `_fuzz/` or its threshold excludes bodies this size —
whichever it is, a byte-identical body across two files in a shipped tree
is exactly what the gate exists to refuse, and it did not fire. Found
during the review of #1297; the duplication itself is being removed by
that PR's rework, so the gate gap is the remaining work.
