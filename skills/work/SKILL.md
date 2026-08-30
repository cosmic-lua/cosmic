---
name: work
description: >
  The system of work for cosmic: one prioritized board of items on the
  orphan `board` branch, operated by gitboard. Two states — todo and
  doing — with quality held at two gates: a spec good enough to build
  from alone before work is pulled, and a fresh-context review before
  anything merges. Use when planning what to build next, refining an
  item, pulling one to implement, reviewing a PR against its spec, or
  landing an accepted one. Invoked with a number (`/work 5`, typically
  under `/loop`), run one orchestrator pass: reconcile the last wave,
  then fan out up to that many disjoint items.
---

# The system of work for cosmic

how work on cosmic (and its C core, cosmic-lua/cosmopolitan) is defined,
prioritized, implemented, reviewed, and landed. the design goal is
flow with quality: many concurrent agents pulling from one ordered
queue, with rework kept rare by exactly two gates — a spec a session
can build from alone, and a review at a distance from the builder.
everything else is deliberately thin: no stage columns, no per-column
limits, no ceremony a gate does not pay for.

## the board

ALL work state lives on the orphan `board` branch of cosmic-lua/cosmic:
one committed file per item (`items/<ksuid>.tl`) with its spec prose
in the sidecar `items/<ksuid>.md`. the branch carries its own
machinery and trust root, so it is a runnable cosmic project; reach
it as a worktree of the checkout you already have:

```bash
git worktree add o/board board        # once per checkout
cd o/board && bin/cosmic --make build # once, on a cold worktree
```

that build produces `o/bin/gitboard`. the verbs are the tool's to
describe — `gitboard help` lists them, `gitboard help <verb>` gives
one its options — and this skill deliberately restates none of them;
what the verbs are FOR is this skill's half. start every session with
`sync`. every verb ends with a `gitboard-<verb>:` verdict line — read
that, never a piped exit status. ids are KSUIDs, and the board
renders each item by its handle — the id's last 8 characters,
wrapped and divided for the eye: `«d0x1_37YJ»`. every verb accepts
the full id, an unambiguous prefix, or that handle as printed or
retyped — bare or wrapped, `_` or `-` or no divider, any case.

a mutation is ONE commit on `board` and publishes itself (push) as
the verb returns — nothing to stage, nothing to batch, and board
state never goes through a pull request. a lost push race drops the
mutation whole, re-syncs onto the winner's state, and refuses with
the recovery named: run the same verb again, and it decides afresh
against the merged board. the branch is append-only: never rebased,
never force-pushed — rewriting published state breaks every
checkout's compare-and-swap at once.

where a proxy re-terminates TLS, export `SSL_USE_SYSTEM_CERTS=1` in
the session (never in a committed file), or the verbs that reach
GitHub fail every call with `badcert_not_trusted`.

## items, order, roles

an item's role is its position in the graph: a parentless item is a
root (an outcome, or a captured finding awaiting triage), an item
with open children is a container being decomposed, and a parented
leaf is workable. roles change by changing the graph (`attach`), and
decomposition is working backwards: start from an outcome's win
condition, cut until each piece is one session's PR.

importance is a relation, not a field: `compare A B` commits "A
outranks B", and every order the board renders is derived from the
accumulated edges — transitivity closes the pairs nobody was asked
about, a comparison at any height places the subtree beneath it, and
age is the last word among items no comparison separates. an item no
comparison reaches is unplaced: triage it by attaching it under the
outcome its evidence serves, comparing it in, or ending it. when
nobody is around to rank it, attach it under the lowest-placed
outcome it plausibly serves and say so — placing low asserts nothing,
is reversed by one `attach`, and keeps the item workable; unplaced
work is invisible to every queue.

