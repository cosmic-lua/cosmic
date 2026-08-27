## Goal

G5, under the test-runner container (3IOCIBGe, D29): close the
compile seam's third entry so `--make check` checks what runs. D29
promises a runner-mode `*_test.tl` type-checks WITH its generated
tail; today it does on two of three toolchain paths, and the third is
the one every project outside this repo uses. Until this closes, the
migration slices below the container (3IOCdooE especially) would ship
a tree shape that fails a downstream `--make ci`.

## Evidence (measured 2026-08-27 at the review of #1446, merged head 3a04501)

- **The seam #1446 landed covers three call sites**: `_cli/build/
  work.tl` (the build's compile step) and `_cli/main_handlers.tl` ×2
  (`--compile`, `--check types`). Its spec (3IOCdHTM) asserted the
  seam was "two call families, both internal" from a grep over
  `_cli/**` and `cosmic/**`, and that inventory was short.
- **`_make/check.tl:149` is the missed entry**: `check_files` calls
  `teal.check_file(f.path, {include_dirs = include_dirs})` directly,
  so `--make check` — and therefore the `check` stage of `--make ci`
  — type-checks a runner-mode file without its tail.
- **Reproduced downstream, on the merged head**. A copy of
  `_make/testdata/hello` plus one runner-mode file:

  ```
  $ cat runner_test.tl
  --- Probe: runner-mode test file in a downstream project.

  local function test_one()
    assert(1 == 1)
  end

  $ cosmic --make check
  runner_test.tl:3:1: warning: unused function test_one: function()
    hint: warnings are errors here — remove it, or prefix the name
    with `_` …
  check: FAIL (1 of 2 files)

  $ cosmic --make ci
  …
  ci: FAIL (check)
  ```

  `build`, `test` and `coverage` pass on that same tree — only
  `check` fails, and with precisely the uncalled-local warning runner
  mode exists to prevent.
- **Why this repo cannot see it**: gate verbs CONVERGE here, so the
  build compiles every test file through the `work.tl` seam before
  `check` runs, and `proved_by_graph` then skips them all (`check: N
  of N already proved by their strict compile`). `_make/check.tl`'s
  own comment names the exposed case — "a tree that has never built,
  a check running before any graph verb — answers false, and the file
  is checked directly" — which is every fresh downstream checkout.
- **The substitution is the one already applied twice**: `_make/` is
  outside `cosmic/**`, so requiring `_tool.seam` there clears the
  strip floor exactly as `_cli/` does.
- **Capacity**: `wc -l` — `_make/check.tl` 227 (273 headroom),
  `_make/fixtures_test.tl` 197 (303 headroom), `_tool/seam.tl` 85.
- **A fifth entry exists and is NOT this item's**: `cosmic
  foo_test.tl` runs through `cosmic/searcher.tl` →
  `teal.compile_cached` → `compile_file`, so a runner-mode file run
  as a script is a silent no-op exiting 0 where a legacy file runs
  its tests (measured on 3a04501). That is 3IOCdooE's to settle when
  the tree migrates; recorded here so it is not rediscovered.

## Change

1. `_make/check.tl` `check_files`: for each file, `seam.augment(
   f.path)`, then `teal.check(aug.source, {include_dirs =
   include_dirs, chunk_name = f.path})`. A read failure counts as a
   failed file with its error on stderr, matching the other two call
   sites' shape.
2. The regression the string-level unit tests structurally cannot
   catch: a fixture project carrying a runner-mode `*_test.tl`,
   checked from a tree with NO prior build, so a call site that never
   reaches the seam fails a gate instead of waiting for a reviewer.
   `_make/testdata/**` is where such fixtures live and
   `_make/fixtures_test.tl` checks, builds and runs them — add the
   runner-mode file to a fixture there (or a new one) and assert
   `--make check` passes.
3. Correct 3IOCdHTM's inventory claim where it is still load-bearing:
   `_tool/seam.tl`'s header names the callers, and after this there
   are three.

## Non-goals

No change to the direct-script path (`cosmic/searcher.tl` →
`teal.compile_cached`) — that is 3IOCdooE's, per the evidence above.
No tree migration, no lint retirement, no testrun/report change. No
change to `cosmic/teal.tl`'s public signatures or to
`engine.process_file`: the strip floor is the wall and the string
variants are the doorway, exactly as 3IOCdHTM settled. `_tool/
seam.tl`'s `augment` contract is unchanged.

## Acceptance

- `bin/cosmic --make ci` ends `ci: PASS`.
- **The downstream check passes with no prior build**: from a fresh
  copy of the fixture carrying the runner-mode test file, in a
  directory with no `o/`, `o/bin/cosmic --make check` ends `check:
  PASS` and `o/bin/cosmic --make ci` ends `ci: PASS`. This is the
  command that fails on the merged head, so it is the one that
  proves the fix.
- `bin/cosmic --make test _make/fixtures_test.tl` passes.
- `wc -l _make/check.tl` ≤ 500.

## Enablement

The ready-bar gap that produced this item, so the next seam spec does
not repeat it: 3IOCdHTM's evidence asserted "two call families, both
internal" from a grep scoped to two directories. A claim about how
many call sites a seam has is a claim about the WHOLE tree, so it is
measured tree-wide or not made — `grep -rn "compile_file\|check_file\
|compile_cached" --include=*.tl .` names every entry at once. Change
item 2 is the standing countermeasure: with a fixture that checks a
runner-mode file from an unbuilt tree, a missed call site fails a
gate rather than surviving a review.

## Smaller findings from the same review (fold in here or drop)

- `Augmented.mode` has no reader. 3IOCdHTM asked for it so callers
  could refuse `mixed` with the lint's message shape, and none does —
  wire it up or drop the field.
- `augment` returns `mode = "empty"` for a non-test path, pinned at
  `_tool/seam_test.tl:54`. `empty` already means "a test file with no
  `test_*` definitions"; a non-test path is a different fact, and the
  first consumer of `mode` will read the conflation as a bug.
- `_cli/build/work.tl`'s comment above `compile_in_process` still
  says "Same compile a spawned bootstrap would run
  (teal.compile_file, strict)". It is `teal.compile` through the seam
  now.
- `lines_of` in `_tool/seam.tl` duplicates `_cli/lint.tl:305-308`
  byte for byte, and both exist only to feed `discover.discover`. The
  splitter belongs in `_tool/discover.tl`, with both callers using
  it.
