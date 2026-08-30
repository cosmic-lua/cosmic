## Problem

`_build/cast_sites.tl`'s `--reconcile` keys a recorded cast site on
`path\tline` (`_build/cast_sites.tl:116-140`), so any edit that shifts
a line carrying an `as` cast reads as a newly discovered, unclassified
site: the tool refuses to write rather than carry the existing class
forward. The `_build/cast_sites_test.tl` failure message advertises
`bin/cosmic --make run _build/cast_sites.tl --reconcile` as the regen
command, but from the shifted state that command cannot produce the
correct file — it is exactly the case it declines to guess at.

Evidence, from building batch 6/7 of the runner-mode migration
(PR #1556, 2026-08-30): deleting 404 bare `test_*()` self-call lines
from 20 `cosmic/*_test.tl` files shifted six rows in
`docs/design/cast-sites.tsv` naming sites in `log_test.tl`,
`rand_test.tl` and `searcher_test.tl`. `--reconcile` refused. The
builder verified the cast text at each new line was byte-identical to
the old one (a clean one-to-one map), moved the six rows by hand
carrying each class forward verbatim, and re-ran `--reconcile`, which
then succeeded and reproduced that file byte-for-byte — so the
committed inventory is provably what the tool generates, and nothing
was reclassified.

This will recur. The tree-migration container (3IOCdooE) has six more
line-deleting batches, and other in-scope `*_test.tl` files carry
recorded casts, so each batch hits the same refusal and each agent is
told by the failure message to hand-classify sites that are already
classified and merely moved. The likely fix: key `reconcile` on the
cast line's CONTENT (or a content hash) rather than its line number,
or fall back to content when the line-number lookup misses, so a pure
line shift regenerates through the advertised command. Scope and shape
are unmeasured — this item needs refinement to the spec bar before it
is pullable.
