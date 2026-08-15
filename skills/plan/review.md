# Reviewing: verdicts and the friction feedback loop

review is the planner's first duty in every session (`SKILL.md`): it
is where implementer work becomes merged work, and where the system
learns. an issue sits in `plan:review` with a PR attached; the
planner ends that state with one of three verdicts, every time.

## the review itself

read the issue first, then the PR against it:

1. **acceptance ran.** the PR quotes the issue's `Acceptance`
   commands and their verdict lines (`ci: PASS`, the narrow checks).
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

## the three verdicts

- **merge.** squash-merge the PR; the `Closes #N` closes the issue as
  completed. if the epic's checklist is now fully checked, verify the
  epic's stated outcome actually holds (run its observable test, not
  the children's) and close the epic too.
- **request changes.** concrete, quoted gaps; the issue stays in
  `plan:review`; the implementer session (or the next one `next`
  sends there) addresses them on the same PR. use this when the work
  is right-shaped but incomplete.
- **reject.** the approach is wrong, or the issue itself was not
  actually ready. close the PR, comment what was learned, and move
  the issue LEFT — `move N shaping` (or close it as not planned if
  the work should not happen at all). rejection is cheap by design;
  wrong work merged is expensive.

## the feedback half — never skip it

every non-merge verdict, and every bounce an implementer initiated,
carries information about why a presumed-ready issue was not. before
ending the session, the planner converts it:

1. name the wrong turn in one line (on the issue).
2. pick the countermeasure by the `enable.md` ordering (core > docs >
   skills) and file the `plan:enable` issue, or fix the ready-bar gap
   directly if it was this one issue's specification failure.
3. if the same wrong turn has now appeared twice, the countermeasure
   stops being optional: file it before refining anything new.

this loop is what makes the system converge: goals pull work onto the
board, reviews push friction back into enablement, and over time the
share of issues a less sophisticated model completes without a bounce
is the measure that planning is working. a rising bounce rate means
the ready bar drifted or enablement debt is due — spend the next
planner sessions there, not on intake.
