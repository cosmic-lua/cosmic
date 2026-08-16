# Reviewing: verdicts and the friction feedback loop

review is the planner's first duty in every session (`SKILL.md`), and
it is the system's FINAL GATE: nothing merges without a sophisticated
model judging the implementation against the definition of work AND
the goal it traces to. an issue sits in `plan:review` with a PR
attached — that column means exactly "awaiting a planner verdict",
nothing else — and the planner ends that state with one of three
verdicts, every time.

## the review itself

read the issue first, then the PR against it:

1. **acceptance ran.** the PR quotes the issue's `Acceptance`
   commands and their verdict lines (`ci: PASS`, the narrow checks) —
   and CI is green on the PR's CURRENT head. a branch that moved
   since the quoted run (a rework push, a merge of main) needs its
   fresh run read, not assumed; an in-progress run is a reason to
   review the next card and come back, never to wave through.
   absent or failing evidence ends the review immediately — verdict
   2, "run the acceptance."
2. **the diff is the Change.** everything in `## Change` is present;
   nothing outside it snuck in. scope creep gets cut even when it is
   good — good ideas go to the board as shaping issues, not into an
   unrelated diff.
3. **the walls held.** `## Non-goals` items are untouched; frozen
   contracts (the `cosmo.*` C boundary, error strings and return
   shapes, verdict line formats, `definitions.lua` coupling) are
   unmoved unless the issue explicitly moved them.
4. **conventions hold.** AGENTS.md binds: naming, error shapes, file
   caps, cast justifications. anything a gate should have caught but
   did not is itself a finding — for the enablement backlog, not
   just this PR.
5. **it serves the Goal.** re-read the issue's `## Goal` trace and
   judge the change as built against it: does this diff actually move
   the named goal's win condition (or the parent epic's outcome), or
   does it satisfy the letter of Acceptance while missing the point?
   this is the judgment only the planner can make — acceptance
   commands prove the issue was implemented; only reading the goal
   proves the issue was worth implementing as built. a diff that
   passes 1–4 but fails this one means the ISSUE was mis-specified:
   fix the specification (and file the ready-bar gap), don't wave the
   diff through.
6. **it is the least thing.** ask of the diff: would a strictly
   smaller one satisfy the same issue? name the surplus concretely —
   a helper with one caller, an abstraction with one instance, an
   option nobody asked for, generality the issue did not demand — and
   request its removal before merge (goals.md's least-thing promise;
   G9 is its measured half, this check is the judged half). the same
   pressure reads the other way: a diff that grew because the ISSUE
   over-asked is a ready-bar finding, filed like any other.

## the three verdicts

- **accept.** the PR is ready to land: say so ON THE PR — a comment
  naming what was verified and ending in the verdict — then `move N
  doing`. landing is implementer-lane work: the finish-first rule
  makes an accepted PR the first thing the next implementer session
  picks up, and it squash-merges (the `Closes #N` closes the issue).
  the planner judges; the implementer lands. when a landing closes an
  epic's last child, the next planner pass verifies the epic's stated
  outcome actually holds (run its observable test, not the
  children's) and closes the epic.
- **request changes.** concrete, quoted gaps on the PR, then `move N
  doing` — rework rejoins the implementer queue, where `next`'s
  finish-before-pull rule makes it the first thing an implementer
  picks up (rework is the work closest to completion). the same PR
  carries the fixes; the issue returns to `plan:review` with them.
  use this when the work is right-shaped but incomplete. never leave
  a changes-requested issue sitting in `plan:review`: that column
  waits on planners, and implementers do not look there.
- **reject.** the approach is wrong, or the issue itself was not
  actually ready. close the PR, comment what was learned, and move
  the issue LEFT — `move N shaping` (or close it as not planned if
  the work should not happen at all). rejection is cheap by design;
  wrong work merged is expensive.

a research slice (deliverable: a comment, no PR) takes the same
three verdicts, on its comment: accept means re-running the issue's
acceptance checks against the tree — totals recomputed, cited
`file:line`s read, claims spot-verified — then commenting the
verdict and closing the issue as completed. the harvested follow-ups
(epic checklist updates, new children, corrections to sibling
issues) are the SAME session's refinement obligations, not a note
for later: accepted research that seeds nothing has not finished
being reviewed.

## landings invalidate the queue

every landing rewrites main, so any other PR — accepted or still in
review — that regenerates the same committed baseline
(`.cosmic-coverage`, a ratchet floor) now conflicts on its derived
lines even when the real diffs are disjoint. the recovery is
mechanical and belongs to the implementer lane AT LANDING TIME:
merge main, run the regen command the gate prints, commit, re-run
the gate, land. no fresh verdict is needed when the ONLY conflict is
a regenerated file — the reviewed diff did not change. anything
beyond that (a source-line conflict, a gate that stays red after the
regen) is not a landing anymore: `move N review` with the conflict
described, and the planner re-judges. the same regenerated-file
conflict appearing on a second PR is enablement evidence under the
feedback half below: file the countermeasure that deletes the
contended line, rather than paying the tax once per landing.

## the feedback half — never skip it

every non-accept verdict, and every bounce an implementer initiated,
carries information about why a presumed-ready issue was not. before
ending the session, the planner converts it:

1. name the wrong turn in one line (on the issue).
2. pick the countermeasure by the `enable.md` ordering (core > docs >
   skills) and file the `plan:enable` issue, or fix the ready-bar gap
   directly if it was this one issue's specification failure.
3. if the same wrong turn has now appeared twice, the countermeasure
   stops being optional: file it before refining anything new.

findings enter the same loop from the implementer side: at the refine
step the planner triages every open `plan:finding` — adopt it with a
goal trace, or close it as not planned — and one this review itself
confirms is countermeasure evidence like any bounce.

this loop is what makes the system converge: goals pull work onto the
board, reviews push friction back into enablement, and over time the
share of issues a less sophisticated model completes without a bounce
is the measure that planning is working. a rising bounce rate means
the ready bar drifted or enablement debt is due — spend the next
planner sessions there, not on intake.