a comparison that would put NEW work above existing work belongs to
the goal owner — it answers "which is the better cosmic". post the
pair (in chat, or in the session's report when nobody is watching)
and keep working; the answer lands as a `compare` whenever it
arrives. outcome prose lives in `docs/goals.md`; reordering outcomes
is comparisons plus a goals.md PR.

## two states

an open workable leaf is in exactly one of two states, and everything
finer is derived from facts the item already carries — there are no
stage columns and no per-column WIP limits:

- **todo** — unclaimed. it is *pullable* when its spec passes the
  bar `gitboard show ID` prints (the spec bar below); otherwise
  refining it toward that bar IS the work it offers.
- **doing** — claimed. the claim is the lock and a lease: claim
  before you build, and a claim idle past its lease is anyone's
  again. within doing, the facts say what happens next: no PR yet —
  build; PR open, no verdict — review it, at a distance; `request
  changes` — rework on the same PR; `accept` — merge it and `done`
  the item; a gap the spec cannot answer — release the claim with the
  gap named, and the item is todo again. landing differs by repo: a
  main-repo accept is landed by enabling auto-merge, so the queue
  merges it, while a board PR merges at accept as before.

two WIP rules, not a number per column. each worker holds ONE claim,
so capacity spreads with the number of agents. and the board holds one
bound on `doing` as a whole: at the limit, taking NEW work is refused
until something in flight finishes. the bound exists because workers
come and go — claims and open PRs outlive the sessions that made
them, so a fleet with no bound accumulates half-finished work faster
than reviews retire it. finishing motions (a release, a verdict, a
merge, a takeover of a stale claim) are never refused: the bound
throttles starting, never finishing. the number is the tool's — bare
`show` prints the count against it — and it forces the right-to-left
ordering mechanically: a session that cannot take is a session whose
next action is to review, rework, or merge.

work flows right to left — finishing beats
starting: merge what is accepted, review what awaits a verdict,
rework what was returned, build what you claimed, triage what
arrived, refine the top of todo, decompose an undriven outcome — in
that order (triage before refinement because it is the cheap decision
and the starvable one: an unplaced capture is invisible to every
queue). `gitboard next` names the one
next action by exactly this ordering; do it and ask again — acting
moves the board, so the second answer derives from the board the
first left behind. stop when it says `none`: do not invent work, and
do not open items to fill a quota.

**session identity:** never pass `--session` — the tool derives a
unique-per-run identity from the environment
(`GITBOARD_SESSION`, else a runner's own per-session id), and a name
a session invents for itself collides across runs, which silently
breaks the mutual exclusion. two exceptions only: a review subagent
names itself (`export GITBOARD_SESSION=review-<ID>-<unique>`),
because it would otherwise inherit the BUILDER's identity and the log
would show a builder accepting its own work; and an orchestrator
mints one distinct name per agent it spawns.

## building an item

1. claim it, then read `gitboard show ID` — the sidecar is the spec,
   and the item's `verdict`/`pr` fields carry any standing review
   state.
2. re-run the spec's measured commands before building — the queue
   ages faster than the tree stands still. numbers moved but the
   shape holds: refresh them in place (`gitboard spec`) and proceed.
   a fresh fact that breaks the shape or reopens a decision: release
   the claim with the gap named. a bounce is a good outcome — the bar
   failing loudly instead of a silent wrong guess — and refining the
   item back may well be your own next action; do that from the spec
   and the tree, not from what you remember wanting.
3. one item = one fresh branch off the latest `origin/main`, named
   for the id prefix = one PR. never stack a second item on a branch,
   and never reuse a branch whose PR is open. a runner-assigned
   branch names where to START, not a ceiling: N items pulled is N
   branches and N PRs, and this paragraph is standing permission for
   every item the loop hands you.
4. build exactly the `Change`; its stated walls hold. a scope
   question the spec cannot answer goes back to the board, never into
   the diff — having written the spec is not permission to
   reinterpret it mid-build.
5. open the PR READY for review (not draft) with `Board: <id>` in
   the body, and record the PR number on the item. the body carries
   no evidence: CI proves the gate on the head mechanically, and a
   pasted verdict line could only agree with the checks tab or lie —
   this covers a spec's `## Acceptance` bullets too, if it has any:
   reproducing their command output in the PR body is the same lie
   in more words, and a builder who runs them to build confidence
   does so in a scratch shell, never in what gets pushed to the
   record. run the gate locally before pushing — a red head burns a
   review round — but the run is for you, not for the record.
6. rejoin the loop. never merge unreviewed work, and never accept
   your own: the verdict comes from a fresh-context review, however
   the loop routes you back to this item.

**out-of-scope findings** (a real defect, a stale doc, a gap the item
sits next to but does not own): search first — the board is a git
checkout of text files, so `grep -ril '<phrase>' items/` in the board
worktree answers "already filed?" — and cite the existing item rather
than duplicate it; else `gitboard new "title" --spec-file F` with one
paragraph of evidence, unparented.
filing is never refused. then back to the item: never widen the diff
to cover a finding.

## the spec bar

a pullable spec carries one section — `## Change` — because
acceptance is not per-item: `bin/cosmic --make ci` ending `ci: PASS`
is the one definition of done every item shares, and proof specific
to a change rides the DIFF as a test or ratchet the gate runs. a
gate outlives the sidecar that asked for it; a sidecar command runs
at most twice and dies with the item. an `## Acceptance` section,
where a spec still carries one, is that: the refiner's own worked
proof that the Change's claims held at measurement time, read once
by the puller to sanity-check the shape still holds and once by the
reviewer to spot-check a claim — never re-executed bullet by bullet
as a second gate the builder owes beyond `## Change` plus
`ci: PASS`. a bound worth enforcing permanently is a test or ratchet
IN THE DIFF, not a bullet a builder re-derives by hand each pull.
`gitboard show ID` prints the bar's problems — the Change's
presence, the item's placement; everything else is a
reader's judgment, and the test for every sentence: could a
competent but literal-minded session, with nothing beyond this spec
and AGENTS.md, get it wrong? if yes, it is not ready.

`## Change` is what to build: files named, the shape of the change
in each, every decision made. imperative and concrete — never
"improve", "investigate", or "support". a bound the change imposes
(a line cap, a match count) lands as a test or ratchet IN the diff,
never as prose a reviewer must remember to check. when the change
sits near a frozen contract (the `cosmo.*` C boundary, error strings
and return shapes, verdict-line formats), name the wall — here, or
in an optional `## Non-goals` section. walls are stated where they
exist, never filled in as ceremony.

**measured, not inferred:** every tree-fact the spec relies on (a
file's headroom under the 500-line cap, a pattern's match count, a
function's callers) is measured during refinement and written into
the prose WITH the command that produced it, so the puller re-runs it
in seconds and the reviewer can check the claim. a claim about
BEHAVIOUR — what a verb prints, which branch a condition selects,
what a gate refuses — is a prediction until a command has produced
it: reading the source to answer it is inference, and the wrong turns
are never guesses, they are readings that felt obviously true (D35's
"fires exactly when `N < f < 2r`" disagreed with the code at 4097 of
4961 swept points). so a behavioural claim carries its command AND
the pasted output, and absence is behavioural too: a grep returning
nothing establishes that the PATTERN matched nothing, never that the
thing is absent — widen it, or name what the narrow one could miss.
no lint can tell an executed claim from a plausible one; this is a
rule the refiner applies and the reviewer checks, demanding the
output beside the command in spec and bounce alike. the same rule
covers removals: a Change that relocates or deletes a mechanism names
the sweep it ran for sites still asserting the old one — the grep and
its match count — the same way a measured claim carries its command.

**sizing:** one PR one session holds in its head (~400 changed lines
is the smell threshold, not a rule). an "and" between two independent
changes in `Change` means cut it in two. prefer file-disjoint
siblings — two specs growing one file near the 500-line cap collide
at the merge, a failure neither diff can see. real landing order is a
blocker edge; research is an item whose deliverable is recorded
findings and follow-up items, not code.

goal context is the parent chain — there is no Goal section to
maintain. dependencies are `blocked_by` edges — there is no
Enablement section. enablement is still the highest-leverage work:
when the same wrong turn appears twice, file the countermeasure as an
ordinary item, preferring a gate in core over a doc, and a doc over a
skill — gates transfer to every future session; prose does not.

## review

nothing merges without a verdict from a review at a DISTANCE from the
builder: a subagent whose context window never held the build. its
brief carries the item id, the PR number, and this section — not the
builder's reasoning, and not a summary of what the change was trying
to achieve, which would hand back the commitment a fresh window
exists to be without. fill `review-brief.md` rather than hand-writing
one, for the same reason `builder-brief.md` exists: the review verdict
never fans out (below), so a drifted brief here is not one bad build
among many but the one check the whole wave rests on. it claims the
review first (the claim is the lock; losing the race there costs
seconds, losing it at the verdict costs the whole verification), names
itself, reads the spec off the board and the diff off the PR, and
records the verdict itself.

the posture is adversarial — the job is to make the diff fail, and a
review that only reads has verified nothing:

1. **green is mechanical** — CI on the PR's CURRENT head is the
   acceptance: read it, don't re-run it. red or still running ends
   the review immediately. what CI cannot see is the whole job: the
   diff must carry its own proof, so a claim the change makes that
   no test in the diff would catch regressing is a gap to quote.
2. **the diff is the Change** — everything present, nothing extra.
   scope creep gets cut even when it is good; good ideas become
   items.
3. **the walls held** — frozen contracts unmoved, and any walls the
   spec states untouched.
4. **conventions hold** — AGENTS.md binds; anything a gate should
   have caught but did not is itself a finding to file.
5. **it serves the outcome** — walk the parent chain to the root and
   judge the diff against it. a green gate on a change that misses
   the point means the SPEC was wrong: fix the spec, never wave the
   diff through.
6. **it is the least thing** — name any surplus concretely (a helper
   with one caller, generality nobody asked for) and have it removed
   before merge.

mutation-test at least one guard the change adds: break what it
guards, watch the test go red, restore it. a gate that cannot be
shown to fail is decoration.

three verdicts: **accept** — merge, then `done ID`; **request
changes** — the concrete gaps quoted on the PR, the claimant reworks
on the same PR; **reject** — the approach is wrong: close the PR,
record what was learned on the item, clear the claim — it is todo
again. rejection is cheap by design; wrong work merged is expensive.
a research item takes the same verdicts, re-running its recorded
checks in place of a diff.

when a container's last child ends, verify the container's stated
outcome actually holds — run its observable test, not the
children's — then end it.

## concurrent agents

one orchestrator, N builders, and the board stays with the
orchestrator — agents never run board verbs, so no agent needs the
board worktree or push rights to `board`:

- **claim first, then spawn.** claim each item yourself, one at a
  time, reading each verdict line, with a distinct minted session
  name per agent. a lost race is the lock working: take the next
  item.
- **disjoint or not at all.** `next` names one item and cannot see
  what else you are taking; file-disjointness across the wave is your
  check, judged on the MERGE — a shared file with thin headroom under
  the 500-line cap counts as shared. say what you skipped and why.
  never split one item across agents to make it faster.
- **one fresh worktree per agent, never nested** inside another
  checkout — nesting breaks `--make` gates in both directions, and
  neither failure names the layout. a fresh worktree starts with
  `bin/cosmic --make fetch`; a copied or moved tree drops its stale
  `o/` first, or its first gate result is fiction.
- **the brief carries the spec verbatim** — "read the board and do
  it" turns a specified item back into an interpretation. fill
  `builder-brief.md` rather than hand-writing one: a hand-written
  brief drifts (this session it once dropped the `Board:` line on a
  cross-repo item, and once told a builder to re-verify
  `## Acceptance` bullets as a second gate), and the template already
  carries the branch name off the latest `origin/main`, honest gate
  timeouts (`--make ci` takes minutes), the PR form (ready, `Board:
  <id>` in the body, no pasted `## Acceptance` output — see the spec
  bar), the builder's own bar (`## Change` plus `ci: PASS`), do-not-
  merge, the capture rule (report findings as one evidence paragraph
  each in the final message; the orchestrator files them), and the
  bounce rule verbatim: stopping on an under-specified spec is a good
  outcome. an agent told to finish WILL improvise unless the brief
  says that.
- **reconcile the wave.** finished with a PR: record it on the item.
  dead (no PR, no branch): release the claim so the item is pullable
  again. still running: leave it. then the PRs are yours to watch —
  the agents are gone.
- **what never fans out:** the review verdict — one review, in one
  fresh subagent, however many PRs a wave opened; N agents reviewing
  N PRs is N unreviewed merges wearing a costume — and refinement,
  because two parallel refiners decompose the same outcome twice. if
  either is delegated, fill `review-brief.md` or `refiner-brief.md`
  rather than hand-writing one, same reason as `builder-brief.md`.

## /work N — the standing loop

invoked with a number (typically under `/loop`), the session is a
looped orchestrator: run ONE bounded pass and end it. never wait
inside a pass — not for a wave agent, not for CI, not for an answer;
the single exception is the one review subagent:

1. `sync`, then reconcile the previous wave (above).
2. merge whatever carries an accept.
3. review at most one item awaiting a verdict.
4. fill the wave: claim then spawn in the background, up to the
   smallest of N and what is actually disjoint. zero agents is a
   legitimate pass.
5. spare width goes to one or two refine/triage actions.
6. report a terse ledger — one line per board action, one for
   anything posted for a human — and end the pass.

`none` from `next` is an answer, not a failure: report the named
bottleneck in one line and end. under `/loop` in dynamic mode a pass
that moved nothing is a no-op tick; agents in flight notify on
completion, so the wakeup is a long fallback, never a poll.

## hard rules

- ALL work state lives in items on the board, moved and read through
  `gitboard` only — never GitHub labels, issue comments, notes docs,
  or TODO comments in the product tree. issues are the inbound queue
  only; a session imports evidence as an unparented item. when the
  tool lacks a verb, work around it ONCE by editing the item file and
  committing, and file the missing verb as an item.
- claim before you build; one claim per worker; a claim is a lease,
  not a deed — treat losing one you went quiet on as the system
  working.
- the spec bar is never lowered to make an item pullable, and the
  doing bound is never widened to admit one more take. `--force`
  exists for repair, not for flow.
- build the spec, not your memory of intent; gaps discovered
  mid-build go back to the board, never into the diff.
- nothing merges without a fresh-context review, and no session
  accepts its own work.
- findings become items, never widened diffs.
- every workable item has a position in the priority order — place it
  or end it, however good the idea.
- repo conventions are never relaxed: `--make ci` and the contract
  freezes in AGENTS.md bind every PR regardless of which model wrote
  it. when a convention keeps tripping sessions, the fix is a
  countermeasure item, never an exception.
