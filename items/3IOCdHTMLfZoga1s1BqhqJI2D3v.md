## Goal

G5, under the test-runner container (3IOCIBGe, D29): the compile seam
— a runner-mode `*_test.tl` gets the toolchain-generated tail in the
source fed to BOTH the strict type check and the compiler, so a
runner-mode file builds and runs end to end under `--make test`.
Unblocks the migration chain (3IOCdooE, 3IOCdZCA, 3IOCdvXF).

## Evidence (measured 2026-08-27 at this refinement, main post-#1437)

- **The pieces stand**: `cosmic/test.tl` (the runner, PR #1405,
  public API per D29) and `_tool/discover.tl` (the classifying walk:
  `discover(file, content, lines) → {mode, cases}`, modes
  legacy/runner/mixed/empty, token-exact, case order = source order).
- **The seam is two call families, both internal** — WRONG, and the
  review of #1446 measured why; read the `## Evidence added at
  review` section below before trusting this bullet's inventory. Its
  reasoning about WHERE the injection may live still holds: the
  build's
  compile (`_cli/build/work.tl:204`, `tealc.compile_file`) and the
  CLI's `--compile`/`--check types`
  (`_cli/main_handlers.tl:115,225`). `cosmic/teal.tl`'s
  `compile_file`/`check_file` read bytes via
  `engine.process_file` (`cosmic/_teal_engine.tl:267-276`), which is
  under `cosmic/**` — and the STRIP FLOOR forbids a `cosmic/**`
  module requiring `_tool.discover`, so the injection cannot live in
  the engine or `cosmic/teal.tl` unless discovery moves under
  `cosmic/**`. DECISION: keep discovery internal and inject at the
  string seam — `teal.compile(source, …)` / `teal.check(source, …)`
  already exist beside the `_file` variants, so an internal caller
  reads the file, asks discover, appends the tail, and hands the
  STRING to the same strict pipeline (`chunk_name` carries the real
  path for error attribution). One new internal helper owns that
  read-discover-append step so the build and the CLI share it:
  `_tool/seam.tl` (new, ~60 lines), `augment(path) → source, Mode`.
- **The tail spelling D29 wrote does not exit**: measured — a script
  chunk's return value is DISCARDED by the script host (`echo
  'return 3' > ret3.lua; o/bin/cosmic ret3.lua; echo $?` → 0), so
  `return require("cosmic.test").main({...})` cannot deliver the
  0/2/fail grammar under `_tool/testrun.tl`, which reads the CHILD
  EXIT of the compiled `o/…_test.lua` (`testrun.tl:95-101`). Making
  the host honor integer chunk returns is wrong (a dual-use script's
  `return {mod}` would become an exit), so the tail is
  `os.exit(require("cosmic.test").main({...}))` — a process boundary
  in generated source the tree never contains (fmt/lint never see
  it; D30's process-boundary licence, and the exits-comment grammar
  does not apply to generated text). This needs a one-line
  "correct"-class edit to D29's tail spelling
  (`docs/decisions/d29-tests-run-because-defined.md`, the
  "invocation is a toolchain-generated in-chunk tail" bullet), in
  this slice: the record asserted a host behavior that does not
  exist.
- **Appending changes no line number** (D29): the tail joins with a
  preceding newline; `discover` line numbers and checker diagnostics
  stay source-true. The checker sees the same augmented string, so
  warnings-as-errors holds with no uncalled-local warning.
- **Caches stay content-keyed and correct**: the tail is a pure
  function of the file's bytes (discover reads only content), so the
  batch's content-keyed `.in` records and `compile_cached` keys need
  no new inputs. `compile-batch` members go through the same
  work.tl call being changed.
- **Capacity**: `wc -l` — `_cli/build/work.tl` 395 (105 headroom),
  `_cli/main_handlers.tl` 429 (71 headroom), so the shared helper
  lives in the new `_tool/seam.tl`, not inline. `_tool/discover.tl`
  173.

## Evidence added at review of #1446 (measured 2026-08-27, head 3a04501)

- **The seam inventory above was short by one: `--make check`.**
  `_make/check.tl:149` calls `teal.check_file(f.path, …)` directly —
  a FOURTH toolchain entry into the checker, missed because the
  inventory grepped `_cli/**` and `cosmic/**` only. Measured on
  #1446's head: a stock `_make/testdata/hello` fixture plus one
  runner-mode `runner_test.tl` gives `cosmic --make check` →
  `runner_test.tl:3:1: warning: unused function test_one` and
  `check: FAIL (1 of 2 files)`, so `cosmic --make ci` → `ci: FAIL
  (check)`, while `build`, `test` and `coverage` pass on the same
  tree. That is exactly the uncalled-local warning runner mode
  exists to prevent.
- **Why this repo cannot see it**: gate verbs CONVERGE here, so the
  build compiles every test file through the `work.tl` seam before
  `check` runs and `proved_by_graph` skips them all (`check: N of N
  already proved by their strict compile`). `_make/check.tl`'s own
  comment names the exposed case — "a tree that has never built, a
  check running before any graph verb — answers false, and the file
  is checked directly" — which is every downstream project, where
  `--make check` does not converge.
- **The direct-script path is a fifth entry, and is out of scope**:
  `cosmic foo_test.tl` runs through `cosmic/searcher.tl` →
  `teal.compile_cached` → `compile_file`, so a runner-mode file run
  that way is a silent no-op exiting 0 where a legacy file runs its
  tests (measured on 3a04501). Harmless until the tree migrates;
  it belongs to 3IOCdooE, and this spec names it a non-goal below
  so the decision is recorded rather than rediscovered.

## Change

1. `_tool/seam.tl` (new): `augment(path: string): string | nil,
   string` — read the file; not a `*_test.tl` or mode ~= "runner" →
   return the bytes unchanged; runner mode → append
   `\nos.exit(require("cosmic.test").main({\n  {name = "test_x", fn = test_x},\n  …\n}))\n`
   with the case list in source order (match `cosmic/test.tl`
   `main`'s Case shape — read it and use its exact field names).
   Also export the discovery verdict so callers can refuse "mixed"
   with the lint's message shape. Unit tests in `_tool/seam_test.tl`:
   legacy unchanged byte-for-byte; runner gains exactly the tail and
   no line number moves (compare `#lines`); mixed reported; a
   non-test path untouched.
2. `_cli/build/work.tl:204` region: for `*_test.tl` sources, call the
   helper and hand the augmented STRING to `tealc.compile` with
   `chunk_name = src` (the strict path already exists); other files
   keep `compile_file`.
3. `_cli/main_handlers.tl:115,225`: same substitution for `--compile`
   and `--check types` on `*_test.tl` arguments, so the checker
   checks what runs.
4. `docs/decisions/d29-tests-run-because-defined.md`: the tail bullet's
   spelling becomes the `os.exit(...)` form with the measured host
   fact in one clause (correct class: edit in place, no status
   change).
5. End-to-end fixture: a runner-mode test file in the tree is
   premature (the migration is 3IOCdooE); instead
   `_tool/seam_test.tl` compiles its runner-mode fixture STRING via
   `cosmic.teal.compile` and runs the chunk under `cosmic.child`
   (the binary + a temp .lua), asserting exit 0 on a passing pair,
   nonzero on a failing one, and 2 on empty — the 0/2/fail grammar
   through the REAL host.
6. `_make/check.tl:149` (`check_files`): the same substitution —
   `seam.augment(f.path)`, then `teal.check(aug.source,
   {include_dirs = include_dirs, chunk_name = f.path})`, with the
   read failure reported as a check failure on that file. `_make/`
   is outside `cosmic/**`, so requiring `_tool.seam` there clears the
   strip floor exactly as `_cli/` does. Capacity at review: `wc -l
   _make/check.tl` 227 (273 headroom), `_make/fixtures_test.tl` 197
   (303 headroom).
7. The regression the string-level unit tests structurally cannot
   catch: a fixture project carrying a runner-mode `*_test.tl`,
   checked and built from a tree with NO prior build, so a call site
   that never reaches the seam fails loudly. `_make/testdata/**` is
   where such fixtures live and `_make/fixtures_test.tl` is what
   checks, builds and runs them — add the runner-mode file to a
   fixture there (or a new one) and assert `--make check` passes.
8. Housekeeping the review named, all inside files this slice already
   touches: `Augmented.mode` gains its intended reader (a caller that
   refuses `mixed` with the lint's message shape) or the field goes;
   a non-test path stops being reported as `"empty"`, which already
   means "a test file with no `test_*` definitions"; `_cli/build/
   work.tl`'s comment above `compile_in_process` stops naming
   `teal.compile_file`; and `lines_of` stops being a byte-for-byte
   copy of `_cli/lint.tl:305-308` — both exist only to feed
   `discover.discover`, so the splitter moves into `_tool/
   discover.tl` and both callers use it.

## Non-goals

No testrun/report changes (per-test statuses and `--filter`
passthrough are 3IOCdZCA, blocked on this). No tree migration
(3IOCdooE) and no lint retirement (3IOCdvXF). No change to
`cosmic/teal.tl`'s public signatures or to `engine.process_file`
(the strip floor is the wall; the string variants are the doorway).
No host change to honor script chunk returns. `cosmic/test.tl`'s
API is frozen (D29/D20). No change to the direct-script path
(`cosmic/searcher.tl` → `teal.compile_cached`): running a test file
as a script is 3IOCdooE's to settle when the tree migrates, and the
evidence above records what it will find.

## Acceptance

- `bin/cosmic --make ci` ends `ci: PASS`.
- `bin/cosmic --make test _tool/seam_test.tl` passes, including the
  end-to-end child cases (0, nonzero, 2).
- `wc -l _tool/seam.tl` ≤ 500; every edited file stays ≤ 500.
- `grep -n "os.exit" docs/decisions/d29-tests-run-because-defined.md`
  names the corrected tail bullet.
- Legacy behavior byte-identical: `bin/cosmic --compile
  cosmic/string_test.tl` output unchanged from main (spot diff).
- **The downstream check passes with no prior build**: from a fresh
  copy of the fixture carrying the runner-mode test file, in a
  directory with no `o/`, `o/bin/cosmic --make check` ends `check:
  PASS` and `o/bin/cosmic --make ci` ends `ci: PASS`. This is the
  command that fails on #1446's head, so it is the one that proves
  the fix.
- `bin/cosmic --make test _make/fixtures_test.tl` passes.

## Enablement

The ready-bar gap this item's first pass hit, recorded so the
re-refinement does not repeat it: the `## Evidence` seam inventory
was assembled by grepping `_cli/**` and `cosmic/**` and asserted
"two call families, both internal" without a command that would
have found a third. A claim about how many call sites a seam has is
a claim about the WHOLE tree, so it is measured tree-wide or not
made — here, `grep -rn "compile_file\|check_file\|compile_cached"
--include=*.tl .` names all five entries at once
(`_cli/build/work.tl`, `_cli/main_handlers.tl` ×2, `_make/check.tl`,
`cosmic/_script_cache.tl`), and item 7's fixture is the standing
countermeasure: a call site that never reaches the seam fails a
gate instead of waiting for a reviewer.

Otherwise as before — runner and discovery landed (PRs #1405, and the
discovery extraction), the string-variant seam already exists, and
every fact above was measured in this pass.
