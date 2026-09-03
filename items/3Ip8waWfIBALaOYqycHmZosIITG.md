## Change

Two edits to one file, `_build/doc_paths_test.tl` (326 lines: `git show origin/main:_build/doc_paths_test.tl | wc -l`). They are kept in one item because both touch the same 30-line header/case region of one file and neither is meaningful without the other being green.

**1. Declare every tree the prose points at.** Replace lines 2-3 (`--- reads: docs` / `--- reads: skills`) with one line naming every root a path-shaped span resolves into, measured below: `--- reads: 3p _build _cli _docs _eval _make _perf _tool _types cmd cosmic docs embed skills sys`. Do NOT add `.github` unless `o/bin/cosmic -e 'print(#require("cosmic.fs").find(".github"))'` prints a nonzero count (`reads_of_file` expands a directory with `fs.find`, `_make/imports.tl:180-186`; if it prunes dot-dirs the declaration would silently list nothing). `_build/coldbuild_test.tl:1` is the precedent for a whole-tree declaration. This makes every root a `deps_<stem>` member (bytes in the content key, `_cli/build/work.tl:346-350`) and gives the test a `o/.reads/_build/doc_paths_test.reads` stamp (`_make/readstamp.tl`) so a rename anywhere in those roots reschedules it. Update the header comment to say the test's input is the tree, not the prose.

**2. Under CI, a board check that cannot run is a failure.** In `test_every_board_reference_names_a_file_on_the_board_branch` (lines 263-278), replace the `print("skipped: ...") return` branch with: `if os.getenv("CI") then error(...)` naming `why` and the `pr.yml` fetch step that should have brought `origin/board`; otherwise keep the skip-aloud print. `CI` is already a D18 step-key switch (`_cli/build/work.tl:59-62`) so the CI verdict and a local verdict never share a record, and the runner hands the child every variable but `COSMIC_COVERAGE`/`COSMIC_MAKE_ROOT` (`_tool/testrun.tl:59-69`), so the child sees `CI`.

Add a case to `_make/build_incremental_test.tl` shaped like `test_a_rename_inside_a_declared_reads_tree_reruns_the_test` (lines 244-266) only if the existing case does not already prove the mechanism for a multi-root declaration; it does (one root suffices), so no new build test — the change is the declaration.

## Evidence

Composition of `deps_<stem>` for a test (`git show origin/main:_make/graph.tl | sed -n 150,197p`): built import closure + `reads:` expansion + reads stamp + env stamp + ref stamp + (engine tests only) `o/bin/cosmic`. The test imports only `cosmic.check`, `cosmic.child`, `cosmic.fs` (`sed -n 24,27p`). Nothing in that set names `cosmic/`, `_make/`, `_cli/` ... so a `git mv cosmic/fs/walk.tl` leaves every prerequisite unmoved and the content key unchanged: the cached PASS replays (`do_record`, `work.tl:352-358`).

Where the prose points (`git grep -oh '`[A-Za-z0-9_./<>*-]*/[A-Za-z0-9_./<>*-]*\.\(md\|tl\|lua\|mk\|yml\|sh\)`' origin/main -- docs skills | sed 's/`//g' | cut -d/ -f1 | sort | uniq -c | sort -rn`):
```
 87 cosmic  36 o  31 docs  29 _build  28 3p  27 _make  22 _cli  20 _perf  19 cmd
 17 _work  16 skills  15 _types  10 <dir>  8 _tool  6 _docs  3 sys  3 _eval
 3 .github  2 embed  ... (pkg/greet/lib/mk/tool/doc are excused example/sibling spans)
```
Only `docs` and `skills` are declared today (`git show origin/main:_build/doc_paths_test.tl | sed -n 1,4p`):
```
#!/usr/bin/env cosmic
--- reads: docs
--- reads: skills
--- ref: origin/board
```
Skip path (`sed -n 272,277p`):
```
  local paths, why = board_paths()
  if not paths then
    print("skipped: " .. BOARD_REF .. " board paths unchecked: " .. why ..
      " — `git fetch origin board` to check them")
    return
  end
```
A passing test's stdout is written to `.out` and printed only in the failure report (`_tool/testrun.tl:128`, `:368-372`), so the skip is invisible to `--make ci`. Files the declaration adds to the key (`for r in ...; do git ls-tree -r --name-only origin/main -- $r | wc -l; done`): cosmic 312, _make 92, _perf 50, _cli 44, _tool 36, _build 28, _types 19, 3p 10, .github 4, _docs 3, cmd 2, embed 1, sys 1 — the same order of cost `_build/coldbuild_test.tl` already pays per run.

## Non-goals

The extension list, the ```` ``` ````-only fence detection and `../` spans stay as they are; a wider span grammar is its own item.
