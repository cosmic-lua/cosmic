## Goal

G8 — the flow system. `decompose.md` tells a session that "the research
IS the slice: an enablement item whose deliverable is recorded evidence
and the follow-up slices, not code", and the tool refuses to accept
one. This slice makes the two agree by giving an evidence slice a real
handover, so its findings get reviewed instead of stranding the item.

## Evidence

Hit live on 2026-08-26 working `3ISWHyP7`. Its A/B was designed, run
and recorded — six alternating isolated measurements across two cosmos
pins, a verdict per scenario, and two follow-up items filed and
published (`3ISlWFiS`, `3ISlY5Xl`). Then:

```
gitboard move 3ISWHyP7 check
gitboard-move: REFUSED: a handover to check names its PR — pass --pr N
```

The item was left in `plan` with the reason in its `## Result`, blocked
on this one. `do` reads as claimed-and-unfinished, `plan` reads as
un-refined; neither is true.

**The pick, so the next session does not have to make it.** Three
options were weighed in this item's original capture (below). This
spec takes **option 1: `check` accepts an evidence handover, reviewed
against the item's recorded `## Result`.** Option 3 (research is
refinement) needs no code but throws the review away — nobody checks
that the A/B was sound before its conclusions become two specs, which
is the one thing `SKILL.md` says the builder/reviewer distance exists
for. Option 2 (always land a doc PR) forces every research slice to
argue where its prose belongs and puts the evidence in two homes when
the board is meant to be the one. Option 1 keeps the review and costs a
declared flag.

Measured 2026-08-26 on `board` at `f0b0a975`, from the `o/board`
worktree:

- `_work/gitverbs.tl:97-100` is the refusal:
  `if target == "check" and (pr or 0) == 0 and (it.pr or 0) == 0 and not
  force then` → `REFUSED: a handover to check names its PR — pass --pr N`.
  `wc -l _work/gitverbs.tl` → **256** (244 of headroom).
- `_work/gitgate.tl:283-286` is `land_refusal`'s second half:
  `if (it.pr or 0) == 0 then` → `a move into land names its PR`. So an
  evidence item accepted today would be refused at `land` as well.
  `wc -l _work/gitgate.tl` → **364** (136 of headroom).
- `_work/gitverbs.tl:152` — on a verdict from `check` or `land`, the
  implied move carries the judgment. An accepted evidence item would
  therefore arrive in `land`, which exists to merge a PR it does not
  have. `_work/gitboard.tl:180-202` already refuses a not-planned
  ending from `land`, for the mirror reason.
- `_work/item.tl:28` is `record Item`; `claim` is at `:52`, `builders`
  at `:62`, `pr` at `:64`. The literal round-trip is `:208-223`
  (read) and `:269-270` (write) — a new field is added in both halves.
  `wc -l _work/item.tl` → **320** (180 of headroom).
- `_work/item.tl:145-147` refuses `claim/pr/verdict/repo` on a root
  ("belong to worked items, not roots") — the new field joins that
  list, since only a workable leaf can be evidence.
- The test files that pin these behaviours already exist:
  `_work/gitverbs_test.tl`, `_work/gitgate_test.tl`,
  `_work/gitverdict_test.tl`, `_work/item_test.tl`.

## Change

Add an `evidence` flag an item declares at handover, and let it stand
in for the PR everywhere the PR is demanded.

**On the `board` branch** (machinery; the branch's `README.md` has how
it is built and gated):

1. `_work/item.tl` — add `evidence: boolean` to `record Item` beside
   `pr` (`:64`), default `false`. Read it in the literal parse
   (`:208-223`) and write it back only when true (`:269-270`), matching
   how `claim` and `builders` are conditionally written. Add `evidence`
   to the root refusal at `:145-147` so a root cannot carry it.
2. `_work/gitverbs.tl:97-100` — the PR refusal fires only when the item
   is not evidence: an item whose `evidence` is true, or a move passing
   `--evidence`, hands over with no `--pr`. The builder refusal at
   `:101-109` is UNCHANGED — an evidence handover still names its
   builder, because that is what withholds the verdict from it.
3. `_work/gitverbs.tl:152` — on an `accept` verdict, an evidence item
   ENDS as `completed` instead of moving to `land`. `land` is the merge
   step and there is nothing to merge. A non-accept verdict is
   unchanged: rework returns to `do` exactly as now.
4. `_work/gitgate.tl:283-286` — `land_refusal` keeps demanding a PR;
   step 3 means an evidence item never reaches it, and if one is forced
   there the refusal is still right.
5. `_work/gitboard.tl` — register `--evidence` on `move` and describe
   it in the generated help: "hand over recorded evidence, not a diff;
   the reviewer reads the item's `## Result`".
6. Tests, in the files named in `## Evidence`: a handover to `check`
   with `--evidence` and no `--pr` SUCCEEDS; the same handover without
   `--evidence` still refuses; an `accept` on an evidence item ends it
   `completed` and does not enter `land`; a root refuses `evidence`.

**On `main`** (the PR this slice carries):

7. `skills/work/decompose.md` — the research-slice paragraph (the "if a
   slice cannot be sized without research" sentence) gains what an
   evidence slice's `## Acceptance` is (the commands that produced the
   numbers, and their verdict lines quoted into a `## Result` section)
   and how it hands over (`move ID check --evidence`, no PR).
