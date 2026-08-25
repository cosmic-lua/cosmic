`gitboard` has no verb that changes an item's title. `gitboard help`
lists new, attach, compare, uncompare, block, unblock, spec, check,
status, tree, stats, next, move, verdict, done, land, show, find,
sync — `spec` replaces the sidecar prose, and nothing touches the
`title` field in `items/<ksuid>.tl`.

That matters because refinement routinely invalidates a title. Item
3IODJMFv was opened as "number-to-integer narrowing: a math.type guard
the checker learns from deletes a 30-cast bucket"; the refinement pass
measured the bucket at 13 sites, not 30, and proved by probe that a
`math.type` narrowing closes at most one of them — so the title named
a wrong count and a mechanism the refined spec explicitly rules out,
while `status`, `tree` and `next` all render work by title.

Worked around once on 2026-08-25 by hand-editing the `["title"]` line
in `items/3IODJMFvKb6RP3cAWnGe9Br4NU2.tl` and committing it directly
(board commit "retitle 3IODJMFv after refinement measured the bucket
at 13 sites, not 30"), which is what the `work` skill's hard rule
prescribes for a missing verb. A `retitle ID TITLE` verb beside
`spec`, going through the same commit-and-publish path in
`_work/gitgate.tl`, is the fix.
