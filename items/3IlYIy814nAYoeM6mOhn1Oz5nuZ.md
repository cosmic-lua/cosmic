## Evidence

Reported independently by three builders of 3IQfJ1tn's children
(2026-09-02, cosmic-lua/cosmic#1630, #1631, #1632), all of whom
re-ran the census Method in `docs/design/nil-flow.md` `## Method`:

- The proof-of-life probe it names —
  `cosmic/teal_narrowing_test.tl`'s
  `test_nil_union_is_admitted_outside_an_index` — exists in no commit
  (`git log -S` over the file is empty; the file's nine tests are
  narrowing/typevar cases that pass under the strict binary). One
  builder found the intended probe in `cosmic/teal_nilflow_test.tl`.
- "Run the file directly" cannot prove anything for a runner-mode
  test: `o/bin/cosmic <file>_test.tl` defines the `test_*` functions
  and calls none (D29), so a direct run exits 0 regardless of the
  checker; the compiled `o/<file>.lua` carries the seam's calls.
- Running a compiled test directly with no `TEST_TMPDIR` writes its
  fixtures (`narrow_*.tl`) into the cwd; at the repo root the next
  `--make build` picks them up as project sources and fails.
- The whole-tree `xargs o/bin/cosmic --check types` scan prints every
  `cosmic/` diagnostic twice; `sort -u` reproduces the recorded
  counts. tl reports only the first failing argument of a call, so
  the probe's `argument 2` line never appears (five of six lines).

Every other step of the recipe (the two hinges, lax-builds-strict
order, scan filter) reproduced the census exactly.

## Change

`docs/design/nil-flow.md` `## Method`: point the proof-of-life at the
probe that exists (`cosmic/teal_nilflow_test.tl`, naming the test),
say to run the compiled `o/<file>.lua` under `TEST_TMPDIR`, note the
`sort -u` and first-argument-only facts, and carry the lax/strict
recipe recorded in 3IQfJ1tn's `## Enablement` so the doc is the one
place the recipe lives. Prose only; the `.tsv` is untouched.

## Non-goals

- No checker change; no census re-run; no `.tsv` edit.
