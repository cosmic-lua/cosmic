## Evidence

PR #1264 (item 3HyCSe5U, "peer table v1") shipped with two of five new files over
the item's own spec-stated 200-line cap: `_perf/peers/peers.tl` at 346 lines (73%
over) and `_perf/peers/run.tl` at 228 lines (14% over). `bin/cosmic --make lint`
passed because the repo-wide gate only enforces the blanket 500-line cap
(AGENTS.md) — nothing checks a file against a tighter cap an item's own spec
states. The PR body's size claim ("all ≤500 lines, well under the cap") answered
the wrong question: it satisfied the general house rule while missing the
spec's explicit, narrower target, and no gate caught the mismatch before review.

This is a ready-bar/acceptance gap, not a one-off implementer slip: a spec that
states a per-file cap tighter than 500 lines has no mechanical way to verify
that cap short of a human counting lines during review. Candidate
countermeasures (core > docs > skills, per skills/work/enable.md): teach the
`ready` bar's spec grammar (`_work/spec.tl`) to parse an explicit per-file line
cap out of the `Change` section and have `gitboard check`/the PR-quoting gate
verify it mechanically, the same way it verifies Acceptance commands were
quoted; short of that, at minimum the spec template/ready-bar guidance should
tell implementers to self-check `wc -l` against a spec-stated cap before
opening the PR.
