## Goal

G8 — the flow system, in service of G6's anchor case: the board decides what
matters most, but it can only rank what it can see, and today the state of
the scheduled lanes (release, fuzz, docs) is invisible to it. A broken
release pipeline should make its own repair the next thing `next` hands
out, without waiting for a human to notice a red run in the Actions tab.
This is the countermeasure item 3IHCIZWU's Direction named; that item is
the incident, this is the mechanism.

## Evidence

The release perf gate went red on 2026-08-18, the first scheduled run after
it became blocking, and stayed red for five consecutive days (runs
32108462657 .. 32557687549) while ~25 PRs landed and the board's right side
ran a two-item chain. Nothing on the board or in issues tracked it until
2026-08-22 (whilp/cosmic#1311, board 3IHCIZWU). The failure was detection,
not prioritization: the ordering machinery could have expedited a repair
item in one `compare`, but no item existed to compare.

The board already has every half of the needed behavior, just not wired to
lanes:

- `status` already surfaces a binding bottleneck as a directive: "flow:
  every ready item is blocked; the chain bottoms at 3ICDH3lW ... resolve
  that before promoting more" (observed 2026-08-22).
- `_work/flow.tl` is pure ("no network and no filesystem"), so lane state
  must enter as data, not as a probe inside the rules.
- `sync` is the one read verb that already touches the network.
- `admits_over_limit` (_work/flow.tl:119) is the designed two-line hole
  for arrivals that cannot wait; an accept into land already uses it.
- `action.next_action`'s finish-first rule already front-runs a class of
  work ahead of ordinary pulls.

## Direction

Not a phase. A phase is the state of a workable leaf; lane health is a
fact about the world. Making it a column would put non-items on the item
board. Instead, four small pieces along the existing seams:

1. **observe at sync**: `sync` (the verb that already has the network)
   also fetches the latest scheduled-run conclusion per required lane
   (release.yml, fuzz.yml — the required set is data, beside LIMITS) and
   records it as a fact the reads can see. Reads stay tokenless and
   offline; the fact is only as fresh as the last sync, same as the rest
   of the board.
2. **a red lane mints one repair item, idempotently**: keyed by lane, so
   five red days cost one item, not five; a lane back to green closes it
   or leaves it to a human `done`. Only the monitor mints these, which is
   what keeps the class rare.
3. **admission and ordering**: the minted item is the motion that cannot
   wait — `admits_over_limit` admits it, and `action.next_action` places
   lane repair with the finish-first class, ahead of ordinary pulls.
   `status` prints a lanes row beside the WIP table so the state is
   visible even when green.
4. **no expedite field.** A class-of-service marker is the kind/rank
   field this board deliberately does not have, and an expedite flag any
   session can set inflates until it means nothing. The two spellings the
   system already has cover the human case: `compare <item> <current-top>`
   IS an expedite — one committed, auditable judgment — and a blocker
   chain that bottoms at the repair item already redirects the whole
   queue. If review ever shows those are not enough, the marker proposal
   comes back with that evidence.

Refinement should split 1+2 (the observation half, needs the GitHub read)
from 3 (the flow/policy half, pure and testable with a fake lane fact),
and decide where the lane fact lives so it survives a fresh worktree
without joining the append-only item history.
