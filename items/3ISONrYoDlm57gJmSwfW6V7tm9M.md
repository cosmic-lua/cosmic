Two verbs read claim liveness differently, and neither reads the one
signal that actually proves a builder is alive: pushes to the item's
PR branch. Observed 2026-08-26 on item 3IOCco6e (PR #1405): the
builder pushed their rework commit a1ea78cf at 14:05; at ~14:13 `next`
offered this session the item as a finish with an explicit "hand it
back with --claim <this-session>" instruction, but `move ... check`
then REFUSED with "claimed by f00d09f2 — take over a live claim with
--force --why". So the router judged the claim takeable while the
guard judged it live, the session had already duplicated the
builder's fix on the branch by the time the refusal landed (the
builder's own a1ea78cf carried the identical guard change), and the
handover ultimately went through as a --force repair, polluting the
repair log the way 3INHKjHG already describes for ordinary rework
handbacks. Two fixes compose: (1) one liveness rule shared by next and
move, so the router never offers what the guard will refuse; (2) the
lease should treat a push to the item's pr branch as claim-keepalive —
the board only sees board commits, so a builder deep in a
build-test-push loop looks idle exactly when they are most active.
git already has the data (the PR head's committer date); the check
that reads the PR for `move --pr` could record it.
