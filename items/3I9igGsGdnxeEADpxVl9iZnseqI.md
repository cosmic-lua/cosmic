## Change

`take --pr` refuses to record a PR number another OPEN item already
carries, so one pull request can never couple two items' verdicts.

Reproduced 2026-08-29 on a scratch board (merged machinery, post
two-state rewrite): two items, two sessions, then

    GITBOARD_SESSION=w1 gitboard take A --pr 7
    gitboard-take: A is yours pr:7 — awaiting review
    GITBOARD_SESSION=w2 gitboard take B --pr 7
    gitboard-take: B is yours pr:7 — awaiting review

— both accepted; a verdict recorded `--pr 7` now judges whichever
item it names while the other still claims the same diff, and done's
merge verification reads one PR for two items' completion.

The change, in `_work/gitverbs.tl`'s `cmd_take` handover path (and
`_work/gitgate.tl` if gitverbs' 500-line headroom is thin — measure
`wc -l < _work/gitverbs.tl` first and put the helper where it fits):
before recording `pr`, scan `store.list` for another OPEN item whose
`pr` equals the number; refuse naming that item ("PR #7 is already
N's — one PR, one item; --force --why to override for repair").
`--force --why` overrides, with the forced suffix on the commit
subject as everywhere. A re-record of the SAME item's own number
stays the existing no-op. Tests in `_work/gitverbs_test.tl` or
`_work/gitreview_test.tl` (whichever has headroom): the reproduced
double-record refuses naming the holder; the same item re-recording
its own pr stays a no-op; a DONE item holding the number does not
block (its PR is spent); --force lands with the suffix.

## Non-goals

Verdict and done are unchanged — the gate sits at the one write site
that couples the items. Existing verdict-line formats unchanged; the
refusal is an addition in the standing `REFUSED: ...` shape.
