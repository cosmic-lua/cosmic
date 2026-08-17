---
name: work
description: >
  The system of work for cosmic: work backwards from ranked goals,
  decompose ambitious outcomes into workable items that flow
  kanban-style across a WIP-limited board, and refine each item until
  a less sophisticated model can implement it reliably. The board
  lives on the orphan `board` branch as committed files, operated by
  gitboard. Use when planning what to build next, refining or
  decomposing work, pulling the next item to implement, reviewing an
  implementer's PR, or landing an accepted one.
---

# The system of work for cosmic

this skill is the operating manual for how work on cosmic (and its C
core, whilp/cosmopolitan) is defined, refined, implemented, reviewed,
and landed. it exists because two different kinds of model work on this
repo, and the system is designed so each does what it is best at:

- a **planner** — a sophisticated model (Fable-class) — works backwards
  from ambiguous, ambitious goals, decomposes them into concrete work,
  refines each piece until it is mechanically implementable, and
  reviews what comes back.
- an **implementer** — a less sophisticated model (Opus/Sonnet-class) —
  works backwards kanban-style: take the thing closest to completion
  forward. land a PR a planner accepted, then finish what is already
  in `do` (rework a planner sent back, and claimed work), then pull the
  oldest ready item — implement exactly what its spec says, and hand
  the result back.

the two lanes split the lifecycle cleanly: planners plan and review;
implementers implement and MERGE. the final gate is still always a
planner — nothing merges until a sophisticated model has judged the
implementation against the item's spec AND the goal it traces to
(`review.md`) — but the landing itself is implementer-lane work.

the planner's defining duty is not writing specs; it is making
implementers succeed. when a piece of work is too ambiguous for an
implementer, the planner does not hand it over anyway — it either
refines the spec further or changes the system (core first, then
docs, then skills) until the ambiguity is gone. see `enable.md`.

the chapters:

- `SKILL.md` — this file: the board, the roles, the session loops, the
  rules.
- `decompose.md` — working backwards from goals; the refinement
  ladder; the ready bar in full, with a worked example.
- `enable.md` — making implementers succeed: core > docs > skills.
- `review.md` — the planner's review verdicts and the friction
  feedback loop.
- `parallel.md` — running several implementer sessions at once:
  picking a disjoint set, isolation, and the brief an agent needs.

## the board in one minute

ALL work state lives on the orphan `board` branch of whilp/cosmic:
one committed file per item (`items/<ksuid>.tl`, `cosmic.literal`
data) with its spec prose in the sidecar `items/<ksuid>.md`. The
branch also carries the machinery (`_work/`) and its own `bin/cosmic`
trust root, so it is a runnable cosmic project on its own. Reach it
as a worktree of the checkout you already have:

```bash
git worktree add o/board board        # once per checkout
cd o/board && bin/cosmic --make build # once, on a cold worktree
```

that build produces `o/bin/gitboard`, the binary this branch ships,
and `gitboard` below means running it from the worktree — one process,
one verdict line, no make output interleaved with the answer.

**the verbs are the tool's to describe, not this skill's.** `gitboard
help` lists them and `gitboard help <verb>` gives one its options,
generated from the CLI itself, so that listing is current by
construction and cannot drift from what the tool does. how the
machinery is run, built and gated is the branch's own `README.md`,
beside it. what the verbs are FOR — when to reach for which, and what
the system means by them — is this skill, and that is the only half
that belongs on `main`.

**start every session with `sync`.** reads are a directory scan of
the worktree, so they are only as current as the last pull; a mutation
publishes against the remote and would discover a stale checkout the
hard way, as a refusal after the fact.

every verb ends with a `gitboard-<verb>:` verdict line — read that,
never a piped exit status. ids are KSUIDs; every verb accepts an
unambiguous prefix (`gitboard show 3I1v4K`), git-style. a KSUID orders
by its one-second timestamp, so "oldest first" is exact across
seconds and arbitrary within one — the board's queues are stable, not
the mint order of items filed in the same breath.

reads need no network and no token; a mutation is ONE commit on
`board` and publishes (push). a rejected push is the compare half of a
compare-and-swap: the tool rebases onto whoever moved first, re-checks
the WIP invariant against the merged board, and refuses if the limit
now binds, dropping its own commit whole — there is no lagged index,
no retry ritual, and no half-landed mutation. two sessions editing the
SAME item cannot rebase past each other; that refusal names the items
and hands back a clean checkout, so re-read and re-apply.

