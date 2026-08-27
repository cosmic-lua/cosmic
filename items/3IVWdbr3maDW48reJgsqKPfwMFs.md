`_work/store.tl` is exactly 500 lines — the lint cap — so the next line
added anywhere in that file fails `cosmic --make lint`, and every change
to it now carries a mandatory trim.

Measured after PR #1466 (item `3IVKVXoO`) merged:

    wc -l _work/store.tl   →   500

The cap is `≤ 500`, so nothing is red today. There is simply no headroom.

## How it got there, which matters for the fix

Two PRs in review at once each shrank `store.tl` and each predicted a
comfortable result — #1466 predicted 481. They overlapped in the file:
#1461 (item `3IUFODun`, the `spec` compare-and-swap) merged first, so
#1466's squash landed on top of it and the two estimates did not
compose. #1466's own merge commit had already spent five lines of
comment prose to get under the cap once; that trim bought room that the
other merge then consumed.

So this is not one file that grew carelessly — it is two independently
reasonable changes whose line-count predictions were each correct alone
and wrong together.

## What is worth deciding

The cheap fix is another prose trim, which buys a few lines and sets up
the same surprise next time. `store.tl` carries the git-backed
persistence layer — `save`, `publish`, `rebase_onto_remote`, `history` —
and it is under active change from several directions at once, so it is
the wrong file to keep at the line the lint refuses.

Better candidates, none of them chosen here: split the publish/CAS half
from the load/save half, since they are already distinct concerns with
distinct callers; or move `history` out, since it reads the log rather
than writing state. Either would leave real headroom rather than
resetting the trap.

Whoever takes this should also check whether other `_work/**` files are
near the cap, since the same two-PRs-one-file arithmetic applies
wherever review rounds overlap.
