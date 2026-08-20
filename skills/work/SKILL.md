---
name: work
description: >
  The system of work for cosmic: work backwards from the outcomes
  that matter most, decompose them into workable items that flow
  kanban-style across a WIP-limited board, and refine each item until
  it can be implemented from its spec alone. One worker asks the board
  what matters most, does it, and asks again. The board lives on the
  orphan `board` branch as committed files, operated by gitboard. Use
  when planning what to build next, refining or decomposing work,
  pulling the next item to implement, reviewing a PR against its
  spec, or landing an accepted one.
---

# The system of work for cosmic

this skill is the operating manual for how work on cosmic (and its C
core, whilp/cosmopolitan) is defined, refined, implemented, reviewed,
and landed.

there is ONE worker. it wakes, asks the board what matters most, does
that, and asks again — decomposing an ambitious outcome, driving a
slice to the ready bar, implementing one, judging what comes back, and
merging what it accepts, as the board demands each in turn. the work
is not split by kind of mind: a session capable of writing a spec is
capable of implementing one, and the ordering decides which it does
now.

what IS still split is the moment of judgment. a review is worth the
distance between the builder and the reviewer, so `next --session
NAME` never hands a session a verdict on work that session built —
the claim recorded when it pulled the item survives into `check` and
says who did it. that distance is now a property of the board rather
than of which model is running, which is why it survives one worker
doing everything.

the worker's defining duty is not writing specs; it is making the NEXT
session succeed — often itself, with none of today's context. when a
piece of work is too ambiguous to implement from its spec alone, the
answer is never to implement it anyway from memory: refine the spec
further, or change the system (core first, then docs, then skills)
until the ambiguity is gone. see `enable.md`.

the chapters:

- `SKILL.md` — this file: the board, the roles, the session loop, the
  rules.
- `decompose.md` — working backwards from outcomes; the refinement
  ladder; the ready bar in full, with a worked example.
- `enable.md` — making the next session succeed: core > docs > skills.
- `review.md` — the review verdicts, the friction feedback loop, and
  the flow review that tunes WIP limits.
- `parallel.md` — running several sessions at once: picking a
  disjoint set, isolation, and the brief an agent needs.

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
| open children | a **container** being decomposed |
| parentless leaf | a **root**: an outcome, or evidence awaiting triage |
| parented leaf | **workable** — the only thing that holds a phase |

there is no goal tier and no `rank` field: importance is a RELATION
between items, not a number an item asserts about itself. `gitboard
compare A B` commits one judgment — A outranks B — and every order the
board renders is DERIVED from the accumulated comparisons.
transitivity closes the pairs nobody was asked about, a comparison at
any height places everything beneath it, and age is the last word
among items no comparison separates. what separates the two kinds of
root is therefore placement, not a marker: a root somebody has
compared is an outcome to decompose, and one no comparison reaches is
what the triage queue holds.

roles change by changing the graph: `attach` is both decomposition (a
workable item that gains a child is de-phased into a container in the
same mutation) and triage (an adopted capture becomes a plan-phase
leaf). PLACEMENT is the checked property: every phased item must have
a position in the priority order, itself or through an ancestor, and
`check` says so when THAT item does not. the question is ordinal —
where does this sit against everything else — rather than
genealogical, so an item nothing has been compared against has no
answer to it. the board's own health (every item's placement and
chain, any leaf left off the board, and any cycle the comparisons
hold) reads from `status`: one item's problem is everyone's to see and
nobody's reason to be refused a promotion.

decomposition is reversible without ceremony. an item that gains a
child is de-phased in the same commit; when its LAST open child ends,
the item returns to `plan` in the closing commit, which is where the
session verifies the outcome its children were supposed to deliver and
ends it.

phases, left to right (only workable leaves carry one). a phase is
named for the action performed in it; `ready` is the one noun,
because nobody acts there — it is a buffer:

| phase | meaning |
|-------|---------|
| `plan` | placed, still ambiguous — refined until it meets the ready bar |
| `ready` | meets the ready bar (`decompose.md`); nobody's until a session pulls it |
| `do` | claimed work and rework — the claimant's, until a PR opens or a bounce |
| `check` | PR open; awaiting a verdict from a session that did not build it |
| `land` | accepted; awaiting the merge |

