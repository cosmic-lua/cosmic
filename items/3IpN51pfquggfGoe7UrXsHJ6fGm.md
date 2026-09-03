## Evidence

`help bar` says a file's headroom under a line cap is a measured fact
the spec must carry, and the refiner of pawY_zI7x omitted it: the
builder found `_make/generate.tl` at 483/500 only after implementing
(see the sibling brief item). The orchestrator always runs `brief` from
`o/board` inside a code checkout, so the tree is one `--tree ../..`
away, but `gitboard brief --help` has no such option
(`o/bin/gitboard brief --help | grep -c -- --tree` → 0).

## Change

`_work/brief.tl`: an optional `--tree DIR`. When given, collect every
path matching `[A-Za-z0-9_./-]+\.tl` in the spec's `## Change` section,
`wc -l` each under DIR, and append a section to the builder and review
briefs:

    ## Measured at brief time (DIR, <git rev-parse --short HEAD>)
    _make/generate.tl  483 lines (17 under the 500 cap)
    _make/seed.tl      absent

A path that does not exist prints `absent`; a file within 40 lines of
the cap is marked `(N under the cap)`. Without `--tree` the brief is
unchanged. The verdict line names what it measured.

`_work/brief_test.tl`: a fixture tree with one 490-line file and one
absent path; assert the section text, and that `--tree` pointing at a
non-directory refuses with a verdict line.

## Non-goals

No spec-bar refusal on missing headroom facts; the measurement rides
the brief, the bar stays prose.
