## Evidence

2026-08-20 machinery audit of the board branch (at 5577fd73; still
true after #1298/#1299). `gitgate.commit_and_publish`'s post-rebase
revalidate re-checks ONLY the WIP arrival, so it does not reproduce
the verbs' admission policy after a lost push race: (1) `--force`
does not survive the retry — a forced arrival into a full column that
loses the race to ANY concurrent commit is refused after rebase, so
the repair the force authorized silently fails; (2) `cmd_attach`
passes `from = nil` unconditionally, so re-parenting an
already-phased item is misclassified as an arrival into its own phase
and refused after a lost race whenever that column is at limit —
exactly the non-arriving-write class #1287 fixed for spec/block; (3)
the `block` verb's deadlock check runs against the LOCAL checkout
only, and two sessions racing reciprocal `block X Y` / `block Y X`
edit different files, rebase cleanly, and land a cycle (status
reports it since #1298, but the race can still create it — the
revalidate should re-ask the block invariant). Related, in
`store.publish`: after 3 failed rounds (or "push could not start")
it reports failure but keeps the local commit standing, which the
NEXT mutation's publish silently ships — contradicting "drops its own
commit whole"; a mid-`save` stage failure similarly leaves a dirty
index that pollutes the next commit.

(4) The revalidate does not carry the `vacated` credit `cmd_new` gained
for net-zero decomposition (#1304): `from` is nil for an entry, so
`flow.is_arrival` is true and the merged-state check refuses a child
whose parent de-phased in the same commit, whenever the column is over
limit. Same root cause as (1) and (2) — the re-check reproduces the
limit but not the verbs' admission policy — and newly reachable: with
`plan` at 44/12, every `new --parent` that loses a push race hits it.
The mutation drops whole, so nothing half-lands and the session may
retry; the cost is a refusal that the up-front gate already decided
against.
