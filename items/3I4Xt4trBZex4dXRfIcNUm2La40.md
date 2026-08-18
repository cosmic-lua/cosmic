Found while moving item 3I06cBmI's PR (whilp/cosmic#1265) into `check`.

`move ID check --pr N`'s Acceptance-quoting gate refused with:

    gitboard-move: REFUSED: PR #1265's body does not quote 1 of its
    Acceptance commands (first: `./_work/gitland.tl:...`)

`_work/spec.tl`'s `acceptance_commands` extracts every backticked span in
the `## Acceptance` section whose first token "names a command" — including
any span matching `head:find("^%./")` (a `./`-prefixed path). The item's
Acceptance bullet was:

    `grep -rn "gh\.merge\b" --include=*.tl . --exclude-dir=o | grep -v _test`
    prints exactly `./_work/gitland.tl:...` (still the one caller —
    unchanged count).

Two backticked spans there: the `grep` command (correctly a command), and
`./_work/gitland.tl:...` — the EXPECTED OUTPUT of that grep, elided with
`...` for a human reader, wrapped in backticks because it's an inline code
span, not because it's a second command to run. Its head `./_work/gitland.tl:...`
matches the `^%./` path heuristic, so the parser counts it as a command the
PR body must quote verbatim. The PR body correctly shows the REAL (non-elided)
grep output (`./_work/gitland.tl:49:  local res, merr = gh.merge(s, it.pr)`)
rather than the literal string `./_work/gitland.tl:...`, so the exact-substring
check fails on a span that was never meant to be re-quoted, let alone quoted
with a literal ellipsis a real command never produces.

Worked around this occurrence with `move ... --force --why`.

Fix shape (not investigated further): `acceptance_commands` needs to
distinguish a COMMAND span from an EXPECTED-OUTPUT span that merely looks
path-like. Candidates: only count a backticked span as a command when it is
the FIRST backticked span on its bullet line (Acceptance bullets consistently
write "`command` prints/ends `output`", command first); or require the
`^%./` head to be followed by a plausible executable extension/no elision
characters; or stop matching bare `^%./` at all and require `COMMAND_HEADS`
plus an explicit low set of path-like binaries actually invoked in this
repo's Acceptance sections. Whatever the fix, add a regression case: an
Acceptance bullet whose second backticked span is a `./`-prefixed elided
grep result (exactly this item's shape) must not appear in
`acceptance_commands`'s output.

This is a different bug from 3I4832Yh (HTML-entity pollution) — same
symptom class (the quoting/facts gates false-positive on legitimate PR
bodies) but a distinct root cause in the parser's heuristic, not the stored
text's encoding. File separately so the two fixes aren't conflated.
