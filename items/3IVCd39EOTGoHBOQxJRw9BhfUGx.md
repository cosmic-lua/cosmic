A `set`-in-place claim overwrite silently reassigned an item's builder
while the original claimant was mid-slice, so the board's record of who
built a PR is wrong — and the no-self-review guarantee, which is derived
entirely from that record, no longer holds for the affected item.

Observed 2026-08-27 on `3IU6AZEx` (runner-mode batch 1/7):

```
13:51:10  d16d86f1  move 3IU6AZEx ready -> do        (session 0b13d2b4)
13:51:24  c77037bd  set 3IU6AZEx in do               (claim -> 05f7c552)
14:01:58  f5fd531a  move 3IU6AZEx do -> check        (pr #1458)
```

Session `0b13d2b4` pulled the item and its worker built the change and
opened PR #1458. Fourteen seconds after the pull, session `05f7c552`
set the claim in place. The item now reads `claim: 05f7c552`, so every
verb that asks "who built this" gets the wrong answer, and `next` will
offer PR #1458 to `0b13d2b4` — the session that actually wrote it — as
a review it is eligible to accept. The one rule the board exists to
enforce is defeated without any verb refusing anything.

It is currently masked: a third session (`e532d9f6`) holds the review
claim on both `3IU6AZEx` and `3IU6AgNN`, so `next` skips them as held
rather than as unreviewable. The masking is coincidental, not a
safeguard.

Note the ordering against `3IU9CuuS` (PR #1454, merged ~06:01Z), whose
`## Change` added exactly the guard this should have tripped:
"`set_in_place` refuses overwriting a live foreign claim without
`--force --why`, the same takeover rule the crossing move applies — the
observed silent-takeover hole." The overwrite here happened at 13:51Z,
nearly eight hours AFTER that landed. So either the guard does not cover
the path `set` took, or the overwriting session passed `--force`, in
which case a forced takeover still leaves no trace on the item that a
later reviewer or `next` can see. Establishing which of the two is the
first step; they need different fixes.

Worth deciding alongside: whether `built_by` should be a separate,
append-only fact from the mutable `claim` at all. A claim is a lease and
is meant to move; authorship is not, and today one field carries both.
