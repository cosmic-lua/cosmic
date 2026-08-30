## Change

Evidence (re-review of PR #1538, 2026-08-30, observed live): `take`'s
review-claim routing (`_work/gitverbs.tl:153` at measurement; re-measure)
derives a review claim only when `it.verdict == ""`. An item that was
bounced (request changes), respecced, and reworked keeps its stale
verdict field until the fresh verdict lands — so a re-reviewer's
`take --force` on the still-live builder claim falls through to the
BUILD path and appends the reviewing session to `builders`, which then
trips `distance_refusal` against that reviewer's own verdict (session
review-3IHwkB1z-1788049700-rev2 had to use the verdict's `--force
--why` repair to record at all).

The change, in `_work/gitverbs.tl` (cmd_take's routing) only: a take
on an item that HAS a PR and whose recorded verdict is `request
changes` routes as a REVIEW claim when the taking session is not the
item's recorded builder — the bounced-and-reworked state is exactly
the state whose next actor is a re-reviewer; the original builder's
takes keep routing to the build path (rework). The `verdict == ""`
branch stays as is. Tests in `_work/gitverbs_test.tl` (or the claim
test file if routing tests live there — follow the existing seam): a
fixture item with pr set, verdict "request changes", builder A —
take by session B claims the review (B lands in reviewer, NOT in
builders); take by A still routes as build/rework; the fresh-item and
no-verdict paths unchanged. Mutation-verify the routing condition
(drop the request-changes arm, watch the B-claims-review test go red).

## Non-goals

No change to the distance guard itself, the verdict verb, or claim
leases. No new flags.
