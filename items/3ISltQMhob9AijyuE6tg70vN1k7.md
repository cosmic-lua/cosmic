An evidence-only slice cannot be handed over: `check` requires a PR,
and a research slice has no diff to show.

Hit on 2026-08-26 working `3ISWHyP7`. That item's A/B was designed,
run, and recorded — six alternating isolated measurements across two
cosmos pins, a verdict for each of the two scenarios, and two follow-up
items filed and published (`3ISlWFiS`, `3ISlY5Xl`). Then:

```
gitboard move 3ISWHyP7 check
gitboard-move: REFUSED: a handover to check names its PR — pass --pr N
```

The work skill invites this shape and the tool refuses it.
`decompose.md` says: "if a slice cannot be sized without research, the
research IS the slice: an enablement item whose deliverable is recorded
evidence and the follow-up slices, not code." `SKILL.md` adds that a
review is worth the distance between builder and reviewer. Both are
satisfied by an evidence slice — there is something to judge (are the
numbers sound, does the verdict follow, are the follow-ups the right
ones?) and a different session can judge it. What is missing is a
handover that carries evidence instead of a diff.

The item is stuck in a bad place either way: `do` reads as claimed and
unfinished, and a bounce to `plan` reads as un-refined when the
measurement is done and correct. `3ISWHyP7` was bounced to `plan` with
the reason recorded in its `## Result`, which is the least-lossy of the
wrong answers, not a right one.

The question to settle, exactly one:

1. **`check` accepts a slice with no PR**, reviewed against the item's
   recorded evidence. Smallest change: relax the refusal to require
   EITHER a `--pr` or a non-empty `## Result` section, and let the
   reviewer read the sidecar. Risk: a real code slice sneaks through
   review with no diff because someone omitted `--pr`, so the relaxation
   probably has to be explicit (a flag, or a property the item carries).
2. **Every research slice lands a doc PR** carrying its finding — a
   decision record, or the relevant `skills/` chapter. Keeps one
   handover shape; costs an argument about where the prose belongs on
   every such slice, and puts evidence in two places (the item and the
   repo) when the board is supposed to be the one home for work state.
3. **Research is refinement, not a slice.** Do it in `plan` and let its
   deliverable be the implementable specs it produces. This matches what
   `3ISWHyP7` actually did — two passes in `plan`/`do` that produced two
   specs and no code — and would mean `decompose.md`'s "the research IS
   the slice" sentence is the thing to change. Costs: refinement is then
   unbounded in size, and a multi-hour measurement gets no claim, no WIP
   slot, and no review.

Whichever wins, `decompose.md` and the tool have to agree afterwards —
today they do not, and a session following the skill literally hits a
refusal with finished work in hand.
