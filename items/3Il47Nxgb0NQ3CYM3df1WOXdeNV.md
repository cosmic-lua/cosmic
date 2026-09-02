## Evidence

Reported by the builder of cosmic-lua/cosmic#1624 (item 3Iivjobs, the
`take ID --result` research handover). After that PR a result item
ranks as "review" through `flow.substate`, so two readers that were
written for PRs now also fire for a research handover with wording
that is wrong for it: `_work/action.tl:195` gives the review action
the reason "a PR awaits a verdict — verdicts before new work", and
`_work/guidance.tl:36-41` tells the reviewer to record
`verdict ... --pr N --head SHA` — a research item has no PR and no
head, and #1624's `verdict` refuses `--pr` against a handover.
#1624's spec held "no reader edited", so both stand. Re-measure at
pull time on a fixture: `take ID --result --session S`, then
`next --session T` and read the reason line and the guidance it
prints.

## Change

Board-tooling change on the `board` branch of cosmic-lua/cosmic, as a
PR against base `board`: `_work/action.tl`'s review reason and
`_work/guidance.tl`'s verdict instruction branch on `it.result ~= ""`
— "a research handover awaits a verdict" and `verdict ID
<accept|request-changes|reject> --session <you>` (no `--pr`/`--head`)
— with one test each (`_work/action_test.tl`, `_work/guidance_test.tl`
or wherever guidance is tested) on a result-item fixture. The PR
wording is untouched.

## Non-goals

- No change to `substate`, `take`, `verdict` or the brief templates.
