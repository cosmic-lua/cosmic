## Change

Split `_work/store.tl` so the persistence layer stops living at the
lint cap. Re-measured 2026-08-29 (`wc -l`, post wave-11): store.tl is
EXACTLY 500 — the one file still at the cap (the original prose also
named flow.tl at 500; the two-state rewrite resolved that — flow.tl is
379 now). Next-nearest: gitverbs.tl 493, converge_test.tl 423. The
history of HOW files reach the cap (two overlapping PRs whose
line-count predictions were each right alone) is in this sidecar's
earlier prose below and stands as the rationale: a split that leaves
real headroom, not a prose trim that resets the trap.

The seam, measured (`grep -n "^local function" _work/store.tl`): lines
282-448 are the remote/CAS/log half — `has_origin`,
`conflicted_items`, `rebase_onto_remote`, `sync`, `publish`,
`history`, `touched_at` — while 52-281 are local persistence (`git`,
`git_ok`, `open`, paths, `load_item`, `resolve`, `read_spec`, `list`,
`stage`, `save`).

1. New `_work/publish.tl` receives the seven remote/log functions
   verbatim (no behavior change — this is a move). The `Store` record
   and the `git`/`git_ok` plumbing stay in store.tl; export `git` and
   `git_ok` from store's module table so publish.tl calls them
   through `store.` (they already take `Store` as arg 1, so no
   signature moves). The `Event` record moves with `history`.
2. Callers update imports mechanically: measure with
   `grep -rln "store\.\(sync\|publish\|history\|rebase_onto_remote\|has_origin\|touched_at\|conflicted_items\)" _work/ | grep -v _test`
   and change each site to `publish.<fn>`; same sweep over the tests.
   No call-site logic changes.
3. Both halves must land with ≥60 lines of headroom — the reviewer
   measures with `wc -l`; the lint gate enforces the cap itself.
4. Coverage: moving lines makes the ratchet see a new file — if the
   gate demands it, regenerate with `--make coverage --baseline` in
   the same diff (never hand-edit), and the baseline diff must be
   row-moves only, no floor lowered.

## Non-goals

No behavior changes anywhere — pure move plus import updates; every
existing store/publish/race test passes unmodified except for import
lines. No API renames. gitverbs.tl at 493 is NOT this item's problem;
the sweep result is stated above, not acted on.

---

(Original evidence prose, kept for the rationale the Change cites:)

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

## Update, 2026-08-27 — a second file reached the cap, the same way

`_work/flow.tl` is now also exactly 500. Measured after PR #1475 merged:

    wc -l _work/flow.tl _work/store.tl _work/converge_test.tl _work/action.tl
    500 _work/flow.tl
    500 _work/store.tl
    498 _work/converge_test.tl
    495 _work/action.tl

Two files with zero headroom, two more within five lines. The next line
added to any of the four needs a split first.

`flow.tl` arrived there by the same route this item already describes,
which is what makes the pattern worth naming rather than fixing one file
at a time. Its spec measured 490 and predicted the addition would fit;
it did not, and the shortfall was covered by condensing two doc comments
that sat OUTSIDE the change's own scope. The PR body called that "no
substance dropped". That is close but not exact: the sentence explaining
why there is no goal tier, and a worked A-built/B-repulled example that
had landed one PR earlier, are both gone. The argument in each comment
survives; the illustration does not.

That is the real cost of treating the cap as a budget to be met rather
than a signal to split. Each change pays for itself by deleting prose
some earlier change added deliberately, the file stays at the limit, and
the next change inherits a smaller reserve and a thinner file.

## What this changes about the fix

The single-file framing above is too narrow. Trimming `store.tl` alone
leaves `flow.tl` at 500 and the same arithmetic in place, so the useful
scope is a decision about the four files together: which of them carry
more than one concern and should be split, and what the convention is
when a change's own budget does not fit.

Worth pairing with `3IVGWI8c`'s outcome, which split
`_work/gitverbs_test.tl` and took it from 7 lines of headroom to 207.
That is the shape that worked; it also shows the cost, since the split
added 24 lines in total for the second file's header and imports.
