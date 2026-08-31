## Goal

`izHf_Yo9h` (3IVLE371, "eval peer baselines") was pulled and bounced: its
`## Change` requires "the same scoring (silent bugs, checker-caught, cycles)"
applied identically across cosmic and CPython/Node/Go peer sandboxes, but that
premise does not hold against the suite as it exists on `main`.

## Evidence

Measured 2026-08-31 against `_eval/eval_types.tl` and `_eval/suite.tl` on
`origin/main`:

- The "C" (checker-caught) metric, per `Task.metrics`'s own doc comment, means
  errors Teal's static checker (`--check types`) catches before runtime. Plain
  CPython and plain Node have no built-in static checker — reporting `C` for
  those peers is either permanently `0`/`nil` (misleading, not "the same
  scoring") or requires adding mypy/TypeScript, which the item's own
  Non-goals-adjacent framing ("only CPython / Node / Go") forecloses.
- Four of the suite's seven tasks carry metrics with no peer-sandbox
  equivalent at all: `json-cli`, `module-tests`, `multi-module-build` score
  `G4` (did the agent adopt `cosmic --make ci` unprompted — no such gate
  exists in a bare peer container), and `contained-task` scores `G2` (cosmic's
  sandbox-denial/recovery instrument — nothing to escape in a bare peer
  container).
- Net: 3 of 7 tasks (`sqlite-indexer`, `child-tcp`, `text-report`, all
  `S,C,Y`) even nominally fit the "same scoring" premise, and all three still
  hit the C-metric gap above. Zero tasks can be scored identically across all
  four table columns as the item's `## Change` specifies. `S` (functional
  checks) and `Y` (cycles) do transfer cleanly to any language; `C`, `G4`,
  and `G2` do not.
- Separately, the item's own `## Acceptance` names "the project-scaffold
  task," which does not exist in `_eval/suite.tl`'s seven tasks — a sign the
  item's refinement predates or diverges from the suite as it landed.

This does not touch whether peer baselines are worth having — `_perf/baseline.tl`'s
generic `--asset NAME` release pattern is real and reusable for a peer table,
and the sibling cadence/history item (`3IOESaPQ`) is unaffected. The open
question is what "the same scoring" can honestly mean when three of the four
metric columns are cosmic-specific by construction.

## Question

Decide the peer-baseline table's metric shape before `izHf_Yo9h` (or any
successor) is re-specced and pulled again:

- Drop `C`/`G4`/`G2` from the peer table entirely and publish only `S`/`Y`
  (functional correctness + cycles) for peer rows, cosmic keeping all four?
- Redefine `C` as "peer-equivalent static analysis, if any is bundled by
  default" (e.g. Node's `--experimental-strip-types`, none for CPython) and
  accept an honest gap rather than a silent zero?
- Narrow the peer comparison to only the 3 tasks that are `S,C,Y`-scored
  (still hitting the `C` gap) or further to whichever subset is honestly
  comparable?
- Something else the owner decides.

Whichever shape is chosen, the successor item should also correct or drop the
non-existent "project-scaffold task" acceptance criterion.
