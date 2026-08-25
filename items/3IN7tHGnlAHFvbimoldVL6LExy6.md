`gitboard next` tells a session that `land ID` squash-merges the PR,
and `land` then refuses because it does not merge. The session that
follows the guidance verbatim earns a refusal on its first try.

## Evidence

Hit on 2026-08-24 landing item 3IKg4hsF (PR whilp/cosmic#1359). `next`
printed, under the `finish` action:

```
From `land` the item is already judged: `land ID` squash-merges the PR
its `pr` field names and ends the item, in that order.
```

Running exactly that:

```
gitboard-land: REFUSED: PR #1359 is not merged — `land` ends an item
whose merge is done, it does not merge. Squash-merge PR #1359, then
re-run `gitboard land 3IKg4hsF`, which reads the merge and ends the
item.
```

The two texts are in the same binary: `_work/guidance.tl:26` still
describes the pre-#1336 behaviour, and `_work/review.tl:148`
(`blocks_land`) states the post-#1336 one. `6f1694fa land verifies the
merge instead of performing it (#1336)` is the commit that split them —
it moved the merge out of `land` and left the guidance sentence
unchanged.

## Why it might matter

The guidance printed with an action is the manual a session reads
instead of a skill chapter (SKILL.md: "the mechanics arrive with the
answer"), so a stale sentence there costs every landing one wasted
loop, and it is exactly the failure mode the arrives-with-the-answer
design exists to prevent. The refusal text is good enough that the
session recovers, so this is friction, not breakage.

## Direction, not a decision

Rewrite `_work/guidance.tl`'s `land` sentence to name the two hands —
squash-merge the PR, then `land ID` reads the merge and ends the item.
Worth checking whether a test can hold the two texts together, since
nothing caught the drift when #1336 landed.

## Second occurrence

Hit again on 2026-08-25 landing item 3IODJMFv (PR whilp/cosmic#1369),
by a different session. `next` printed the same sentence and `land`
refused with the same text:

```
gitboard-land: REFUSED: PR #1369 is not merged — `land` ends an item
whose merge is done, it does not merge. Squash-merge PR #1369, then
re-run `gitboard land 3IODJMFv`, which reads the merge and ends the
item.
```

Two landings, two wasted loops, no session-specific cause: the cost is
one refusal per landing for as long as the sentence stands.
