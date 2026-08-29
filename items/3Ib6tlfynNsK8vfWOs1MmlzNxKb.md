Evidence, from PR #1506's fresh-context review (2026-08-29):
`_work/flowstats.tl`'s `try_verdict` recognizes only `accept` and
`request changes`, silently skipping `reject` — a real third kind
`_work/gitverdict.tl` writes (its kind == "reject" branch). The spec's
grammar list named only two kinds, so the diff was in-scope-as-
specified; the gap is the spec's. A reject verdict on an item later
completed undercounts `rounds` and `rework_total`. The fix is one
grammar arm in `events_of` plus a test case; decide there whether a
reject counts toward rework_rate's denominator (it is a judged round).
