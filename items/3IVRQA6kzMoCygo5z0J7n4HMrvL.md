## Evidence

Found while reviewing whilp/cosmic#1465, which added the refine claim
and its ready-shed. That PR closes the path it introduced; this is the
adjacent one it deliberately walled off, recorded so it is not
rediscovered as a surprise.

`cmd_move` clears `it.claim` on an arrival into `ready`
(`_work/gitverbs.tl`, the rightward guard, plus the pre-existing
`is_return` clear). But a **same-phase** move returns early into
`set_in_place` before reaching that block. So:

```
gitboard move ID ready --claim X      # on an item ALREADY in ready
```

routes through `set_in_place`, writes `claim = X`, and nothing later
clears it. `action.pullables` then honours that claim indefinitely —
its `held` test is `(i.claim or "") ~= "" and session ~= "" and
i.claim ~= session`, with **no lease term at all**, unlike the refine
draw's `is_refine_stale` and the review draw's `is_review_stale`.

The result is a `ready` item reserved for one session permanently:
every other session's `next` skips it, and no lease ever frees it. The
only escapes are a `--force` takeover or a hand edit.

This is pre-existing, not introduced by #1465 — the same-phase early
return and the lease-free `pullables` both predate it. #1465's spec
walls off `pullables`/`unheld` and the takeover rules explicitly, which
is why it was right to leave alone there.

## What this item should settle

Which of the two halves to fix, and they are not equivalent:

1. **Give `pullables` a lease**, mirroring the refine and review draws.
   This is the general fix: any stuck claim in `ready` frees itself
   after the interval, whatever wrote it. It needs a decision on WHICH
   lease — `ready` is a buffer nobody is working, so a claim there is
   not evidence of work in progress the way a `do` or refine claim is,
   which argues for a short one or for treating any claim in `ready` as
   stale on sight.
2. **Clear the claim in `set_in_place` when the phase is `ready`**, so
   the write cannot happen. Narrower, and it closes the one known
   entry point without deciding anything about leases — but it leaves
   `pullables` lease-free, so a claim arriving by some future path is
   permanent again.

Prefer 1 if a defensible interval exists, since it removes the class;
2 is the cheap stopgap. Whichever lands should also say, in
`pullables`' own comment, why it does or does not carry a lease — the
absence currently reads as an oversight rather than a choice.

## Non-goals

- No change to the takeover rules (`--force --why`).
- No change to the refine or review leases, or to the do lease.
