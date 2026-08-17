# Reviewing: verdicts and the friction feedback loop

review is the planner's first duty in every session (`SKILL.md`), and
it is the system's FINAL GATE: nothing merges without a sophisticated
model judging the implementation against the definition of work AND
the goal it traces to. an item sits in `check` with a PR attached —
that phase means exactly "awaiting a planner verdict", nothing else —
and the planner ends that state with one of three verdicts, every
time. `check` is the only phase a verdict may end, and the verb
refuses one from anywhere else: an accept reaches `land` past every
gate between them, so it may only be given where review happens.

## the review itself

read the item first (`gitboard show ID` — the spec sidecar), then the
PR against it:

1. **acceptance ran.** the PR quotes the spec's `Acceptance`
   commands and their verdict lines (`ci: PASS`, the narrow checks) —
   and CI is green on the PR's CURRENT head. a branch that moved
   since the quoted run (a rework push, a merge of main) needs its
   fresh run read, not assumed; an in-progress run is a reason to
   review the next item and come back, never to wave through.
   absent or failing evidence ends the review immediately — verdict
   2, "run the acceptance."
2. **the diff is the Change.** everything in `## Change` is present;
   nothing outside it snuck in. scope creep gets cut even when it is
   good — good ideas go to the board as items, not into an unrelated
   diff.
3. **the walls held.** `## Non-goals` items are untouched; frozen
   contracts (the `cosmo.*` C boundary, error strings and return
   shapes, verdict line formats, `definitions.lua` coupling) are
   unmoved unless the spec explicitly moved them.
4. **conventions hold.** AGENTS.md binds: naming, error shapes, file
   caps, cast justifications. anything a gate should have caught but
   did not is itself a finding — for the enablement backlog, not
   just this PR.
5. **it serves the Goal.** walk the item's parent chain to its goal
   and judge the change as built against it: does this diff actually
   move the goal's win condition (or the parent container's outcome),
   or does it satisfy the letter of Acceptance while missing the
   point? this is the judgment only the planner can make — acceptance
   commands prove the spec was implemented; only reading the goal
   proves the spec was worth implementing as built. a diff that
   passes 1–4 but fails this one means the SPEC was mis-specified:
   fix the specification (and file the ready-bar gap), don't wave the
   diff through.
6. **it is the least thing.** ask of the diff: would a strictly
   smaller one satisfy the same spec? name the surplus concretely —
   a helper with one caller, an abstraction with one instance, an
   option nobody asked for, generality the spec did not demand — and
   request its removal before merge (goals.md's least-thing promise;
   G9 is its measured half, this check is the judged half). the same
   pressure reads the other way: a diff that grew because the SPEC
   over-asked is a ready-bar finding, filed like any other.

## the three verdicts

three verdicts, three directions out of `check`, and one verb records
each: `gitboard verdict ID <kind> --pr N --head SHA` stores the
verdict and the head commit it judged on the item and performs the
move it implies, in one board commit. nothing is posted to the PR to
carry state — write review prose on the PR for the humans reading it,
but the item is the record the tool reads.

- **accept** — `verdict ID accept` moves the item into `land`. the
  move is never refused — a verdict already made is not inventory —
  and the landing itself is implementer-lane work: the finish-first
  rule makes it the first thing the next implementer session picks
  up, squash-merging the PR and running `done ID`. the planner
  judges; the implementer lands. a landing that completes a
  container's last child returns that container to `plan` in the same
  commit, where the next planner pass verifies its stated outcome
  actually holds (run its observable test, not the children's) and
  ends it with `done ID`.
- **request changes** — quote the concrete gaps on the PR, then
  `verdict ID "request changes" --pr N --head SHA` moves the item
  back to `do`, where `next`'s finish-before-pull rule makes the
  rework the first thing an implementer picks up after a landing.
  the same PR carries the fixes; the item returns to `check` with
  them. the item's `verdict_head` records which commit was judged, so
  a reviewer can see at a glance whether anything new followed the
  verdict — read it before re-reviewing, and treat an unmoved head as
  nothing to judge. use this when the work is right-shaped but
  incomplete. never leave a changes-requested item sitting in
  `check`: that phase waits on planners, and implementers do not look
  there.
- **reject** — the approach is wrong, or the item was not actually
  ready. close the PR, record what was learned in the item's spec,
  and `verdict ID reject` sends it all the way back to `plan` (or
  `done ID --reason not-planned` if the work should not happen at
  all). rejection is cheap by design; wrong work merged is expensive.

a research slice (deliverable: recorded findings, no PR) takes the
same three verdicts: accept means re-running the spec's acceptance
checks against the tree — totals recomputed, cited `file:line`s read,
claims spot-verified — then `done ID`, with no move into `land`
because there is nothing to merge. the harvested follow-ups (new
children, corrections to sibling specs) are the SAME session's
refinement obligations, not a note for later: accepted research that
seeds nothing has not finished being reviewed.

## landings invalidate the queue

every landing rewrites main, so any other PR — accepted or still in
review — may now conflict with what landed. a committed ratchet floor
is the classic source of one: two disjoint diffs collide on the derived
lines they both rewrite. `.cosmic-coverage` mostly does not anymore — a
`--baseline` rewrite lowers only the rows the ratchet would have failed
on, and the file merges with git's `union` strategy, so both sides'
rows land and the ratchet reads a repeated path as its lower
percentage. expect this to be rare. when it does happen the recovery is
mechanical and belongs to the implementer lane AT LANDING TIME:
merge main, run the regen command the gate prints, commit, re-run
the gate, land. no fresh verdict is needed when the ONLY conflict is
a regenerated file — the reviewed diff did not change. anything
beyond that (a source-line conflict, a gate that stays red after the
regen) is not a landing anymore: `move ID check` with the conflict
described, and the planner re-judges. the same regenerated-file
conflict appearing on a second PR is enablement evidence under the
feedback half below: file the countermeasure that deletes the
contended line, rather than paying the tax once per landing.

## the feedback half — never skip it

every non-accept verdict, and every bounce an implementer initiated,
carries information about why a presumed-ready item was not. before
ending the session, the planner converts it:

1. name the wrong turn in one line (in the item's spec).
2. pick the countermeasure by the `enable.md` ordering (core > docs >
   skills) and file the enablement item (`gitboard new "title"
   --parent <goal> --spec-file F`), or fix the ready-bar gap directly
   if it was this one item's specification failure.
3. if the same wrong turn has now appeared twice, the countermeasure
   stops being optional: file it before refining anything new. no
   flag enforces this anymore — filing is never refusable, so the
   rule is the planner's own discipline, and a review that skips it
   twice is itself a finding.

a bounce that quotes a wrong or unmeasured tree-fact names its
countermeasure directly — the facts block was missing or stale for
that claim — and the fix is a facts entry in the re-refined spec, not
a prose apology.

findings enter the same loop from the implementer side: at the triage
step the planner takes every unranked root — `attach` it under the
goal its evidence serves (it enters `plan`), or end it: `done ID
--reason not-planned` for a finding that will not be worked, `done
ID` for one that landed work already covers, so the record says which
of the two happened. a finding this review itself confirms is
countermeasure evidence like any bounce.

this loop is what makes the system converge: goals pull work onto the
board, reviews push friction back into enablement, and over time the
share of items a less sophisticated model completes without a bounce
is the measure that planning is working. a rising bounce rate means
the ready bar drifted or enablement debt is due — spend the next
planner sessions there, not on intake.