every phase is WIP-limited. the numbers are the tool's — `status`
prints each phase against its own — and retuning one is a reviewed
change to the machinery, not a reading of this table: `review.md`'s
flow review is the method that earns one.

a full phase still admits the motion that cannot sensibly wait: a
return is never refused, because leftward motion is the system
correcting itself, and an accept is a decision already made rather
than new inventory. everything else queues until the phase drains,
and which arrivals qualify is the tool's rule to state rather than
this table's — an over-limit phase blocks further pull and nothing
else. roots and containers are never phased, so no exemption
vocabulary exists for them — they occupy no slot to exempt.

**work flows right to left.** finishing beats starting: merging before
reviewing, reviewing before finishing, finishing before pulling,
pulling before refining, and refining before intake.

GitHub keeps two jobs. pull requests carry fixes: the diff, its CI,
and its review conversation, exactly as before. issues are the
INBOUND queue only — a bug report or an external request arrives
there and a session imports it as an unparented item (`gitboard new`
with the evidence as `--spec-file`, no parent) at triage; no workflow
state ever returns to labels or issue comments.

## the session loop

run `gitboard next --session <name>` and do what it says. it names the
one next action and the rule that chose it; the ordering is the
tool's, and what it encodes is this skill's: work flows right to left,
so finishing beats starting. an accepted PR is the most-finished work
there is, a verdict unblocks whoever is waiting on it, and an inbox
nobody empties is a channel that only takes — which is why draining an
over-bound triage queue jumps ahead of refinement, and why taking in
new work comes last.

**always pass `--session <name>`.** it is what makes the loop safe in
company and honest alone: it withholds work another session claimed,
and withholds a verdict on what THIS session built. without it you
will be handed your own PR to review, and reviewing your own work is
the one thing the ordering cannot make good.

**doing several actions is running the loop again.** acting moves the
board, so ask again rather than planning a batch: the second answer is
derived from the board the first one left behind. stop when `next`
says `none` — do not invent work, and do not open items to fill a
quota. a longer backlog is not progress, and `none` names the
bottleneck so you can say what it was.

what each kind of action is:

- **finish (from `land`)** — the item is already judged. `gitboard
  land ID` is the whole step: it squash-merges the PR its `pr` field
  names and ends the item, in that order.
- **review** — an item in `check` gets a verdict (`review.md`). read
  the acceptance evidence in the PR description before the diff; it is
  what the builder owed you.
- **finish (from `do`)** — claimed work, or rework a `request changes`
  verdict sent back. address the quoted gaps on that PR and hand it
  over again.
- **pull** — a fresh `ready` item. claim it first: `move ID do --claim
  <session>` — the move is the lock, and the lock is a lease: a claim
  whose session stops committing to the board reads as stale after a
  few hours, and `next` offers the item to whoever asks. then the
  slice loop below.
- **unblock** — every `ready` item waits on an open blocker, so
  nothing pulls however deep the queue is. `next` names the chain's
  deepest open item; resolving it is whatever its state calls for —
  finish it, take over its stale claim, refine it — and when the
  reason recorded on the edge no longer binds (the spec grew its own
  workaround), drop the edge with `gitboard unblock`.
- **refine** — take a `plan` item one rung down the ladder
  (`decompose.md`): decompose a container's outcome further, or drive
  a leaf to the ready bar. before a `move ID ready`, run the
  enablement check (`enable.md`) and `check ID` — both must pass.
- **triage** — unplaced captures await a decision: `attach` each under
  the outcome or container its evidence serves (it enters `plan`),
  `compare` it against something to place it as an outcome in its own
  right, or end it — `done ID` when landed work already covers it,
  `done ID --reason not-planned` for a recorded dead end.
- **intake** — decompose the highest-placed root that no live work
  drives (`gitboard new "outcome" --parent <root>`). its position is
  derived from the comparisons on the board, re-derived by asking one
  more pair when contested (`decompose.md`); the outcome prose stays
  in docs/goals.md, which nothing derives from — it is context to read
  when interpreting and adjusting the tree.
- **none** — implementation has to catch up, or everything left is
  yours to review and somebody else must. before stopping, run
  `gitboard stall`: it files (or refreshes) the one standing capture
  naming the bottleneck, so the stall is a timestamped board object
  the next triage sees rather than a vanished session log — and it
  refuses when the board in fact has work. then stop.

