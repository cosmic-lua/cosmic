Evidence, observed twice in sonnet scenario evals (2026-08-29, s2 both
rounds): after `drop ID --why "<gap>"`, the item snaps straight back to
pullable — the gap lives only in the board log, so `next` re-offers the
same item and the next session re-discovers the same gap from scratch
(the eval worker: "next still names the same item... re-taking it would
repeat the identical bounce"). `show ID` prints the git history, but
nothing marks a recently-bounced item at the offer itself. Candidate
shapes, undecided: surface the last drop reason on `show`/`next` for
items whose most recent board commit is a drop; or hold a bounced item
off pullable until its spec revision moves. The countermeasure is a
gate/render change in `_work`, not prose.
