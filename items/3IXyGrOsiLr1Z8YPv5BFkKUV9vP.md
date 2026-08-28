## Evidence

`plan` is 4/4 at its limit and **every one of the four is blocked**, so the
lane holds no refinable work and `status` reports `WIP: plan 4/4 at limit —
arrivals refused`:

```
$ gitboard status
plan    4/4
  3IUBNQZZ codec compare rows are state-split ... [blocked]
  3IVEEDO8 perf report says which binary but not which session ... [blocked]
  3IVLAF3Z perf gate: stampless files pass identity refusals ... [blocked]
  3IPXRRd2 strict nil-flow mode: carry it as a sixth patch group ... [blocked]
ready   0/5
do      0/5
gitboard-status: WIP: plan 4/4 at limit — arrivals refused
```

The blockers, read from the items themselves:

```
3IUBNQZZ  blocked by: 3IVF3HbV            (in `check`, PR #1480)
3IVEEDO8  blocked by: 3IUBNQZZ            (chain)
3IVLAF3Z  blocked by: 3IVF3HbV
3IPXRRd2  blocked by: 3IPXQ1Zw 3IPXQuYu   (two containers)
```

`3IPXRRd2` is the instance that shows the shape. Its two blockers are
containers whose children are all in `backlog` (`3IQfILPQ`, `3IQfJ1tn` under
`3IPXQ1Zw`; `3IQgCT9j`, `3IQgClLo`, `3IQgCz5L`, `3IQgDPC0` under `3IPXQuYu`).
Promoting any of those children is the only way to retire the blockers — and
`promote` is refused, because `plan` is full of items that include
`3IPXRRd2` itself. A blocked item is holding the slot needed to unblock it.

Today this resolves by luck rather than by rule: `3IVF3HbV` sits in `check`
with a green PR, and merging it frees three slots at once. Had the lane
filled with items blocked only on backlog work, nothing on the board could
have moved without `--force` — which the skill reserves for repair, never
for flow.

## Why this is the same class as 3I1VnwDm

`3I1VnwDm` ("untriaged findings occupy plan's WIP slots: capture should never
consume a refinement slot") established that a slot is for work being
REFINED, and that something merely parked there is a flow bug rather than
inventory. A blocked item is parked in exactly that sense: nobody can refine
it to the ready bar until its blocker retires, so it consumes a refinement
slot while being unrefinable.

## Not asserted here

Whether the fix is to exclude blocked items from the `plan` count, to refuse
`block` on a `plan`-phase item, to auto-return a newly-blocked item to
`backlog`, or to leave the limit alone and treat this as the flow review's
business (`review.md`). Each trades differently against "a full phase still
admits the motion that cannot sensibly wait", and retuning a WIP limit is a
reviewed change to the machinery. This item records the observation and its
reproduction; the route is `plan`'s to decide.
