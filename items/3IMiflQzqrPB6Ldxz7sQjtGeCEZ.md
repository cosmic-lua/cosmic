# Problem

`skills/work/SKILL.md` tells a session facing a capture that fits no
existing outcome to "post the pair and stop rather than inventing an
answer". A scheduled session has nobody to ask, so that rule converts
one unrankable capture into a dead run.

Observed on the 2026-08-24 scheduled run: triage stood at 12/8, over
bound, and `next` serves triage oldest-first. The three oldest captures
(3IKD33rv markdown, 3IKEcDqs markdown xref lint, 3IKFaYlG templating)
each propose a new stdlib battery, and no ranked outcome hosts that
class — G7 owns the battery test ("without shelling out or vendoring
C") but is scoped to serving and parked last. The session stopped after
one action with 11 items still queued, five of them ordinary
defect/doc captures needing no judgment at all, stuck behind the
proposals in the oldest-first queue.

The cost is one-sided. `check` refuses to promote work with no
position, so "leave it unplaced" is not the cautious answer — it is the
answer that makes the item unreachable and holds the whole triage queue
over bound.

Reproduce the rule: `grep -n "post the pair and stop" skills/work/SKILL.md`
names the line on `main` at 9bcb0f7d.

## Change

- `skills/work/SKILL.md`: narrow the reserved judgment to a comparison
  that would put new work ABOVE existing work — a new outcome ordered
  against the ranked ones, or a capture compared up into a band it
  would displace. That pair is posted (in chat, or in the session's
  report when nobody is watching) and the session keeps working.
- `skills/work/SKILL.md`: state the fallback for every other case —
  attach the capture under the lowest-placed outcome it plausibly
  serves and say so. A low placement outranks nothing, `attach`
  re-parents it when the answer arrives, and the item is at least
  visible to every verb that walks the order.
- `skills/work/decompose.md`: the paired-comparison chapter says to ask
  in chat; give it the unattended path, so a session with no chat puts
  the pair in its report rather than into a wait.
- `_work/guidance.tl` on `board` (landed as baa99e6a, pushed directly
  per that branch's README): the `triage` guidance `next` prints states
  the fallback as fact — "No outcome fits? Attach under the
  lowest-placed one regardless: it outranks nothing, `attach`
  re-parents freely, and an unplaced item can never be promoted."

## Non-goals

- Who decides the order does not change. A comparison that raises work
  stays the goal owner's, and this change invents no comparison edge.
- No change to `gitboard`'s verbs, the ready bar, or the WIP limits.
- The battery proposals' placement under G7 is provisional, not a
  ruling: the open pair — a "batteries beyond serving" outcome against
  G6, or widening G7 — is posted for the goal owner and settled by one
  `compare` or one `attach`.

## Acceptance

- `bin/cosmic --make ci` at the repo root: `ci: PASS (5 stages)`.
- `bin/cosmic --make ci` in the `board` worktree, covering the guidance
  change: `ci: PASS (4 stages)`.
- `bin/cosmic --make test _work/guidance_test.tl` in the `board`
  worktree: `test: PASS (1 file)` — the guidance stays inside the
  6-line, 88-column budget `test_guidance_stays_terse` and
  `test_lines_fit_the_indented_width` enforce. The first draft of the
  wording failed it with `triage spends 8 lines, over the 6-line
  budget`, so the gate discriminates.
- `grep -n "post the pair and stop" skills/work/SKILL.md` finds nothing.
- Behavioural: triage went 12/8 (over bound) to 0/8 with
  `gitboard-status: WIP ok` under exactly this rule — five captures
  under the outcome their evidence serves, five battery proposals low
  under G7, one flow defect under G8, one fuzz defect under the
  `cosmic.fuzz` container.
