## Goal

G1 — the agent-eval instrument (docs/goals.md), via epic #1126. This item WAS the
epic container; both its board-tracked children (#1147 manifest+stage, #1179
score+checks+verdict) have landed, so per the decomposition ladder it returned to
`plan` and is refined here into the next slice in the epic's own dependency-ordered
follow-up list rather than spawned as a new child, because `plan` is currently well
over its WIP limit (drain first, add later): "a history format and release-asset
retention of journals." The remaining follow-ups named in the original epic body —
per-release cadence wiring, the noise-aware comparison/ratchet gate, peer sandboxes,
folding the round-4 backlog into task selection — are NOT this item; they get their
own `gitboard new --parent <this item, or the G1 goal>` once plan has slack again.

## Outcome (observable)

Today a run's `EvalResults` record (`_eval/eval_types.tl`, written by `_eval/score.tl`)
and the raw per-task journals (`NOTES.md` + `final.txt` in each task's run-dir
workspace) both exist only in the operator's local run directory and vanish once it is
cleaned up — nothing commits, uploads, or retains either. This item defines the
retained on-disk/asset shape for both and wires their publication, so a later child
(the per-release cadence wiring, and the comparison/ratchet gate) has durable history
to read.

Precedent to follow directly: `_perf/baseline.tl` + `release.yml`'s existing
perf/size asset chain — `_perf/run.tl` produces `perf.json`, `release.yml` uploads it
as a release asset, and `_perf/baseline.tl` fetches the previous release's named asset
over the GitHub REST API to compare against. Eval should get the analogous fetch
helper and the analogous `release.yml` upload step for (a) each run's `results.json`
(the `EvalResults` record, uploaded as-is — one file per release, mirroring
`perf.json`, not an aggregated/appended series) and (b) a retained bundle of the raw
per-task journals (`NOTES.md` + `final.txt` for all seven tasks), since those files
exist only transiently in the operator's run dir today and `Row.journal_path`
(`eval_types.tl`) already points at them by task id.

## Non-goals

Not this item: actually triggering/scheduling an eval run per release (the epic's
next follow-up, "per-release cadence wiring"); the noise-aware comparison or ratchet
gate that will consume this history (the epic's follow-up after that, analogous to
`_perf/gate.tl`); peer sandboxes; folding the round-4 backlog into task selection.
This item only defines the retained format and the fetch/upload mechanics a later
child builds on — it does not need to change `_eval/stage.tl` or `_eval/score.tl`'s
existing behavior beyond what retention requires.

## Enablement

research needed before this is ready: the exact asset-naming and fetch-helper shape
should mirror `_perf/baseline.tl` and `release.yml`'s perf/size steps closely enough
to reuse their pattern rather than invent a new one — read both first. Whether the
journal bundle is a tarball (`cosmic.tar`/`cosmic.compress`) or a per-task file set as
separate assets is an open design call for the planner to settle before this item
moves to ready, grounded in a fact-check of `release.yml`'s current asset list and
upload step shape.

---
Origin: planner refinement pass, following #1135's accepted comment (§4/§6), which
named "a history format and release-asset retention of journals" as the next
follow-up after #1147/#1179 landed. No prior GitHub issue existed for this slice.
