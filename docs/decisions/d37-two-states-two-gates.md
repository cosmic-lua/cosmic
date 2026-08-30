# D37 — the board holds two states; quality is two gates, not stages

- **date:** 2026-08
- **status:** amended 2026-08
- **context:** the flow system ran a six-phase kanban (`backlog` →
  `plan` → `ready` → `do` → `check` → `land`) with per-phase WIP
  limits in `_work/flow.tl`, a triage bound, a hand-run flow review
  to tune the numbers, and a six-chapter skill (~1900 lines) to say
  what it all meant. at the time of this decision the live board held
  206 items in `backlog`, 2 in `plan`, 1 in `do`, 2 in `check`, and
  `ready` and `land` were both empty: the intermediate columns were
  not where work sat, and most of the rules existed to govern
  transitions between near-empty queues. each phase also restated a
  fact the item already carried — `do` is "claimed", `check` is "PR
  open, no verdict", `land` is "verdict accept", `ready` is "the spec
  passes the bar" — so the columns could drift from the facts and the
  tool needed refusal machinery (limits, forced moves, returns,
  de-phasing) to keep them honest. the system's goal is flow across
  concurrent agents at high pace with rework rare, and the phase
  vocabulary was overhead against it, not protection.
- **decision:** an open workable leaf is in exactly one of two
  states, and everything finer is derived, never declared:
  - **todo** — unclaimed; *pullable* when its spec passes the check:
    a Change that decides the work, walls stated as optional prose
    where a contract is near. acceptance is not spec content at all —
    the CI gate passing is the one acceptance every item shares, and
    proof specific to a change rides the diff as a test the gate
    runs. otherwise refining it is the work.
  - **doing** — claimed; the claim is the lock and a lease. within
    doing, the item's own facts (`pr`, `verdict`) say what happens
    next; a released claim with the gap named returns it to todo.
  - two WIP rules replace the per-phase table: one claim per
    concurrent worker (capacity spreads with the number of agents),
    and a single bound on `doing` as a whole — at the limit, taking
    NEW work is refused; finishing motions (a release, a verdict, a
    merge, a takeover of a stale claim) never are. the bound is what
    stops accumulation when workers come and go: claims and open PRs
    outlive the sessions that made them.
  - quality is held by exactly two gates: the spec bar before work is
    pulled, and a fresh-context review before anything merges. both
    survive at full strength; everything between them is thin.
  - the skill is one file, `skills/work/SKILL.md`.
- **rejected:**
  - **keeping the six phases.** columns that restate claim/PR/verdict
    facts can only agree with them or lie; every transition needed a
    rule, every rule a refusal path, and the live board showed the
    columns holding almost nothing. the rules cost more than the
    state they protected.
  - **keeping per-phase WIP limits and the flow review.** a limit
    binds arrivals, but the queues it bounded were empty in practice
    and the measurement that was to tune them (G8 flow health) was
    never built. one number on the whole in-flight span replaces four
    per-phase numbers and the machinery for tuning them.
  - **no bound at all (capacity only).** one claim per worker bounds
    what runs concurrently but not what accumulates: a claim and an
    open PR both outlive the session that made them, so a fleet of
    come-and-go workers grows unreviewed in-flight work without
    limit. the single doing bound closes exactly that hole, and by
    refusing only new takes it makes finish-before-start mechanical
    rather than advisory.
  - **keeping a per-item Acceptance section — and with it the
    five-section form (Goal / Change / Non-goals / Acceptance /
    Enablement).** a presence lint cannot judge substance — a
    scenario eval showed a spec passing every section check while
    being unbuildable, caught only by the puller's judgment — and
    even a machine-checked "at least one literal command" judged only
    shape. the deeper fault: a sidecar command runs at most twice
    (the puller and the reviewer) and dies with the item, while the
    same proof written as a test or ratchet in the diff runs on every
    future change. so acceptance is not spec content: the CI gate is
    the one definition of done, per-change proof lands in the tree,
    Goal context is the parent chain, dependencies are `blocked_by`
    edges, and walls are stated where a contract is near rather than
    filled in everywhere. the lint keeps the one section it can
    prove present: Change.
  - **dropping the review or the spec bar to go faster.** rework is
    the expensive path at high throughput — a wrong merge or a
    mid-build improvisation costs more than either gate. the gates
    are what make pace safe; they are the two things deliberately
    NOT simplified.
- **consequences:** gitboard sheds `move`, the phase field, the
  per-phase `LIMITS`, the triage bound, and the flow-review
  instrumentation, and gains the one `DOING_LIMIT` (a change on the
  `board` branch; the existing items are migrated in one commit —
  phases fold into the facts they restated). the verb surface follows
  the same rule — a verb whose meaning the item's facts already
  determine does not exist: `review` folds into `take` (an item
  awaiting a verdict, taken by a session that is not its builder, can
  only mean the review claim), `land` into `done` (which verifies the
  accepted PR merged), `check` and `status` into `show`, `uncompare`
  into `compare` (a direct contrary edge reverses in one commit), and
  `tree`, `find` and `next --take` retire — twenty-one verbs become
  fourteen. the board's
  git log keeps the old phase history readable. G8's measured-by
  becomes lead time, rework rate, and the cost ratchet — this amends
  the measured-by detail in D25, whose two-tier split stands. the
  cost accepted: sub-states are no longer visible as columns, so
  `show`/`next` must derive them well for the board to stay
  legible. revisit if the rework rate rises (the bar or the review
  weakening) or claim contention becomes the bottleneck (too little
  queue structure for the number of agents).
- **amended 2026-08:** the release exit is now two exits, split by
  which side stopped. a gap in the ITEM — a spec that cannot answer,
  a reopened decision, a falsified premise — is no longer released
  bare: the question becomes its own item (parented, so it is
  placed), the stuck item takes a `blocked_by` edge on it, and only
  then does the claim return — the item waits on the answer instead
  of re-entering todo to bounce again, and the question's `done`
  unblocks it with no further verb, while a blocker's queue order is
  lifted by what waits on it. a bare `drop` narrows to the
  WORKER-side release — a dead session, a spent budget — and asserts
  the item is fine to re-offer as-is. the derived-state doctrine is
  unchanged: blocked-todo already existed, and no third state was
  added.
