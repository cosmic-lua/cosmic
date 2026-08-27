## Goal

G4, under the tree-migration container (3IOCdooE): batch 2 of seven —
the dispatcher and the build system lose their test self-call lines, so
those files run because the toolchain found their cases (D29). The
container's spec carries the facts every batch shares; this one names
the scope.

## Evidence (re-measured 2026-08-27 against origin/main at 267c2a4d)

- **Scope**: `_cli/`, `_make/` — `*_test.tl` files, **`*/testdata/*`
  excluded**, and **`_cli/citations_test.tl` excluded** (see below).
  Testdata fixtures are other tests' inputs under their own roots and
  are never run by this repo's `--make test`; the raw grep also matches
  `_make/testdata/assets/note_test.tl`, and touching it is out of scope.

- **49 files carrying 482 column-1 matches**, counted with the same
  pattern the edit deletes:

  ```
  grep -rln '^test_[A-Za-z0-9_]*()$' --include='*_test.tl' _cli _make | grep -v /testdata/ | xargs grep -hc '^test_[A-Za-z0-9_]*()$' | paste -sd+ | bc
  ```

  Re-run at pull; the tree grows, so treat a moved number as detail
  drift and refresh the line rather than bouncing.

- **One of those 482 lines is string content, not code.**
  `_make/resolution_test.tl` embeds a legacy-shaped fixture test inside
  a `[[...]]` long bracket (lines 79-82 on `267c2a4d`: `local function
  test_source()` … `test_source()`, both at column 1 because the
  bracket's content is unindented). A blind `sed` deletes line 82 and
  silently rewrites that fixture, which
  `test_a_test_loads_what_the_graph_built` then writes to disk and
  builds. So the mechanical edit skips `_make/resolution_test.tl`, and
  that file's TEN real self-call lines are deleted by hand
  (`test_a_test_loads_what_the_graph_built`,
  `test_run_resolves_a_computed_require`,
  `test_run_passes_argv_and_exit_code_through`,
  `test_run_refuses_a_binary_name`, `test_resolution_does_not_inherit`,
  `test_run_in_process`, `test_run_refusals_in_process`,
  `test_run_builds_a_target_with_no_binary`,
  `test_run_reports_a_binaryless_build_failure`,
  `test_run_passes_stdin_through`), leaving line 82 untouched. It is the
  only in-string match in scope, found with a long-bracket scan over the
  49 files:

  ```
  for f in $(grep -rln '^test_[A-Za-z0-9_]*()$' --include='*_test.tl' _cli _make | grep -v /testdata/); do awk -v F="$f" '/\[\[/ && !/\]\]/ {inb=1} /\]\]/ {if (inb) {inb=0; next}} inb && /^(local function )?test_[A-Za-z0-9_]*\(/ {print F ":" NR ": " $0}' "$f"; done
  ```

  → exactly `_make/resolution_test.tl:79` and `:82`, nothing else.

- **`_cli/citations_test.tl` is carved out of this batch and owned by
  3IVAhnTj.** It captures the cwd at module scope, chdirs into a
  fixture, and restores on its LAST line (`assert(fs.set_cwd(ORIGINAL),
  "restore the original cwd")`). The seam appends the runner tail after
  that line, so the restore runs before any case does and the cases read
  the wrong cwd. Measured: applying the deletion to that file too and
  running the scope gives `test: FAIL (1 of 49 files)` with
  `14 checks: 7 passed, 7 failed`. Repairing it needs a comment rewrite
  and an EOF fixup, which is not a deletion, so it is its own item.
  Its 14 self-call lines stay.

- **Batch scope after both carve-outs: 48 files, 467 real self-call
  lines** — 457 deleted mechanically across 47 files, plus
  `_make/resolution_test.tl`'s 10 by hand.

- **No test is lost.** `_tool/discover` totals **481 cases** over the 49
  in-scope files both before and after the edit, with exactly one
  definition-count mismatch either way — `_make/resolution_test.tl`, 11
  naive `^local function test_` hits vs 10 cases, the string phantom
  above (a naive grep cannot see strings; discover, a real lexer, can).
  After the edit the mode census is `runner = 48, legacy = 1`, the one
  legacy file being `_cli/citations_test.tl`. Probe, run from the repo
  root and kept OUT of the tree (a `*.tl` inside it joins the build
  graph) as `o/bin/cosmic /tmp/probe.lua`:

  ```lua
  local discover = require("_tool.discover")
  local fs = require("cosmic.fs")
  local bad, total = 0, 0
  for _, tree in ipairs({"_cli", "_make"}) do
    for _, path in ipairs(assert(fs.find(tree, {glob = "*_test.tl"}))) do
      if not path:find("/testdata/", 1, true) then
        local content = assert(fs.read(path))
        local lines, defs = {}, 0
        for line in (content .. "\n"):gmatch("(.-)\n") do
          lines[#lines + 1] = line
          if line:match("^local function test_[A-Za-z0-9_]*%(") then defs = defs + 1 end
        end
        local d = discover.discover(path, content, lines)
        total = total + #d.cases
        if #d.cases ~= defs then
          bad = bad + 1
          print(("MISMATCH %s: %d definitions, discover found %d (%s)"):format(path, defs, #d.cases, d.mode))
        end
      end
    end
  end
  print(total .. " cases, " .. bad .. " mismatches")
  ```

- **No pin bump is needed; the cold-build rule is satisfied.** The
  pinned release is `2026-08-27-555873e` (`bin/cosmic.pin` on
  `267c2a4d`, landed as #1457), and it carries both the D29 seam and
  #1455's discover extent fix. Measured on a scratch mirror carrying
  this batch's edit, with the pinned bootstrap and the generated types,
  which is `_build/coldbuild_test.tl`'s own instrument:

  ```
  COSMIC_COVERAGE=0 o/bootstrap/cosmic --check types --include-dir . --include-dir o/_types/types_gen <every .tl under 3p _build _cli _docs _eval _fuzz _make _perf _tool _types cmd cosmic, testdata excluded>
  ```

  → 549 files, exit `0`, no diagnostics; `_build/coldbuild_test.tl`
  itself also passes inside the gate run below. The check is not
  vacuous: the same 48 migrated files copied to a `_probe.tl` suffix (so
  the seam does not apply) fail the same command with exactly 467
  `warning: unused function test_…` diagnostics, one per deleted line,
  and the same command over batch 3's scope under the PREVIOUS pin
  `2026-08-27-cb39b65` failed on three such warnings.

- **The whole edit is gate-clean, run end to end on the mirror**:
  `ci: PASS (5 stages)` — `fmt: PASS (549 files)`,
  `check: PASS (549 files)`, `example: PASS (35 files)`,
  `lint: PASS (649 files)`, `coverage: PASS (251 files)`. Deleting a
  call line leaves the blank line that followed it, so no reflow rides
  along.

## Change

In every `*_test.tl` under this batch's scope — testdata excluded,
`_make/resolution_test.tl` and `_cli/citations_test.tl` excluded —
delete each line matching exactly `^test_[A-Za-z0-9_]*()$`: a bare call
at column 1, no arguments. Then hand-edit `_make/resolution_test.tl`:
delete its ten real self-call lines (named in Evidence), leaving the
`test_source()` line inside the long bracket untouched. Nothing else
changes in those files, and no file outside the scope is touched.

The mechanical half, run from the repo root and kept OUT of the tree (a
`*.tl` inside it joins the build graph):

```
grep -rln '^test_[A-Za-z0-9_]*()$' --include='*_test.tl' _cli _make | grep -v /testdata/ | grep -v '^_make/resolution_test\.tl$' | grep -v '^_cli/citations_test\.tl$' | xargs sed -i -E '/^test_[A-Za-z0-9_]*\(\)$/d'
```

If a ratchet gate complains, run exactly the regen command its failure
message prints and commit the result — never weaken a gate another way.

## Non-goals

No semantic edits ride along: no renames, no assertion changes, no test
added or removed, no reflow, no comment rewrites. The 23 trailing
`print("all … tests passed")` lines in scope now print before the cases
run rather than after; they are not this batch's to touch — leave them
exactly as they are. No `*/testdata/*` file — fixtures belong to the
tests that read them, and `_make/testdata/assets/note_test.tl` is one.
No `_cli/citations_test.tl` — 3IVAhnTj owns it, and folding its fix in
would put insertions into a deletions-only diff. No file outside this
batch's scope — the other six batches are file-disjoint on purpose. No
change to `cosmic/test.tl`, `_tool/seam.tl`, `_tool/discover.tl`, or the
`call-after-define` lint (retiring it is 3IOCdvXF; it already passes on
a runner-mode file). No testrun or report change (3IOCdZCA, landed). No
pin bump — 3IU62YqO landed as #1450 and 3IUJSV7e as #1457.

## Acceptance

- `bin/cosmic --make ci` ends `ci: PASS`.
- **Exactly the two known matches survive in scope**, and the file
  selection is checked non-empty first so an empty selection is a bug
  rather than a pass:
  `grep -rln '^test_[A-Za-z0-9_]*()$' --include='*_test.tl' _cli _make | grep -v /testdata/`
  names 2 files, and
  `grep -rn '^test_[A-Za-z0-9_]*()$' --include='*_test.tl' _cli _make | grep -v /testdata/ | wc -l`
  → `15`: `_cli/citations_test.tl`'s 14 (carved out, 3IVAhnTj) and
  `_make/resolution_test.tl:82` (string content). Today the same two
  commands give 49 files and `482`.
- **No test lost**: the probe in Evidence, run as
  `o/bin/cosmic /tmp/probe.lua` from the repo root, prints
  `481 cases, 1 mismatches` and names only
  `_make/resolution_test.tl: 11 definitions, discover found 10
  (runner)` — the same total and the same single mismatch it prints
  against `origin/main` today, where the mode reads `(legacy)`. This is
  the equality whose absence bounced batch 1's first implementation: a
  definition discover cannot see becomes dead code, and
  warnings-are-errors only catches the unreferenced ones.
- The diff is deletions only:
  `git diff origin/main --numstat -- '*_test.tl' | awk '{a+=$1} END {print a+0}'`
  → `0` insertions, and
  `git diff origin/main --numstat -- '*_test.tl' | awk '{d+=$2} END {print d+0}'`
  → `467` deletions.
- **The run counts the same tests it counted before.**
  `bin/cosmic --make test _cli _make` ends `test: PASS (49 files)` over
  `49 checks: 48 passed, 1 skipped` and prints the per-test totals line
  `455 tests: 455 passed`. The line is `_tool/records.tl`'s
  `test_counts`, landed with #1456, and it appears only for runner-mode
  children — today this scope prints no such line at all. The 455 is
  481 real cases minus three files whose statuses the report cannot
  carry: `_cli/citations_test.tl` (14, still legacy),
  `_make/fixpoint_test.tl` (2, skipped — it exits `check.EXIT_SKIP`
  unless `COSMIC_FIXPOINT=1`), and `_make/resolution_test.tl` (11,
  where `_tool/testrun.tl`'s naive `^local function (test_[%w_]+)`
  source scan yields 11 names against the runner's 10 real cases, so
  `records.parse_cases` refuses the file and testrun falls back to
  writing names only — a REPORTING artifact, not a lost test, exactly
  as batch 1 records for `_tool/seam_test.tl`).

## Enablement

none needed. Measured rather than assumed, because this is the claim
that changed since the item was written: the pinned release is now
`2026-08-27-555873e`, which carries the D29 seam AND #1455's discover
extent fix, and the whole batch type-checks clean under it (see the
cold-build measurement in Evidence). Both recorded blockers have landed
— 3IU62YqO as #1450, 3IUJSV7e as #1457 — and 3IU4umVT (`--make check`
misses the compile seam) cannot reach this batch for the three reasons
batch 1's spec measures: `check` is a gate verb so it always builds
first and `proved_by_graph` skips kind-`test` files, the other cold path
`--check types` IS a seam site, and `testdata/` is outside every gate's
reach. The one remaining shape hazard in scope, the cwd bracket, is
carved out as 3IVAhnTj rather than left for the builder to discover.
