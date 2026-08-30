Evidence (re-review of PR #1538, 2026-08-30): `take`'s review-claim
routing (`_work/gitverbs.tl:153`) derives a review claim only when
`it.verdict == ""`. An item that was bounced (request changes),
respecced, and reworked keeps its stale verdict field until the fresh
verdict lands — so a reviewer's `take --force` on such an item's
still-live builder claim falls through to the generic build path and
appends the REVIEWING session to `builders`, which then trips
`distance_refusal` on that same session's own verdict attempt
(observed live: review-3IHwkB1z-1788049700-rev2 had to use the
verdict's `--force --why` distance repair to record at all). The fix:
`take_review`'s condition also covers "a verdict exists but is stale
against the current head/spec pair" — the same staleness the verdict
guard itself computes — so a re-review claim on a reworked item routes
as a review claim, not a build claim. Tests: take on a
bounced-then-reworked fixture claims as reviewer (builders unchanged);
the existing fresh-item and no-verdict paths hold; mutation-verify.
