## Evidence

Found 2026-08-27 reviewing the CAS surface under looped concurrency.

`gitgate.commit_and_publish`'s post-rebase revalidate re-asks exactly one
guard — the WIP admission (3ICDOfPj made that one faithful: force,
vacated, arrival). Every OTHER guard a verb applied is decided against
pre-race state and never re-asked, so a mutation whose preconditions a
concurrent commit falsified still lands whenever the rebase is textually
clean — which it always is when the two mutations write different files.
Two concrete instances, both cross-item:

- reciprocal `block` from two checkouts lands a cycle the verb's own
  `waits_on` check never saw — `_work/health.tl`'s header states this
  and detects it after the fact;
- concurrent `done` of a container's last two children: each session
  reads the other's child as still open, so neither computes
  `rephased_parent`, both push cleanly (different files), and the parent
  is stranded open, workable and unphased — `status` reports it as "off
  the board without being finished", but nothing prevented it.

The current design is detect-and-repair (status/health) for this class.
The principled upgrade is not accreting per-guard revalidate closures —
they will drift the way the WIP one did before 3ICDOfPj — but having the
lost-race path re-run the WHOLE verb against merged state: drop the
commit, sync, recompute the mutation from a fresh `store.list`, bounded
retries. The verbs are already near-pure decisions over the item list,
so the shape is a refactor of the publish contract (a mutation function
instead of a commit plus one invariant), not new policy.
