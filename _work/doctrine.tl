--- The system of work, served by the tool: `gitboard help <topic>`
--- prints one of these pages, and the overview help lists them. The
--- pages carry DOCTRINE — what the verbs are for, the ordering, the
--- bars, and the judgment around them — while `help <verb>` stays the
--- mechanics. The `work` skill on main is only the bootstrap and
--- delegates everything else here, so the one source for how to
--- operate the board is the binary a session has already built, and a
--- doctrine change ships to every session with the next sync.
---
--- Pure data: no git, no filesystem. `_work/doctrine_test.tl` pins
--- that every listed topic renders and that no topic shadows a verb.

--- One page. `body` is the prose; `title` is the one-line summary the
--- topic list prints beside the name.
local record Page
  name: string
  title: string
  body: string
end

local PAGES < const >: {Page} = {

  {name = "system", title = "the board: states, order, exits, rules",
    body = [[
One prioritized queue of items on the `board` branch, operated only
through gitboard verbs. An item's ROLE is its position in the graph: a
parentless item is a root (an outcome, or a captured finding awaiting
triage), an item with open children is a container being decomposed,
and a parented leaf is workable. Importance is a RELATION, not a
field: `compare A B` commits "A outranks B", every rendered order
derives from the accumulated edges, and age is the last word among
items no comparison separates. An item no edge reaches (at any
height) is unplaced — invisible to every queue and refused by `take`
— so triage it: attach it under the outcome its evidence serves,
compare it in, or end it. When nobody is around to rank it, attach it
under the lowest-placed outcome it plausibly serves and say so.

A comparison that would put NEW work above existing work belongs to
the goal owner — it answers "which is the better cosmic". Post the
pair (in chat, or in the session's report when nobody is watching)
and keep working; the answer lands as a `compare` whenever it
arrives. Outcome prose lives in docs/goals.md on main; reordering
outcomes is comparisons plus a goals.md PR.

An open workable leaf is in exactly one of two states; everything
finer derives from facts the item already carries:

  todo   unclaimed. Pullable when its spec passes the bar (`help
         bar`); otherwise refining it toward the bar IS the work.
  doing  claimed. The claim is the lock and a lease: claim before you
         build, and a claim idle past its lease is anyone's again.
         Within doing the facts say what happens next: no PR — build;
         PR, no verdict — review at a distance; `request changes` —
         rework on the same PR; `accept` — merge, then `done`.

Two exits from doing, split by which side stopped. A gap in the ITEM
— a spec that cannot answer, a reopened decision, a falsified
premise — files the question as its own item, blocks this one on it,
then releases the claim: the item waits on the answer, not the
queue, and the question's `done` unblocks it by itself (`help
block`). A bare `drop` is the WORKER-side release — a dead session,
a spent budget — and asserts the item is fine to re-offer as-is
(`help drop`).

Two WIP rules: each worker holds ONE claim, and one bound covers
`doing` as a whole — at the limit, taking NEW work is refused until
something in flight finishes; finishing motions are never refused.
Work flows right to left — finishing beats starting: merge what is
accepted, review what awaits a verdict, rework what was returned,
build what you claimed, triage what arrived, refine the top of todo,
decompose an undriven outcome — in that order. `next` names the one
next action by exactly this ordering; do it and ask again — acting
moves the board, so the second answer derives from the board the
first left behind. Stop when it says `none`: do not invent work.

Session identity: never pass --session — the tool derives a
unique-per-run identity from the environment, and an invented name
collides across runs, silently breaking the mutual exclusion. Two
exceptions: a review subagent names itself (review-<ID>-<unique>),
so the log never shows a builder accepting its own work, and an
orchestrator mints one distinct name per agent it spawns.

Hard rules:
- ALL work state lives in items here, moved and read through
  gitboard only — never GitHub labels, issue comments, notes docs,
  or TODO comments in a product tree. Issues are the inbound queue
  only. When the tool lacks a verb, work around it ONCE by editing
  the item file and committing, and file the missing verb as an
  item.
- claim before you build; one claim per worker; losing a claim you
  went quiet on is the system working.
- the spec bar is never lowered to make an item pullable, and the
  doing bound never widened to admit one more take. --force exists
  for repair, not for flow.
- build the spec, not your memory of intent; gaps discovered
  mid-build go back to the board (block-first), never into the diff.
- nothing merges without a fresh-context review, and no session
  accepts its own work.
- findings become items, never widened diffs.
- every workable item has a position in the priority order — place
  it or end it, however good the idea.
- repo conventions are never relaxed: the repo's gate and its
  AGENTS.md bind every PR. When a convention keeps tripping
  sessions, the fix is a countermeasure item, never an exception.
]]},

  {name = "bar", title = "the spec bar: what makes an item pullable",
    body = [[
A pullable spec carries one section — `## Change` — because
acceptance is not per-item: the repo's own gate passing (for cosmic,
`bin/cosmic --make ci` ending `ci: PASS`) is the one definition of
done every item shares, and proof specific to a change rides the
DIFF as a test or ratchet the gate runs. A gate outlives the sidecar
that asked for it; a sidecar command runs at most twice and dies
with the item. An `## Acceptance` section, where a spec still
carries one, is the refiner's own worked proof that the Change's
claims held at measurement time — read once by the puller to
sanity-check the shape still holds and once by the reviewer to
spot-check a claim — never re-executed bullet by bullet as a second
gate. A bound worth enforcing permanently is a test or ratchet IN
THE DIFF, not a bullet a builder re-derives by hand.

`## Change` is what to build: files named, the shape of the change
in each, every decision made. Imperative and concrete — never
"improve", "investigate", or "support". When the change sits near a
frozen contract (a C boundary, error strings and return shapes,
verdict-line formats), name the wall — there, or in an optional
`## Non-goals` section. Walls are stated where they exist, never
filled in as ceremony. The test for every sentence: could a
competent but literal-minded session, with nothing beyond this spec
and the repo's AGENTS.md, get it wrong? If yes, it is not ready.

Measured, not inferred: every tree-fact the spec relies on (a
file's headroom under a line cap, a pattern's match count, a
function's callers) is measured during refinement and written into
the prose WITH the command that produced it, so the puller re-runs
it in seconds and the reviewer can check the claim. A claim about
BEHAVIOUR — what a verb prints, which branch a condition selects,
what a gate refuses — is a prediction until a command has produced
it: reading the source is inference, and the wrong turns are never
guesses, they are readings that felt obviously true. So a
behavioural claim carries its command AND the pasted output.
Absence is behavioural too: a grep returning nothing establishes
that the PATTERN matched nothing, never that the thing is absent —
widen it, or name what the narrow one could miss. The same rule
covers removals: a Change that relocates or deletes a mechanism
names the sweep it ran for sites still asserting the old one.

Sizing: one PR one session holds in its head (~400 changed lines is
the smell threshold, not a rule). An "and" between two independent
changes in `Change` means cut it in two. Prefer file-disjoint
siblings — two specs growing one file near a line cap collide at
the merge, a failure neither diff can see. Real landing order is a
`blocked_by` edge; research is an item whose deliverable is
recorded findings and follow-up items, not code.

Goal context is the parent chain — there is no Goal section.
Dependencies are `blocked_by` edges — there is no Enablement
section. Enablement is still the highest-leverage work: when the
same wrong turn appears twice, file the countermeasure as an
ordinary item, preferring a gate in core over a doc, and a doc over
a skill — gates transfer to every future session; prose does not.
]]},

  {name = "build", title = "building a claimed item",
    body = [[
1. Claim it (`take ID`), then read `show ID` — the sidecar is the
   spec, and the item's verdict/pr fields carry any standing review
   state.
2. Re-run the spec's measured commands before building — the queue
   ages faster than the tree stands still. Numbers moved but the
   shape holds: refresh them in place (`spec ID FILE --base BASE`)
   and proceed. A fresh fact that breaks the shape or reopens a
   decision: file the question as its own item, block this one on
   it, then release the claim (`help block` has the order). A bounce
   is a good outcome — the bar failing loudly instead of a silent
   wrong guess — and answering the question may well be your own
   next action; do that from the spec and the tree, not from what
   you remember wanting.
3. One item = one fresh branch off the latest default branch, named
   for the id's first 8 characters = one PR. Never stack a second
   item on a branch, and never reuse a branch whose PR is open.
4. Build exactly the `## Change`; its stated walls hold. A scope
   question the spec cannot answer goes back to the board, never
   into the diff — having written the spec is not permission to
   reinterpret it mid-build.
5. Open the PR READY for review (not draft) with `Board: <full id>`
   as the body's first line, and record it (`take ID --pr N`). The
   body carries no evidence: CI proves the gate on the head
   mechanically, and a pasted verdict line could only agree with the
   checks tab or lie — `## Acceptance` output included. Run the gate
   locally before pushing — a red head burns a review round — but
   the run is for you, not for the record.
6. Rejoin the loop. Never merge unreviewed work, and never accept
   your own: the verdict comes from a fresh-context review.

Out-of-scope findings (a real defect, a stale doc, a gap the item
sits next to but does not own): search first — the board is a git
checkout of text files, so `grep -ril '<phrase>' items/` answers
"already filed?" — and cite the existing item rather than duplicate
it; else `new "title" --spec-file F` with one paragraph of
evidence, unparented. Filing is never refused. Then back to the
item: never widen the diff to cover a finding.
]]},

  {name = "review", title = "the fresh-context review and its verdicts",
    body = [[
Nothing merges without a verdict from a review at a DISTANCE from
the builder: a subagent whose context window never held the build.
Its brief carries the item id, the PR number, and the process — not
the builder's reasoning, and not a summary of intent, which would
hand back the commitment a fresh window exists to be without. Emit
the brief with `brief review ID` rather than hand-writing one. The
reviewer claims the review first (`take ID` on an item awaiting a
verdict, under a self-named review-<ID>-<unique> session), reads the
spec off the board and the diff off the PR, and records the verdict
itself.

The posture is adversarial — the job is to make the diff fail, and
a review that only reads has verified nothing:

1. Green is mechanical — CI on the PR's CURRENT head is the
   acceptance: read it, don't re-run it. Red or still running ends
   the review immediately. What CI cannot see is the whole job: the
   diff must carry its own proof, so a claim the change makes that
   no test in the diff would catch regressing is a gap to quote.
2. The diff is the Change — everything present, nothing extra.
   Scope creep gets cut even when it is good; good ideas become
   items.
3. The walls held — frozen contracts unmoved, and any walls the
   spec states untouched.
4. Conventions hold — the repo's AGENTS.md binds; anything a gate
   should have caught but did not is itself a finding to file.
5. It serves the outcome — walk the parent chain to the root and
   judge the diff against it. A green gate on a change that misses
   the point means the SPEC was wrong: fix the spec, never wave the
   diff through.
6. It is the least thing — name any surplus concretely (a helper
   with one caller, generality nobody asked for) and have it
   removed before merge.

Mutation-test at least one guard the change adds: break what it
guards, watch the test go red, restore it. A gate that cannot be
shown to fail is decoration.

Three verdicts. `accept` — merge (a main-repo PR lands by enabling
auto-merge; a board PR merges directly), then `done ID`. `request
changes` — the concrete gaps quoted on the PR; the claimant reworks
on the same PR. `reject` — the approach is wrong: close the PR,
record what was learned, clear the claim. A reject that reopens a
decision uses the block-first exit: file the question as an item
and block this one on it, so the learning holds the item back until
answered. Rejection is cheap by design; wrong work merged is
expensive. A research item takes the same verdicts, re-running its
recorded checks in place of a diff — checks its spec carries because
whoever claimed it (an orchestrator applying a `brief research ID`
agent's recommendation, or a solo session) already wrote them there;
there is no PR to fetch, so `verdict` judges the claim and the spec
revision instead.

When a container's last child ends, verify the container's stated
outcome actually holds — run its observable test, not the
children's — then end it.
]]},

  {name = "orchestrate", title = "concurrent agents and the standing loop",
    body = [[
One orchestrator, N builders, and the board stays with the
orchestrator — agents never run board verbs, so no agent needs this
worktree or push rights to `board`:

- Claim first, then spawn. Claim each item yourself, one at a time,
  reading each verdict line, with a distinct minted session name per
  agent. A lost race is the lock working: take the next item.
- Disjoint or not at all. `next` names one item and cannot see what
  else you are taking; file-disjointness across the wave is your
  check, judged on the MERGE — a shared file with thin headroom
  under a line cap counts as shared. Say what you skipped and why.
  Never split one item across agents to make it faster.
- One fresh worktree per agent, never nested inside another checkout
  — nesting breaks build gates in both directions, and neither
  failure names the layout. A fresh worktree bootstraps first; a
  copied tree drops its stale output directory, or its first gate
  result is fiction.
- The brief carries the spec verbatim — "read the board and do it"
  turns a specified item back into an interpretation. Emit briefs
  with `brief builder ID` / `brief research ID` / `brief review ID` /
  `brief refine ID` / `brief decompose ID` rather than hand-writing
  them: a hand-written brief drifts, and the emitted one already
  carries the spec, the item's coordinates, and the standing rules
  (ready PR with the Board: line, no pasted gate output, do-not-merge,
  the capture rule, the bounce rule).
- A research slice (its spec says its deliverable is board state, not
  a diff — no product PR) still gets a claim and a spawned agent, via
  `brief research ID` in place of `brief builder ID`: the agent does
  the measuring and drafts its recommendation — the item's full new
  spec, and each capture ready for `new`/`attach`/`block` — but never
  runs a `gitboard` command itself, even when the item's own spec
  tells it to. Applying that recommendation (`spec`, then `new` /
  `attach` / `block` per drafted capture) is yours, same as landing a
  PR is; only once it is applied does the claimed, PR-less item carry
  anything to `verdict`.
- Reconcile the wave. Finished with a PR: record it on the item
  (`take ID --pr N`). Finished with a research recommendation: apply
  it (above), which leaves the item claimed and PR-less, ready for a
  verdict same as any other claimed item — `review.md`'s
  research-slice clause. Dead (no PR, no recommendation, no branch):
  release the claim (`drop ID --why`, a worker-side reason) so the
  item is pullable again. Still running: leave it. Then the PRs are
  yours to watch — the agents are gone.
- What never fans out: the review verdict — reviews run one fresh
  subagent AT A TIME, however many PRs await; N agents reviewing N
  PRs in parallel is N unreviewed merges wearing a costume — and
  refinement, because two parallel refiners decompose the same
  outcome twice. Sequential is not fanning out: a pass MAY run
  several reviews back to back, each in its own fresh subagent.

The standing loop (a session invoked as an orchestrator with a
width N) runs ONE bounded pass and ends it. Never wait inside a
pass — not for a wave agent, not for CI, not for an answer; the
single exception is a review subagent. Reviews outrank pulls
inside the pass, and the tool holds that mechanically: `take`
refuses a todo pull while an unclaimed diff the session could
review awaits a verdict — builds fan out N at a time while
reviews drain one at a time, so a loop that reviewed less than it
pulled accumulated open PRs until the doing bound refused every
take. Drain first and neither refusal ever fires:

1. `sync`, then reconcile the previous wave (above).
2. Merge whatever carries an accept.
3. Drain the reviews: while items await a verdict, review them —
   one fresh subagent at a time, sequentially, a distinct minted
   review session for each. Only the sequencing is yours to hold;
   that the wave cannot fill past waiting verdicts, the take gate
   already holds.
4. Fill the wave: claim then spawn in the background, up to the
   smallest of N and what is actually disjoint. Zero agents is a
   legitimate pass.
5. Spare width goes to one or two refine/triage actions.
6. Report a terse ledger — one line per board action, one for
   anything posted for a human — and end the pass.

`none` from `next` is an answer, not a failure: report the named
bottleneck in one line and end the pass.
]]},
}

--- The topic names, in listing order.
--- @return {string} Names
local function names(): {string}
  local out: {string} = {}
  for _, p in ipairs(PAGES) do
    out[#out + 1] = p.name
  end
  return out
end

--- One topic's rendered page, nil for a name that is not a topic.
--- @param name string The topic name
--- @return string | nil Title line, blank line, body
local function page(name: string): string | nil
  for _, p in ipairs(PAGES) do
    if p.name == name then
      return ("%s — %s\n\n%s"):format(p.name, p.title, p.body)
    end
  end
  return nil
end

--- The topic list, one aligned row per topic, for the overview help.
--- @return string The rendered list, no trailing newline
local function listing(): string
  local width = 0
  for _, p in ipairs(PAGES) do
    if #p.name > width then
      width = #p.name
    end
  end
  local lines: {string} = {"topics ('gitboard help <topic>'):"}
  for _, p in ipairs(PAGES) do
    lines[#lines + 1] = ("  %s%s  %s"):format(p.name,
      string.rep(" ", width - #p.name), p.title)
  end
  return table.concat(lines, "\n")
end

local record doctrine
  names: function(): {string}
  page: function(name: string): string | nil
  listing: function(): string
end

local M: doctrine = {
  names = names,
  page = page,
  listing = listing,
}

return M
