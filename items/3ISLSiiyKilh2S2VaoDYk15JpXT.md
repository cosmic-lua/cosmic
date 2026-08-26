`gitboard spec ID FILE` rewrites an item's spec sidecar in any phase,
with no claim check and no phase check, so a refining session can
silently replace the definition of work a DIFFERENT session has already
built and handed to review.

Observed 2026-08-26, sessions f00d09f2 and 7b2d5794 on item 3ISJKfRg.
`next` (f00d09f2) answered `refine 3ISJKfRg … plan holds` and that
session began measuring. While it measured, 7b2d5794 claimed the item,
implemented it and opened PR #1406, moving it `do -> check` at 14:02.
f00d09f2's `gitboard spec 3ISJKfRg …` then succeeded at 14:0x against an
item in `check` carrying another session's claim, replacing the
one-paragraph spec the PR was built from with a five-section one. The
reviewer now judges a diff against a spec written after it, by a session
that never saw the diff. Here the two happened to describe the same two
edits, so nothing was harmed; a spec that had asked for anything more
would have failed a PR for not implementing a requirement that did not
exist when it was written.

The push-as-compare-and-swap does not cover this: it refuses two sessions
editing the same item only when their commits race, and these did not —
the `move` landed first and the `spec` rebased cleanly on top of it.

Candidate shapes: `spec` refuses an item in `do`/`check`/`land` unless
`--force`, the way the ready bar's other invariants are enforced; or it
refuses only when the item carries a claim belonging to a different
session, which still allows a claimant to refresh measured facts at pull
(the slice loop's step 2 requires exactly that). The second is the
narrower rule and matches what the skill already says the verb is for.
