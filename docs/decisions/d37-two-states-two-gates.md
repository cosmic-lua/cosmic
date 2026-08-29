# D37 — the board holds two states; quality is two gates, not stages

- **date:** 2026-08
- **status:** active
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
  - **todo** — unclaimed; *pullable* when its spec passes the check
    (Change / Non-goals / Acceptance, measured claims, literal-runnable
    commands), otherwise refining it is the work.
  - **doing** — claimed; the claim is the lock and a lease. within
    doing, the item's own facts (`pr`, `verdict`) say what happens
    next; a released claim with the gap named returns it to todo.
  - the only WIP rule is one claim per concurrent worker, so capacity
    is the number of agents, not a number on a column.
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
    never built. one-claim-per-worker bounds work in progress by
    construction, with no numbers to tune and no refusal machinery.
  - **dropping the review or the spec bar to go faster.** rework is
    the expensive path at high throughput — a wrong merge or a
    mid-build improvisation costs more than either gate. the gates
    are what make pace safe; they are the two things deliberately
    NOT simplified.
- **consequences:** gitboard sheds `move`, the phase field, `LIMITS`,
  the triage bound, and the flow-review instrumentation (a follow-up
  change on the `board` branch; the existing items are migrated in
  one commit — phases fold into the facts they restated). the board's
  git log keeps the old phase history readable. G8's measured-by
  becomes lead time, rework rate, and the cost ratchet — this amends
  the measured-by detail in D25, whose two-tier split stands. the
  cost accepted: sub-states are no longer visible as columns, so
  `status`/`next` must derive them well for the board to stay
  legible. revisit if the rework rate rises (the bar or the review
  weakening) or claim contention becomes the bottleneck (too little
  queue structure for the number of agents).
