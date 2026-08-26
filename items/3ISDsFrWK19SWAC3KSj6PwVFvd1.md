gitboard has no verb that changes an item's title. `spec` replaces the
sidecar prose and `new` sets the title once, at mint time; nothing
edits it afterwards.

That gap bites during refinement, which is when a title is most likely
to become wrong. A capture is titled from what its evidence looked like
at first sight; refining it one rung down often changes what the item
IS. 3ISDGNep was filed as "profile the per-value domain check before
optimizing it" and the refinement pass did the profiling, so the ready
spec's `Change` is the optimization itself — leaving a title that tells
a claiming session to do something the spec's Non-goals forbid. The
title is what `next`, `status` and `tree` render, so it is the only
thing most readers see.

Worked around 2026-08-26 the way the `work` skill's hard rules allow —
editing `items/3ISDGNepIOn2g0aoax1nq8lHwr7.tl`'s `title` field directly
and committing, board commit "retitle 3ISDGNep after refinement
attributed the cost (no retitle verb)". The file format is the
contract, so the edit is safe; what it skips is the push-as-
compare-and-swap the verbs perform, which is the reason to have the
verb rather than repeat the workaround.

Shape, matching `spec`'s: `gitboard retitle ID TITLE`, one commit,
published like every other mutation, with the same rebase-and-recheck
on a rejected push. The commit subject the flow review reads should
name a verb its parser already knows or be added to the vocabulary
alongside `new`/`attach`/`move`/`verdict`/`done`/`block` — the flow
review's instrument (`review.md`) parses a commit's first word as its
verb, so an unrecognised subject is a hole in that record.
