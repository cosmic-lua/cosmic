The twin of landed 3ISVlHT6, for the next cycle: move bin/cosmic.pin
to the first release whose tag commit carries the patch-directory
mechanism (PR #1424, main 6b88a0db, merged 2026-08-27 ~02:4x UTC).
Eligibility: `git merge-base --is-ancestor 6b88a0db <tag sha>`.
Today's pin (2026-08-27-afad5b5) predates it — verified 2026-08-27,
`git merge-base --is-ancestor 6b88a0db afad5b5e` fails — which is the
wall holding 3ITo9Inv (the tl_patch split) and, behind it, the three
queued patch items. The daily release cron (06:00 UTC) should produce
an eligible release; dispatching one early is a human's call, never
this item's. The procedure is 3ISVlHT6's spec verbatim (two pin
lines, sha computed from the downloaded asset, cold-start
`rm -f o/bin/cosmic && bin/cosmic --make fetch && bin/cosmic --make
ci` → `ci: PASS`), with this cycle's checker proof being the
MECHANISM rather than a narrowing: the pinned binary's own
`--make fetch` over a scratch project whose pin carries a
`<stem>_patch/` directory fixture applies it (or, cheaper, the
ancestry check above plus the pinned binary resolving the real tree
once 3ITo9Inv lands). Note the release lane's perf gate was green for
afad5b5's cycle; if this cycle's run goes red instead, that repair is
its own item — file and block, never debug inside the bump.