**placing a new outcome is not yours to decide alone.** a comparison
answers "which of these is the better cosmic", and that judgment
belongs to the goal owner (`decompose.md`). attaching a capture under
something already placed needs no such question — it inherits a
position. but when triage or intake would require ordering a NEW
outcome against the existing ones, post the pair and stop rather than
inventing an answer; an unattended session has nobody to ask, and a
fabricated comparison is worse than an unplaced item.

## implementing a slice

when the action is **pull**, or **finish** from `do`, the item is a
slice and this is the loop:

1. read it with `gitboard show ID` — the spec sidecar is the spec, and
   the item's `verdict`/`pr` fields carry the standing review state.
2. implement EXACTLY what the spec says. its `Change` is the scope,
   its `Non-goals` are walls, its `Acceptance` commands are the
   definition of done — run them and quote their verdict lines in the
   PR description.
3. open the PR READY for review, carrying `Board: <id>` in its body
   and the acceptance run in its description — that evidence is what
   you OWE the reviewer, who reads it before reading the diff and
   cannot reconstruct it from the branch. hand it over WITH its
   number: `gitboard move ID check --pr N`. the move refuses a
   request not yet worth a reviewer's time; read the refusal and fix
   what it names, because anything it catches is something a reviewer
   would otherwise discover instead of reviewing.
4. stop implementing and rejoin the loop. never merge a PR that has
   not been accepted, and never accept your own: the item now carries
   your claim, so `next --session <name>` will route it elsewhere and
   hand you something else.

**when the spec under-specifies** — you hit a decision the sidecar
does not settle, a command that does not exist, a contract question —
do not improvise. `gitboard move ID plan` (a return, never refused)
with the gap named in the PR-or-item trail, leave the PR draft or
close it, and rejoin the loop. a bounce is a good outcome: it is the
ready bar failing loudly instead of a silent wrong guess, and every
bounce becomes enablement evidence (`enable.md`). refining it back to
the bar may well be your own next action — do that as a refine, from
the spec and the tree, not from what you remember wanting.

**when you find something out of scope** — a real defect, a stale
doc, a gap the slice sits next to but does not own — it goes to the
board, never into the diff: `gitboard new "title" --spec-file F`,
where F is one paragraph of evidence. an unparented item IS a
capture; no trace is required of you, and filing is never refused —
an unparented item holds no phase, so no limit has anything to say.
then return to the slice: do not refine it, do not fix it in passing,
do not widen the diff to cover it.

one slice at a time. running SEVERAL sessions at once is a different
move with its own mechanics — a disjoint set, a checkout per session,
a brief that carries the spec — and those are `parallel.md`.

## hard rules (guardrails)

- ALL work state lives in items on the `board` branch — never in
  GitHub labels, issue comments, notes docs, or TODO comments in the
  product tree. (the `perf` label keeps its own hypothesis backlog
  under the `optimize` skill; a board item may link to a perf issue,
  never duplicate it.)
- board state moves and reads through `gitboard` only. when the tool
  LACKS a verb the session needs, work around it ONCE by editing the
  item file and committing — the file format is the contract — and
  file the missing verb as an unparented item.
- the ready bar is never lowered to make an item pullable, and the
  WIP limits are never widened to make a move succeed. `--force`
  exists for repair, not for flow.
- a container is never pulled: only workable leaves hold phases, and
  the tool de-phases an item the moment a child attaches under it.
- implementation follows the spec; the spec is decided in `plan`. a
  scope question discovered mid-implementation goes back to the board,
  not into the diff — being the same worker who wrote the spec is not
  permission to reinterpret it mid-slice.
- no session accepts its own work. `--session NAME` enforces it in
  `next`; honour it if you reach for `verdict` directly.
- every phased item has a position in the priority order — checked
  structurally by `gitboard check` for the item at hand and by
  `gitboard status` for the board, not by convention. an item nothing
  has been compared against, at any height, is not workable: place it
  or end it as not planned, however good the idea. when the ORDER
  itself is wrong, change it with `compare`/`uncompare` (plus a
  docs/goals.md PR when the outcome prose moves), never by lowering
  the bar for one item.
- repo conventions are never relaxed: `--make ci` and the contract
  freezes in AGENTS.md bind every PR regardless of which model wrote
  it. when a convention keeps tripping sessions, the fix is enablement
  (`enable.md`), never an exception.
