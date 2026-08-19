## Evidence (2026-08-19)

With `plan` at 18/12, `gitboard new "cast wave 3: …" --parent 3HyArM3A
--spec-file …` was refused up front: `REFUSED: plan is at 18/12 — drain
it before pulling more`. But 3HyArM3A was itself a plan-phase leaf, and
`cmd_new` de-phases a parent that gains its first child IN THE SAME
COMMIT (`gate.dephased_container`, `_work/gitverbs.tl:81-87`) — so the
mutation's net effect on `plan` occupancy is zero. The up-front check
(`gate.wip_refusal(flow.board(all), nil, phase)` at
`_work/gitverbs.tl:76`) counts only the arrival, never the de-phase the
same mutation performs.

The consequence is a deadlock shaped like today: the highest-priority
refinement action was decomposing that exact epic, and the limit that
exists to force draining blocked the drain. The workaround was filing
the refined child as an unparented capture (3I7BSkD7) to attach later.

## Suggested shape

`wip_refusal` (or `cmd_new`/`cmd_attach` before calling it) accounts for
the same-mutation de-phase: when the parent is a phased leaf in the SAME
phase the child enters, the mutation is net-zero for that column and the
limit has nothing to refuse. Distinct from 3I44Et1Z, which fixes the
rebase-path re-check for non-arriving writes; this is the up-front check
on decomposition specifically. G8 material — attach under 3HyRdT1J when
plan drains.

## Owner decision, 2026-08-19

Confirmed by the goal owner: the up-front check should admit net-zero
decomposition — when filing a first child under a plan-phase leaf, the
same-mutation de-phase of the parent is accounted and the limit has
nothing to refuse. Refine toward that shape.
