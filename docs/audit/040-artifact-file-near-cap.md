# 040 — `_make/artifact.tl` is 464/500 lines; the next feature forces a split

severity: medium (maintainability cliff, not a defect)
type: design / maintainability
area: `_make/artifact.tl`, neighbors near the cap

## issue

the repo's 500-line cap is a hard gate (`bin/make lint`, no exceptions
for `.tl`). `_make/artifact.tl` is at **464** after 4a15b92 added
`generate`/`collision` — 36 lines of headroom. the module already does
six jobs: `scope_of`, `plan`, `collision`, `stage`, `base_of`,
`generate`, plus `build` orchestrating them. the open audit items most
likely to land next (026's fixpoint lane may need hooks here; item 9's
`.cosmicignore` work; any payload change) all touch this file.

a split made *under* cap pressure gets drawn wherever the line count
falls; a split made now gets drawn on the seams the code already has.
splitting when forced is how modules end up as `artifact2.tl`.

watch items in the same band: `_make/pin_test.tl` 460, `_make/project.tl`
423, `_make/artifact_test.tl` 439, `_make/build_test.tl` 431 — the cap
applies to tests too.

## where

- `wc -l _make/artifact.tl` → 464 at 4a15b92.

## suggested fix

split along the phase boundary the code and its comments already draw:

- `_make/generate.tl` — `generate_unit` + `generate` (the "phase over
  the project"; it is already invoked from `init.run_graph` separately
  from `build`, so the seam is real, not invented).
- `_make/artifact.tl` keeps the staging half: `scope_of`, `plan`,
  `collision`, `stage`, `base_of`, `build`.

that is ~70 lines out, restoring real headroom, and the module boundary
matches the runtime boundary (`generate` runs once per project;
everything else runs per binary). do it as its own commit — the repo's
convention for moves — before the next feature lands here.
