## Evidence

`gitboard brief review ID` refuses a claimed, PR-less research item
whose recommendation has been applied, and `next` never surfaces one
as awaiting a verdict — while `_work/doctrine.tl`'s review topic
(lines 260-265 at board `8e9a9619`) says a research item "takes the
same verdicts ... there is no PR to fetch, so `verdict` judges the
claim and the spec revision instead", and the orchestrate topic
(299-313) says applying the recommendation "leaves the item claimed
and PR-less, ready for a verdict".

Measured 2026-09-01 on four applied research slices (`YloP_x1CX`,
`YAQq_Fsja`, `aPvf_Gezb`, `7Gbq_90xl`, children of `3IQtgMjy`):

```
$ gitboard brief review YloP_x1CX
gitboard-brief: 3IR2U42t has no PR recorded — the handover (`take 3IR2U42t --pr N`) is what a review judges
```

and `gitboard next` offered a todo pull with all four claimed.

Where the tool stands (board `8e9a9619`):

- `_work/brief.tl:81-85`: `cmd_brief` refuses `review` when
  `(it.pr or 0) == 0`. Its own message names the cause exactly: the
  handover is what a review judges, and a research item has no
  handover verb — `take --pr N` is the only one.
- `_work/flow.tl:66-76` `substate`: an item is "review" only when
  `pr ~= 0`; a claimed PR-less item is "building" whatever happened to
  it, so `_work/action.tl:184-196`'s review rung never sees it.
- `_work/gitverdict.tl:127-130,171-177`: `verdict` ALREADY handles a
  PR-less item — no head to verify, `verdict_head` stays empty, the
  already-judged guard degrades to the spec revision (`verdict_spec`).
  So the verdict half works; only the handover and its two readers
  are missing.
- `_work/gitverbs.tl:386-395` `done`: a PR-less item with a non-empty
  `builders` and no accept is refused without a verdict — the
  reference condition; it needs no change.

The fields alone cannot tell "research applied, awaiting a verdict"
from "builder mid-flight": both are claimed, PR-less, `builders`
non-empty (the apply flow is `drop` → `spec` → `take` again, because
`spec` refuses a live claim). A PR-side item gets its tell from
`take --pr N`; the research side needs the same verb shape.

## Change

Board-tooling change on the `board` branch of cosmic-lua/cosmic, as a
PR against base `board`, one handover for research mirroring the PR
one:

1. `_work/item.tl`: a `result: string` field — the sha256 of the spec
   sidecar at handover (the same digest `verdict_spec` records), empty
   when unset. `problems` reports an item carrying both `pr ~= 0` and
   `result ~= ""` (a deliverable is a diff or board state, never
   both), and `result` on an item with no `builders` (a handover with
   no work).
2. `_work/gitverbs.tl` (`take`): `take ID --result` records the
   handover — refused unless the caller holds the live claim (same
   rule as `--pr`), refused when `pr ~= 0`; it stores the current
   spec's digest and clears any standing `verdict` the way `--pr`
   re-opens one for a new head. `take ID --pr N` on an item with
   `result` set is refused symmetrically.
3. `_work/flow.tl` `substate`: `result ~= ""` ranks as "review"
   exactly as `pr ~= 0` does, so `next`'s review rung, the take gate
   ("diff(s) await a verdict") and `show` all see it — one change at
   the one declaration, no reader edited.
4. `_work/brief.tl` + `_work/brieftext.tl`: `brief review` accepts an
   item with `result ~= ""` and emits a `RESEARCH_REVIEW` template —
   the spec verbatim, no PR/diff to fetch, the instruction to re-run
   every probe the spec records and to judge the spec revision and
   the captures it names (`new`/`attach`/`block` landed on the board),
   and the same verdict command without `--pr`/`--head`. The
   PR-based `REVIEW` template is untouched.
5. `_work/gitverdict.tl`: for an item with `result ~= ""`, refuse when
   the spec's current digest differs from `result` (the spec moved
   after handover — hand it over again), the same shape as the
   head-moved refusal for PRs; otherwise the existing PR-less path
   records `verdict_spec` as today.
6. Tests: `_work/gitverbs_test.tl` (take `--result` accepts on a live
   claim, refuses without one and with a PR; `--pr` refuses with a
   result), `_work/flow_test.tl` (substate review for a result
   item), `_work/action_test.tl` (next offers the review ahead of a
   todo pull), `_work/gitverdict_test.tl` (spec-moved refusal),
   `_work/item_test.tl` (both problems), plus a `brief review` case
   on a result item. Runner mode. `help take`, `help verdict` and the
   doctrine's review/orchestrate lines that describe the research
   handover name `take ID --result` where they now say "leaves the
   item claimed and PR-less".

## Non-goals

- No change to `done`'s PR-less refusal (`_work/gitverbs.tl:386-395`).
- No change to the PR-based review flow or the `REVIEW` template.
- No retroactive handover for the four items in Evidence; the
  orchestrator hands them over with the new verb after this lands.

## Acceptance

- On a fixture item claimed by S with a spec: `take ID --result
  --session S` → `show` reports `awaiting review`; `next --session T`
  offers it as a review ahead of a todo pull; `brief review ID` emits
  the research template with no unfilled `<PR_*>` placeholder;
  `verdict ID accept --session T` records `verdict_spec`; editing the
  spec between handover and verdict is refused.
- `bin/cosmic --make ci` on the board branch ends `ci: PASS`.
