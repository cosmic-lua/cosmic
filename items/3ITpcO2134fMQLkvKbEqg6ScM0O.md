## Goal

`bin/cosmic.pin` points at the first release whose tag commit carries
the patch-directory mechanism (PR #1424, main 6b88a0db, merged
2026-08-27 ~02:4x UTC), tearing down the wall holding 3ITo9Inv (the
tl_patch split) and, behind it, the queued patch items. The twin of
landed 3ISVlHT6, for the next cycle.

## Change

Two pin lines in `bin/cosmic.pin` (url + sha256, sha computed from
the downloaded asset), per 3ISVlHT6's procedure verbatim. Eligibility
of the candidate release: `git merge-base --is-ancestor 6b88a0db
<tag sha>` succeeds. Today's pin (2026-08-27-afad5b5) predates it —
verified 2026-08-27: the ancestry check fails for afad5b5e.

Timing: the daily release cron (06:00 UTC) should produce an eligible
release; dispatching one early is a human's call, never this item's.
If #1426 (cosmos pin bump) merges before the cron fires, the same
release also carries the new cosmos runtime — fine either way.

## Non-goals

No early release dispatch. No tl_patch split here (that is 3ITo9Inv,
gated on this landing). If this cycle's release lane goes red, that
repair is its own item — file and block, never debug inside the bump.

## Acceptance

Cold-start proof: `rm -f o/bin/cosmic && bin/cosmic --make fetch &&
bin/cosmic --make ci` ends `ci: PASS`. Checker proof of the MECHANISM:
the pinned binary's own `--make fetch` over a scratch project whose
pin carries a `<stem>_patch/` directory fixture applies it (or,
cheaper, the ancestry check above plus the pinned binary resolving
the real tree once 3ITo9Inv lands).

## Enablement

Waits on the 06:00 UTC cron release carrying 6b88a0db. Nothing else:
the procedure, the eligibility check, and the proofs need no new
mechanism.
