Direction from the goal owner, 2026-08-18: prioritization becomes part of the
workflow. Oldest-first stays the default ordering; an item may OPTIONALLY carry a
priority weight, and the weights are elicited with the analytic-hierarchy method
(Saaty pairwise judgments) rather than asserted.

## Evidence (verified 2026-08-18 against the board machinery)

Queue order today is item age and nothing else, everywhere:

- `_work/flow.tl:130-141` — `oldest_first(b, phase)` sorts a phase by `id`, with
  the comment at `flow.tl:18` stating the intent: "sorting by id IS sorting by
  age and 'oldest first' needs no other" — ids are KSUIDs.
- `_work/action.tl:137-144` — the planner's refine action is
  `oldest_first(b, "plan")[1]`. The implementer's pull is the same rule over
  `ready`. Both roles' `next` therefore has exactly one tie-break: age.
- `_work/gitview.tl:34` — `status` renders each phase through the same function,
  so what a session SEES is also age order.

Items cannot express priority at all:

- `_work/item.tl:28-29` — `rank` is documented "Roots only: 1 is the top
  promise. 0 means unranked."
- `_work/item.tl:105-110` — validation actively refuses it anywhere else:
  "rank belongs to roots; a parented item carries none". So a workable leaf has
  no field to weight, and the board is append-only with immutable KSUIDs, so age
  cannot be edited to stand in for urgency.
- Goal rank does not reach queue order either: `_work/action.tl:155-166` reads it
  only to choose which goal to decompose at INTAKE, and intake is the last branch
  the planner rule reaches.

Observed consequence, same day: `3I3z2gOF` (the cross-repo item that unblocks the
whilp/cosmopolitan Landlock ABI 4-9 work under `3I1IfJ22`) sits 17th of 17 in
`plan` purely because it is the youngest. The tool's own rule would refine it
last. There is no supported way to say otherwise short of a planner refining out
of turn, which leaves no record of WHY it jumped the queue.

## Change (direction, not yet a specification)

1. An item may carry an optional priority weight. Absent a weight, ordering is
   unchanged — oldest-first remains the default and the common case, so a board
   nobody has prioritized behaves exactly as it does today.
2. Where weights are present, `next` and `status` order by weight, with age as
   the tie-break among equally-weighted items. A weighted item's position must be
   explicable from the data, not from a session's judgement.
3. Weights are ELICITED, not asserted: pairwise comparison over the contested
   set, in the analytic-hierarchy style (Saaty), producing a weight per item plus
   the consistency signal that says whether the judgments hang together. The
   comparison record is committed with the weights, the way goal ranks are
   committed twice today.

## Prior art in this repo, which this must reconcile with

`skills/work/decompose.md:41-67` already ranks GOALS by paired comparison and
names AHP explicitly at line 58 as "the heavyweight variant with weighted
judgments and a consistency ratio", deliberately preferring a plain win-count
tournament because "at a half-dozen goals the plain tournament converges in a
handful of questions and its record is legible". Extending to AHP-weighted ITEMS
is therefore not a gap being filled but a settled tradeoff being revisited at a
different scale (tens of items, not nine goals) - it needs a decision record via
the `decide` skill, amending or superseding that reasoning rather than quietly
contradicting it. D25 (`docs/decisions/d25-outcomes-and-instruments.md`) is where
the goal half is recorded.

## Open questions for refinement (planner's)

- Which phases honour weights? Ordering `ready` (what gets pulled) is the ask;
  whether `plan` (what gets refined) and `check` (what gets reviewed) follow is a
  separate decision with separate consequences.
- Does a weight decay or expire? A weight set during one context shift and never
  revisited becomes a permanent queue-jump that outlives its reason.
- What forces re-elicitation, and over which set? Comparing every open item
  pairwise is quadratic and does not converge; the contested set has to be bounded
  the way `decompose.md` bounds it with byes.
- Does the weight live on the item file (a new field, with the validation that
  `rank` has) or in a separate committed comparison record the weights derive
  from?
- WIP limits and the ready bar are explicitly never bent for flow reasons
  (`SKILL.md` hard rules). A priority weight must not become the loophole that
  reintroduces "just this once".
