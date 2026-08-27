## Evidence

Found 2026-08-27 reviewing the board machinery for concurrency gaps.

`_work/gitverdict.tl:145` refuses a self-accept with `session ==
(it.claim or "")` — the claim alone. The durable half exists and is
consulted everywhere else: `flow.built_by` (`_work/flow.tl`) answers
"claim now, or in `builders` ever", and `next`'s `reviewable` walk uses
it, precisely because a rework takeover moves the claim while the item's
diff stays the first builder's. So after `move ID check --claim <second>
--force --why ...`, `next` correctly withholds the item from the first
builder — but the first builder reaching for `verdict` directly is not
refused on its own diff, since `it.claim` now names the second session.
The skill says "honour it if you reach for `verdict` directly", which is
honor-system at exactly the spot a one-line tool rule (`flow.built_by(it,
session)` instead of the claim equality) would enforce it. Related but
distinct: 3ITAFU4F is the takeover ERASING the record before `builders`
existed; this is the verdict verb not READING the record that now exists.
