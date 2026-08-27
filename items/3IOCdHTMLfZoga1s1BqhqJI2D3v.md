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
- **The seam is two call families, both internal**: the build's
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

## Non-goals

No testrun/report changes (per-test statuses and `--filter`
passthrough are 3IOCdZCA, blocked on this). No tree migration
(3IOCdooE) and no lint retirement (3IOCdvXF). No change to
`cosmic/teal.tl`'s public signatures or to `engine.process_file`
(the strip floor is the wall; the string variants are the doorway).
No host change to honor script chunk returns. `cosmic/test.tl`'s
API is frozen (D29/D20).

## Acceptance

- `bin/cosmic --make ci` ends `ci: PASS`.
- `bin/cosmic --make test _tool/seam_test.tl` passes, including the
  end-to-end child cases (0, nonzero, 2).
- `wc -l _tool/seam.tl` ≤ 500; the two edited files stay ≤ 500.
- `grep -n "os.exit" docs/decisions/d29-tests-run-because-defined.md`
  names the corrected tail bullet.
- Legacy behavior byte-identical: `bin/cosmic --compile
  cosmic/string_test.tl` output unchanged from main (spot diff).

## Enablement

none needed — runner and discovery landed (PRs #1405, and the
discovery extraction), the string-variant seam already exists, and
every fact above was measured in this pass.

## Post-merge review finding

This item was accepted and merged (#1446) at 04:40:57Z while a
review claim taken at 04:38:34Z was still open; that review finished
afterwards and found one gap the accepted diff carries into main.

The `## Evidence` bullet above asserting the seam is "two call
families, both internal" is WRONG. `_make/check.tl:149` calls
`teal.check_file` directly — a third toolchain entry into the
checker, and the one `--make check` uses. In this repo it is
invisible because gate verbs converge, so the build compiles every
test file through the seam and `proved_by_graph` skips them all;
downstream, `--make check` does not converge, and a runner-mode test
file fails with the very uncalled-local warning runner mode exists
to prevent (measured on the merged head: `check: FAIL`, `ci: FAIL
(check)` in a `_make/testdata/hello` copy carrying one runner-mode
file, while build/test/coverage pass).

The fix, the fixture regression that would have caught it, and the
review's smaller findings are 3IU4umVT.