8. `skills/work/SKILL.md` — the slice loop's step 5 says a slice hands
   over "WITH its number"; add the evidence variant beside it.
9. `skills/work/review.md` — say what reviewing an evidence item asks:
   are the measurements sound and repeatable, does the stated verdict
   follow from them, are the follow-ups the right ones. A reviewer with
   no diff needs to be told what to judge.

## Non-goals

- **Do NOT relax the refusal by inspecting the spec sidecar** — e.g.
  "allow it when a `## Result` section exists". A code slice's spec can
  grow that heading too, and then a real diff reaches a reviewer with
  no PR because someone forgot `--pr`. The declaration is explicit or
  it is not a guard.
- **Do NOT touch the builder refusal** (`_work/gitverbs.tl:101-109`) or
  the `next` rule that withholds a verdict from an item's builder. An
  evidence slice needs that distance MORE than a code slice, not less.
- **Do NOT weaken `land_refusal`.** `land` merges; an item with no PR
  has no business there, and step 3 is why it never arrives.
- **Do NOT change the ready bar's five sections** or `_work/spec.tl`.
  `## Result` is prose an evidence item accumulates while it runs, not
  a sixth required section, and `gitboard check` must not start
  demanding it.
- **Do NOT retro-mark any existing item as evidence** except
  `3ISWHyP7`, which is blocked on this one and is the case that found
  it. Every other item in flight carries a PR.
- **Do NOT rewrite `board` history.** The branch is append-only; the
  machinery change is an ordinary commit on it.

## Acceptance

Machinery, from the `o/board` worktree:

- `bin/cosmic --make ci` → `ci: PASS`.
- `bin/cosmic --make test _work/gitverbs_test.tl _work/gitgate_test.tl
  _work/gitverdict_test.tl _work/item_test.tl` → `test: PASS (4 files)`.
- `wc -l _work/item.tl _work/gitverbs.tl _work/gitgate.tl
  _work/gitboard.tl` — every file ≤ 500 (today 320, 256, 364, 333).
- `o/bin/gitboard help move` lists `--evidence` (today: it does not).
- End to end on a scratch item, from the worktree — create it, hand it
  over with `--evidence` and no `--pr`, and confirm the verdict ends it:
  `o/bin/gitboard move <scratch> check --evidence` →
  `gitboard-move: <id> do -> check`, then
  `o/bin/gitboard verdict <scratch> accept --session other` →
  the item ends `completed` and `o/bin/gitboard status` shows `land`
  unchanged in depth.
- The same handover WITHOUT `--evidence` still prints
  `REFUSED: a handover to check names its PR — pass --pr N`.

Skill docs, from the cosmic repo root:

- `bin/cosmic --make ci` → `ci: PASS (5 stages)`.
- `grep -c -- "--evidence" skills/work/decompose.md skills/work/SKILL.md
  skills/work/review.md` — each ≥ 1 (today all three return 0; the bare
  word "evidence" already occurs 1/6/9 times, so the FLAG spelling is
  what this checks).

Then, and only then:

- `o/bin/gitboard show 3ISWHyP7` no longer lists `3ISltQMh` among its
  blockers, and `o/bin/gitboard move 3ISWHyP7 check --evidence` is
  accepted — the case that found this is the case that proves it.

## Enablement

`none needed`. The machinery is a cosmic project like any other: the
`board` branch's `README.md` has the build and the gate, `gitboard
help` is generated from the CLI so the new flag documents itself, and
the four test files that pin today's refusals already exist.

One thing the implementing session should know rather than rediscover:
this slice spans two branches. The `_work/**` change is an ordinary
commit pushed to `board` (board state never goes through a pull
request, and the branch's README covers machinery changes), while the
`skills/work/**` change is a normal PR on `main` — and that PR is the
one this slice hands over with. So this item is NOT itself an evidence
slice; it has a diff.

## The capture that opened this

Recorded 2026-08-26, before the pick above was made — retained so the
choice can be re-argued against what was actually known.

The work skill invites the evidence shape and the tool refuses it.
`decompose.md`: "if a slice cannot be sized without research, the
research IS the slice: an enablement item whose deliverable is recorded
evidence and the follow-up slices, not code." `SKILL.md` adds that a
review is worth the distance between builder and reviewer. Both are
satisfied by an evidence slice — there is something to judge and a
different session can judge it. What was missing is a handover that
carries evidence instead of a diff.

The three options weighed:

1. **`check` accepts a slice with no PR**, reviewed against the item's
   recorded evidence. Risk: a real code slice sneaks through review
   with no diff because someone omitted `--pr`, so the relaxation has
   to be explicit. ← taken.
2. **Every research slice lands a doc PR** carrying its finding. Keeps
   one handover shape; costs an argument about where the prose belongs
   on every such slice, and puts evidence in two places when the board
   is supposed to be the one home for work state.
3. **Research is refinement, not a slice.** Do it in `plan` and let its
   deliverable be the implementable specs it produces — which is what
   `3ISWHyP7` actually did. Costs: refinement becomes unbounded in
   size, and a multi-hour measurement gets no claim, no WIP slot, and
   no review.