**a mutation publishes itself, and board state never goes through a
pull request.** the verb commits and pushes in one step, so there is
nothing to stage, nothing to batch, and no moment where a session
decides it has accumulated enough to publish — a claim, a verdict, a
bounce and an ended item are each on the remote as the verb returns.
pull requests are `main`'s: opening one over `items/**` would put a
review gate in front of state the tool has already validated, and
leave the board stale for as long as it sat there. a change to the
branch's own machinery is a different subject, and the branch's
`README.md` has it.

**the `board` branch is append-only: never rebased, never
force-pushed.** rewriting published state history breaks every
checkout's compare-and-swap at once.

**where TLS is intercepted, trusting the interceptor is an explicit
opt-in.** cosmic loads the system CA bundle only when
`SSL_USE_SYSTEM_CERTS` is set — a locally-installed CA never joins the
trust store just by being installed. so in an environment that
re-terminates TLS (a corporate egress proxy, a sandboxed runner) the
two verbs that reach GitHub — `move … check`, whose refusals read the
PR, and `land`, which merges it — fail every call with
`badcert_not_trusted` until the session says otherwise:

```bash
export SSL_USE_SYSTEM_CERTS=1   # only where a proxy re-terminates TLS
```

`sync` and the push half are git's, and git reads its own CA
configuration, so they keep working and the failure looks like one
verb being broken rather than the environment. set the variable in the
session, never in a committed file: it is a statement about where the
session runs, not about the board.

## roles emerge from the graph

an item carries no kind field; its role is its position in the
dependency graph, the way a file's role in cosmic is its position in
the tree:

| position | role |
|----------|------|
| ranked root | a **goal**: long-lived, ordered by rank |
| unranked root | a **finding**: captured evidence, awaiting triage |
| parented, open children | a **container** being decomposed |
| parented leaf | **workable** — the only thing that holds a phase |

roles change by changing the graph: `attach` is both decomposition (a
workable item that gains a child is de-phased into a container in the
same mutation) and triage (an adopted finding becomes a plan-phase
leaf). the goal trace is a checked property — every phased item must
reach a ranked root through its parent chain, and `check` names the
broken link when THAT item cannot. the board's own health (every
item's chain, and any leaf left off the board) reads from `status`:
one item's broken chain is everyone's to see and nobody's reason to be
refused a promotion.

decomposition is reversible without ceremony. an item that gains a
child is de-phased in the same commit; when its LAST open child ends,
the item returns to `plan` in the closing commit, which is where the
planner verifies the outcome its children were supposed to deliver and
ends it.

phases, left to right (only workable leaves carry one). a phase is
named for the action performed in it; `ready` is the one noun,
because nobody acts there — it is a buffer:

| phase | meaning |
|-------|---------|
| `plan` | traced to a goal, still ambiguous — the planner's until it meets the ready bar |
| `ready` | meets the ready bar (`decompose.md`); nobody's until an implementer pulls it |
| `do` | claimed work and rework — the implementer's, until a PR opens or a bounce |
| `check` | PR open; the planner's, until a verdict |
| `land` | accepted; the implementer's, until the merge |

every phase is WIP-limited. the numbers are the tool's — `status`
prints each phase against its own — and retuning one is a reviewed
change to the machinery, not a reading of this table.

the limits carry the label board's empirically tuned values. at the
limit, exactly two arrivals are admitted: a return (leftward motion —
the system correcting itself) and a move into `land` (an accept is a
decision already made). everything else queues; an over-limit phase
blocks further pull until it drains and nothing else. goals,
containers, and findings are never phased, so no exemption vocabulary
exists for them — they occupy no slot to exempt.

**work flows right to left.** finishing beats starting: verdicts
before refining, refining before intake, and an implementer lands and
finishes `do` before pulling ready.

GitHub keeps two jobs. pull requests carry fixes: the diff, its CI,
and its review conversation, exactly as before. issues are the
INBOUND queue only — a bug report or an external request arrives
there and a planner imports it as a finding (`gitboard new` with the
evidence as `--spec-file`, no parent) at triage; no workflow state
ever returns to labels or issue comments.

## the planner session

run `next --role planner` and do what it says; the rule it applies
is, in order:

1. **review** — anything in `check` gets a verdict first
   (`review.md`). this is the strongest lever: it unblocks
   implementers and harvests friction evidence.
2. **refine** — while `ready` has slack, take the oldest `plan` item
   one rung down the ladder (`decompose.md`): decompose a container's
   outcome further, or drive a leaf to the ready bar. before a
   `move ID ready`, run the enablement check (`enable.md`) and
   `check ID` — both must pass.
3. **triage** — findings await adoption: `attach` each under the goal
   or container its evidence serves (it enters `plan`), or end it —
   `done ID` when landed work already covers it, `done ID --reason
   not-planned` for a recorded dead end.
