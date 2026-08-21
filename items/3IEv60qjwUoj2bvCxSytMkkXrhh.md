## Evidence

`land` is the only phase with no ownership and no exit check, so two
sessions are handed the same finish and either may end the item without
establishing that the PR merged.

Measured 2026-08-21 on item `3I7LNDrF` (cosmos pin bump wave 2, PR
#1303, claim `piji6k`). Board history for the item:

```
18:41:45  5658f1cc  verdict 3I7LNDrF accept (check -> land)
18:42:44  328980ec  done 3I7LNDrF completed (from land)
```

This session, meanwhile:

```
18:42:22  gitboard status      → land 1/3  3I7LNDrF @piji6k pr:1303
18:42:2x  gitboard next --session board-state
          → finish 3I7LNDrF — land holds 1/3 — accepted, awaiting merge
18:43:xx  merge_pull_request #1303 squash → merged aaf4af95
18:43:xx  gitboard land 3I7LNDrF
          → REFUSED: 3I7LNDrF is in no phase — only an accepted item lands
```

Two sessions drove one item at once, and the one that ran `done` was
not the one that merged.

## Two facets, one root

**No lease on `land`.** `next --session NAME` withholds a verdict on
work that session built, because the claim records who built it. There
is no equivalent for a finish: `action.phased_action` returns
`finish landing[1]` to every caller, whatever any other session is
doing with it. The claim is present on the item and simply not
consulted here, so the fix may be as small as the lease `do` already
has — `land` is the phase where a duplicated action issues an external,
irreversible call.

**`done` from `land` asserts completion it never checked.** `land` is
not in `NO_DONE` and `reason` defaults to `completed`, so `gitboard done
ID` from `land` records the item finished with no read of the PR. For
roughly a minute here the board said `3I7LNDrF` was completed while PR
#1303 was still open; it happened to close because this session merged
it moments later. Had that merge failed, the board would carry a
completed item whose PR never landed, and nothing would ever say so.

The two compound: the session with no lease is also the session allowed
to declare the work done without looking.

## Why it might matter

Every landing runs this way today. `gitboard land`'s own merge step is
403-refused in scheduled sessions (`3I8lUm1r`), so the out-of-band
merge-then-`land` (or merge-then-`done`) sequence is the normal path,
not an exception — which is exactly the path that splits "who merged"
from "who ended it".

## Shape of a fix

Worth deciding together, not separately: whether `land` takes a claim
the way `do` does (and `next` withholds a finish another session holds),
and whether `done` from `land` must read the PR and refuse a
`completed` resolution for one that is not merged — `land`'s
already-merged path proves the read is available.
