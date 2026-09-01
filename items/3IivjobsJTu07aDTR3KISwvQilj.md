## Finding

`gitboard brief review ID` refuses for a claimed, PR-less research
item whose recommendation has already been applied — even though
`_work/doctrine.tl`'s own `review` topic text states plainly: "A
research item takes the same verdicts, re-running its recorded checks
in place of a diff... there is no PR to fetch, so `verdict` judges the
claim and the spec revision instead."

## Symptom

```
$ gitboard brief review YloP_x1CX
gitboard-brief: 3IR2U42t has no PR recorded — the handover (`take 3IR2U42t --pr N`) is what a review judges
```

for an item whose spec was already replaced with a `## Result` section
(the orchestrator's applied research recommendation), leaving it
claimed and PR-less, exactly the state the doctrine's own research-slice
clause describes as "ready for a verdict."

## Provenance

Discovered 2026-09-01 orchestrating a `/work` wave: four research
slices (`YloP_x1CX`, `YAQq_Fsja`, `aPvf_Gezb`, `7Gbq_90xl`, all
children of `3IQtgMjycyFrxa8xT2ZqwOHfdJl`) each finished with a
recommendation, had it applied (`gitboard spec` with the recommended
`## Result` text, plus `gitboard new`/`set`/`block` for each drafted
capture), and were left claimed and PR-less per the orchestrate
doctrine's own instructions — expecting them to be reviewable per
`review.md`'s research-slice clause. `brief review` refused all four
with the same "no PR recorded" message. `gitboard next` also does not
surface any of the four as awaiting a verdict — it goes straight to
offering the next todo pull, as if a PR-less claimed item is invisible
to the review queue entirely.

## Change

To be scoped at refinement. The gap has (at least) two parts, and the
fix likely needs both:

1. `_work/gitverbs.tl`'s `brief` command (whatever function backs
   `cmd_brief`/`KIND_LIST`'s `review` branch) currently gates on `it.pr
   ~= 0` before emitting a review brief; it should also accept a
   claimed item with no PR but at least one entry in `builders`
   (mirroring the exact condition `_work/gitverbs.tl`'s `done` verb
   already uses — see its comment: "A PR-less item that was ever
   worked is evidence mid-review the same way... this keys on
   `builders`... rather than the LIVE claim"). The review brief text
   itself would then need a research-specific branch (no diff/PR to
   fetch; re-run the spec's own recorded probe commands instead, per
   `_work/brieftext.tl`'s existing `RESEARCH` template as a model for
   how a research-specific brief already reads).
2. Whatever priority function backs `next`'s "review outranks pull"
   ordering does not currently treat a claimed, PR-less, `builders`-
   nonempty item as a pending review — it should, so the standing
   orchestrator loop's "drain reviews first" step actually surfaces
   these instead of silently skipping straight to new pulls.

## Non-goals

- Do not change `done`'s existing PR-less-verdict-required refusal
  logic (`_work/gitverbs.tl` around the "evidence-only item takes a
  verdict too" comment) — that logic is already correct and is the
  reference this fix should match, not touch.
- Do not change the PR-based review flow in any way.

## Acceptance

- `gitboard brief review ID` succeeds for a claimed, PR-less item with
  a non-empty `builders` list, emitting a research-appropriate review
  brief (re-run the spec's own probe commands; no diff to fetch).
- `gitboard next` surfaces such an item ahead of a todo pull, the same
  way it currently surfaces a PR awaiting a verdict.
- A fixture modeled on this session's four real items (or a synthetic
  equivalent) exercises both halves of the fix.
