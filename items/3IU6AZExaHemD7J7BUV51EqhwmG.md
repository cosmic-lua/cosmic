## Goal

G4, under the tree-migration container (3IOCdooE): batch 1 of seven —
the internal trees except _cli and _make lose their test self-call lines, so those files run because
the toolchain found their cases (D29). The container's spec carries the
facts every batch shares; this one names the scope.

## Evidence (re-measured 2026-08-27 against origin/main at 555873eb)

- **Scope**: `_build/`, `_docs/`, `_types/`, `3p/`, `_fuzz/`, `_eval/`,
  `_perf/`, `_tool/` — `*_test.tl` files, **`*/testdata/*` excluded**.
  Testdata fixtures are other tests' inputs, live under their own
  roots, and are never run by this repo's `--make test`; the raw grep
  currently also matches 9 `_eval/testdata/**` files, and touching
  them is out of scope.
- **65 files carrying 479 column-1 self-call lines**, counted with:

  ```
  grep -rln '^test_[A-Za-z0-9_]*()$' --include='*_test.tl' _build _docs _types 3p _fuzz _eval _perf _tool | grep -v /testdata/ | xargs grep -hc '^test_[A-Za-z0-9_]*()$' | paste -sd+ | bc
  ```

  Re-run at pull; the tree grows, so treat a moved number as detail
  drift and refresh the line rather than bouncing.
- **One of those 479 lines is string content, not code**:
  `_tool/seam_test.tl` embeds legacy-shaped source in long-bracket
  fixtures (`LEGACY_SRC`'s `test_addition()` sits at column 1 inside
  `[[...]]`). A blind `sed` would delete it and flip that fixture out
  of legacy mode, failing `test_other_shapes_pass_through_byte_identical`.
  So the mechanical edit skips `_tool/seam_test.tl`, and that file's
  four REAL self-calls (`test_other_shapes_pass_through_byte_identical`,
  `test_runner_mode_gains_the_tail_below_the_source`,
  `test_the_augmented_source_checks_strictly`,
  `test_the_tail_delivers_the_exit_grammar`) are deleted by hand.
  478 real self-calls total.