4. **intake** — while `plan` has slack, `next` names the top-ranked
   goal with no live work under it; decompose it (`gitboard new
   "outcome" --parent <goal>`). the rank is data on the goal items,
   re-derived by paired comparison when contested (`decompose.md`);
   the outcome prose stays in docs/goals.md.
5. **nothing** — plan and ready are full and check is empty:
   implementation has to catch up. do not open more items; a longer
   backlog is not progress.

a planner session may touch several items, but it respects the same
flow: never step left while a right-hand phase has work for you.

## the implementer session

one item per session, exactly this loop:

1. `next` names the item, rightmost first: land what sits in `land` —
   an accepted PR is the most-finished work there is — then finish
   `do`, before pulling the oldest unblocked `ready` leaf. if it
   answers `none`, stop — do not invent work; say a planner session
   is needed (`next` names the bottleneck). read the item with
   `gitboard show ID` — the spec sidecar is the spec, and the item's
   `verdict`/`pr` fields carry the standing review state.
2. which phase it came from decides this step. a `land` item is
   already judged, and `gitboard land ID` is the whole step: it
   squash-merges the PR its `pr` field names and ends the item, in
   that order. a `do` item with a
   `request changes` verdict is rework: address the quoted gaps on
   that PR and rejoin the loop at step 3. a fresh `ready` item is
   claimed: `move ID do --claim <session>` — the move is the lock, and
   `next --session <session>` is how you hold it: it never hands you
   an item another session claimed.
3. implement EXACTLY what the spec says. its `Change` is the scope,
   its `Non-goals` are walls, its `Acceptance` commands are the
   definition of done — run them and quote their verdict lines in the
   PR description.
4. open the PR READY for review, carrying `Board: <id>` in its body
   and quoting the Acceptance commands you ran, then hand it over WITH
   its number: `gitboard move ID check --pr N`. the move refuses each
   of those in turn — a draft, a body that names no item, one that
   does not show the commands having been run, a head whose CI already
   concluded failure — because each is something a reviewer would
   discover instead of reviewing.
5. stop. the verdict is the planner's job; never merge a PR that has
   not been accepted. the accept arrives as the item moving to `land`
   with `verdict = accept` — landing it is step 2's first case, in
   this lane.

**when the spec under-specifies** — you hit a decision the sidecar
does not settle, a command that does not exist, a contract question —
do not improvise. `gitboard move ID plan` (a return, never refused)
with the gap named in the PR-or-item trail, leave the PR draft or
close it, and stop. a bounce is a good outcome: it is the ready bar
failing loudly instead of a silent wrong guess, and every bounce
becomes enablement evidence (`enable.md`).

**when you find something out of scope** — a real defect, a stale
doc, a gap the slice sits next to but does not own — it goes to the
board, never into the diff: `gitboard new "title" --spec-file F`,
where F is one paragraph of evidence. an unparented item IS a
finding; no trace is required of you, and filing is never refused —
findings hold no phase, so no limit has anything to say. then return
to the slice: do not refine the finding, do not fix it in passing,
do not widen the diff to cover it.

one session takes one item. running SEVERAL implementer sessions at
once is a different move with its own mechanics — a disjoint set, a
checkout per session, a brief that carries the spec — and those are
`parallel.md`.

## hard rules (guardrails)

- ALL work state lives in items on the `board` branch — never in
  GitHub labels, issue comments, notes docs, or TODO comments in the
  product tree. (the `perf` label keeps its own hypothesis backlog
  under the `optimize` skill; a board item may link to a perf issue,
  never duplicate it.)
- board state moves and reads through `gitboard` only. when the tool
  LACKS a verb the session needs, work around it ONCE by editing the
  item file and committing — the file format is the contract — and
  file the missing verb as a finding.
- the ready bar is never lowered to make an item pullable, and the
  WIP limits are never widened to make a move succeed. `--force`
  exists for repair, not for flow.
- a container is never pulled: only workable leaves hold phases, and
  the tool de-phases an item the moment a child attaches under it.
- implementers implement what the spec says; planners decide what
  specs say. a scope question discovered mid-implementation goes back
  to the board, not into the diff.
- every phased item traces to a ranked goal — checked structurally by
  `gitboard check` for the item at hand and by `gitboard status` for
  the board, not by convention. work that traces to no goal is
  ended as not planned, however good the idea — re-rank the goals
  (rank fields + a docs/goals.md PR) when the goals themselves are
  wrong.
- repo conventions are not relaxed for implementers: `--make ci` and
  the contract freezes in AGENTS.md bind every PR regardless of which
  model wrote it. when a convention keeps tripping implementers, the
  fix is enablement (`enable.md`), never an exception.