- **Discover finds every real definition in scope** — the equality the
  first implementation bounced on, now measured directly: for each of
  the 65 files, `_tool/discover`'s case count equals the file's count
  of column-1 `local function test_*(` lines, with exactly one
  reported mismatch — `_tool/seam_test.tl`, 8 grep hits vs 4 cases —
  and inspection shows all 4 extra grep hits are the same long-bracket
  fixtures (naive grep cannot see strings; discover, a real lexer,
  can). Probe, run from the repo root with the script kept OUT of the
  tree:

  ```lua
  -- o/bin/cosmic /tmp/probe.lua
  local discover = require("_tool.discover")
  local fs = require("cosmic.fs")
  local trees = {"_build", "_docs", "_types", "3p", "_fuzz", "_eval", "_perf", "_tool"}
  local bad = 0
  for _, tree in ipairs(trees) do
    for _, path in ipairs(assert(fs.find(tree, {glob = "*_test.tl"}))) do
      if not path:find("/testdata/", 1, true) then
        local content = assert(fs.read(path))
        local lines, defs = {}, 0
        for line in (content .. "\n"):gmatch("(.-)\n") do
          lines[#lines + 1] = line
          if line:match("^local function test_[A-Za-z0-9_]*%(") then defs = defs + 1 end
        end
        local d = discover.discover(path, content, lines)
        if #d.cases ~= defs then
          bad = bad + 1
          print(("MISMATCH %s: %d definitions, discover found %d"):format(path, defs, #d.cases))
        end
      end
    end
  end
  print(bad .. " mismatches")
  ```

  Measured: `MISMATCH _tool/seam_test.tl: 8 definitions, discover
  found 4` (the string phantoms above), `1 mismatches`, nothing else.
  The blocker that made this false is fixed: 3IP9ijhv landed as #1455
  (`2724a719`, "read a definition's extent from the parser, not a
  depth count"), and the pinned checker `2026-08-27-cb39b65` carries
  the D29 seam.
- **The deletion is fmt-, check- and lint-clean**: trialled on
  `_build/**` (12 files, 43 lines) — `fmt: PASS`, `check: PASS`,
  `lint: PASS`. Deleting the call line leaves the blank line that
  followed it, so no reflow rides along.

## Change

In every `*_test.tl` under this batch's scope — testdata excluded,
`_tool/seam_test.tl` excluded — delete each line matching exactly
`^test_[A-Za-z0-9_]*()$`: a bare call at column 1, no arguments.
Then hand-edit `_tool/seam_test.tl`: delete its four real self-call
lines (named in Evidence), leaving the `test_addition()` line inside
`LEGACY_SRC`'s long bracket untouched. Nothing else changes in those
files, and no file outside the scope is touched.

The mechanical half, run from the repo root and kept OUT of the tree
(a `*.tl` inside it joins the build graph):

```
grep -rln '^test_[A-Za-z0-9_]*()$' --include='*_test.tl' _build _docs _types 3p _fuzz _eval _perf _tool | grep -v /testdata/ | grep -v '^_tool/seam_test.tl$' | xargs sed -i -E '/^test_[A-Za-z0-9_]*\(\)$/d'
```

If a ratchet gate complains, run exactly the regen command its failure
message prints and commit the result — never weaken a gate another
way.

## Non-goals

No semantic edits ride along: no renames, no assertion changes, no
test added or removed, no reflow, no comment rewrites. No
`*/testdata/*` file — fixtures belong to the tests that read them. No
file outside this batch's scope — the other six batches are
file-disjoint on purpose. No change to `cosmic/test.tl`,
`_tool/seam.tl`, `_tool/discover.tl`, or the `call-after-define` lint
(retiring it is 3IOCdvXF; it already passes on a runner-mode file).
No testrun or report change (3IOCdZCA, landed). No pin bump —
3IU62YqO landed as #1450.

## Acceptance

- `bin/cosmic --make ci` ends `ci: PASS`.
- **No test lost**: for every file in scope, discover on the migrated
  file reports `mode = "runner"` and the SAME case list, name for
  name, as discover on the file at `origin/main` — a probe script
  (out of tree) diffing `discover(git show origin/main:<path>)`
  against `discover(<worktree path>)` prints zero differences over
  the 65 files. This is the equality whose absence bounced the first
  implementation: a definition discover cannot see becomes dead code,
  and warnings-are-errors only catches the unreferenced ones.
- The one surviving column-1 self-call in scope is string content:
  `grep -rn '^test_[A-Za-z0-9_]*()$' --include='*_test.tl' _build _docs _types 3p _fuzz _eval _perf _tool | grep -v /testdata/`
  prints exactly one line — `_tool/seam_test.tl`'s in-fixture
  `test_addition()` — and the file selection is checked non-empty
  before the grep, so an empty selection is a bug, not a pass.
- The diff is deletions only:
  `git diff origin/main --numstat -- '*_test.tl' | awk '{a+=$1} END {print a+0}'`
  → `0` insertions.
- `bin/cosmic --make test` passes, and its summary still reports the
  same number of test files as before the edit.

## Enablement

none needed — both blockers cleared. 3IU62YqO landed as #1450
(`bin/cosmic.pin` names `2026-08-27-cb39b65`, whose checker carries
the D29 seam). 3IP9ijhv landed as #1455 (`2724a719`): discover reads
a definition's extent from the parser, so the under-count that
bounced the first implementation is gone — re-measured above with
zero unexplained mismatches in scope.

## Bounced at implementation, 2026-08-27T05:3xZ — discover under-counts

The deletion was applied exactly as `## Change` specified (73 files,
481 lines, 0 insertions, 0 surviving self-calls) and `--make ci`
failed the build:

```
_types/tlast_test.tl:39:1: warning: unused function
  test_cache_thaws_on_fresh_tl: function()
build: FAIL (545 files)
ci: FAIL (build failed)
```

**The wrong turn was in this spec's evidence, not in the edit.** The
container's probe asserted "every file in scope reaches runner mode"
and checked `discover`'s MODE. It never checked that discover found
every `test_*` DEFINITION in the file. At the time it did not:
`_tool/discover.tl`'s `end_line_of` returned nil when the depth walk
lost the closer — a `function` token in TYPE position opens no block
and has no `end` — and such a definition was SKIPPED rather than
judged. 10 files tree-wide under-counted, 17 definitions invisible to
the seam.

**Resolved by re-refinement, 2026-08-27T06:4xZ**: 3IP9ijhv (the
counter fix) was raised to a blocker edge on this item and has landed
as #1455; the Evidence above now carries the definition-equality
probe and its measured answer, and the Acceptance carries the
name-for-name case-list equality across the batch, so a counter
regression cannot land a silent test loss. Re-measurement also caught
two scope traps the original Change would have hit: the raw grep now
selects 9 `_eval/testdata/**` fixtures (excluded — fixtures are other
tests' inputs), and `_tool/seam_test.tl` keeps one column-1 self-call
inside a long-bracket fixture that a blind sed would have deleted
(that file is hand-edited instead).

## Bounced at implementation, 2026-08-27T06:5xZ — the PINNED discover is the wall now

The re-refined Change was applied exactly as specified (65 files, 478
deletions, 0 insertions, the one in-fixture survivor intact) and every
acceptance probe passed except one: the no-test-lost probe reported
`65 files, 0 differences`, `--make test` passed, but `--make ci`
failed `_build/coldbuild_test.tl`:

```
_types/tlast_test.tl:39:1: warning: unused function test_cache_thaws_on_fresh_tl
coverage: FAIL (1 of 251 files)
```

The Evidence's equality probe ran the TREE's discover (with #1455).
The coldbuild gate runs the PINNED release's — `2026-08-27-cb39b65`,
cut before #1455 merged — whose old extent walk still loses
`test_cache_thaws_on_fresh_tl` (a `function` token in type position),
omits it from the generated tail, and refuses the file as an unused
function. One file in scope hits this; the other 64 sweep clean under
both checkers. This is the cold-build staging rule doing its job:
land the checker, bump the pin, then land the code that needs it.

Blocked on 3IUJSV7e (pin bump to a release carrying `2724a719`).
No release yet exists cut from a main containing it (latest:
cb39b65, 05:05Z); releases here are dispatched, never by this item.
The edit is fully mechanical and takes seconds to reproduce from
`## Change`, so no work-in-progress branch is kept. When re-pulled:
apply the Change verbatim, and expect all Acceptance lines to pass
as measured — only the coldbuild gate was red.
