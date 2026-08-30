## Goal

G4, under the tree-migration container (3IOCdooE): batch 3 of seven —
the `cosmic/` subdirectories fs, child, format, flags, coverage,
sandbox lose their test self-call lines, so those files run because the
toolchain found their cases (D29). The container's spec carries the
facts every batch shares; this one names the scope.

## Evidence (re-measured 2026-08-30 against origin/main c9b0b31f)

- **Scope**: `cosmic/fs/`, `cosmic/child/`, `cosmic/format/`,
  `cosmic/flags/`, `cosmic/coverage/`, `cosmic/sandbox/`, **minus
  `cosmic/fs/glob_test.tl`** (carved out — see below).
- **28 files carry self-calls, 338 lines total**; excluding
  `glob_test.tl` leaves **27 files and 327 lines**:

  ```
  grep -rln '^test_[A-Za-z0-9_]*()$' --include='*_test.tl' cosmic/fs cosmic/child cosmic/format cosmic/flags cosmic/coverage cosmic/sandbox | wc -l
  ```
  → `28`, and the same selection piped through
  `xargs grep -hc '^test_[A-Za-z0-9_]*()$' | paste -sd+ | bc` → `338`.

- **`cosmic/fs/glob_test.tl` does NOT migrate mechanically and is out
  of scope.** It builds its fixture at top level (`local root =` line
  11, `assert(fs.make_dirs(...))` line 12) and tears it down at top
  level on its LAST line, 129: `assert(fs.remove_all(root))`. Runner
  mode runs cases from a generated tail AFTER the whole chunk, so the
  teardown would delete the fixture before any case runs. A build
  bounce on 2026-08-30 measured the result: 9 of 11 cases failing with
  `opendir: .../glob_root: ENOENT`. Migrating it means moving the
  bracket into the cases — a semantic edit this batch's Non-goals
  forbid — so it is its own item (the `_cli/citations_test` precedent,
  a972ab5a / #1508). **A sweep for the same shape found no other file
  in scope carries it**: the only other column-1 statements after a
  test definition are three `print` epilogues (`cosmic/fs/times_test.tl:168`,
  `cosmic/format/types_test.tl:386`,
  `cosmic/format/literal_format_test.tl:71`, item 3IcH4Snp — harmless
  to correctness), and every apparent `io.write`/`child.run` at column
  1 in `child/stdio_test.tl`, `child/init_test.tl`,
  `sandbox/pledge_test.tl`, `sandbox/unveil_test.tl` and
  `sandbox/landlock_test.tl` is inside a `[[ ]]` child-process script
  literal, not a top-level statement (verified by reading each site).

- **The whole change was trialled end to end and the gate passed**:
  `bin/cosmic --make ci` → `ci: PASS (5 stages)`, `259 checks: 258
  passed, 1 skipped`, `2146 tests: 2146 passed`, `coverage ratchet ok`.

## Change

In every `*_test.tl` under this batch's scope, delete each line
matching exactly `^test_[A-Za-z0-9_]*()$` — a bare call at column 1, no
arguments. Nothing else changes in those files, and no file outside the
scope is touched. `cosmic/fs/glob_test.tl` is excluded.

The edit is mechanical; do it with a throwaway script run from the repo
root, kept OUT of the tree (a `*.tl` inside it joins the build graph):

```
grep -rln '^test_[A-Za-z0-9_]*()$' --include='*_test.tl' cosmic/fs cosmic/child cosmic/format cosmic/flags cosmic/coverage cosmic/sandbox | grep -v 'cosmic/fs/glob_test.tl' | xargs sed -i -E '/^test_[A-Za-z0-9_]*\(\)$/d'
```

**Then repair the cast-sites ratchet, which the deletion always
breaks.** `_build/cast_sites_test.tl` fails because
`docs/design/cast-sites.tsv` names cast sites by line number and the
deletion shifts them. The regen the failure message prints
(`bin/cosmic --make run _build/cast_sites.tl --reconcile`) cannot fix
it alone: reconcile keys a site on `path\tline`, so a moved site reads
as newly discovered with no class to carry forward and the tool
refuses to write (item 3IcGmqWF). Measured against c9b0b31f, exactly
five rows shift, and the cast text at old and new line is
byte-identical in all five (verified by comparing
`git show origin/main:<file> | sed -n '<old>p'` against
`sed -n '<new>p' <file>` — all SAME):

| file | old | new |
| --- | --- | --- |
| `cosmic/fs/find_close_test.tl` | 86 | 85 |
| `cosmic/fs/find_close_test.tl` | 88 | 87 |
| `cosmic/sandbox/init_test.tl` | 50 | 48 |
| `cosmic/sandbox/init_test.tl` | 110 | 107 |
| `cosmic/sandbox/init_test.tl` | 119 | 116 |

(`cosmic/sandbox/init_test.tl:21` does not move.) Update ONLY those
line numbers, carrying each row's class string forward verbatim, then
re-run `--reconcile` and confirm it reproduces the file byte for byte
(`md5sum` unchanged across the run — it was `29404957d8083f730510a84d399e97ed`
at measurement). If the numbers have drifted, re-derive them the same
way; never invent or change a class, and never weaken the gate.

## Non-goals

No semantic edits ride along: no renames, no assertion changes, no test
added or removed, no reflow, no comment rewrites. `cosmic/fs/glob_test.tl`
is untouched. No file outside this batch's scope — the other six
batches are file-disjoint on purpose. No change to `cosmic/test.tl`,
`_tool/seam.tl`, `_tool/discover.tl`, or the `call-after-define` lint
(retiring it is 3IOCdvXF). No testrun or report change (3IOCdZCA). No
pin bump. The three `print` epilogues are 3IcH4Snp's, not this item's.

## Acceptance

- `bin/cosmic --make ci` ends `ci: PASS`.
- No self-call survives in scope. Use this form, which names the files
  independently of whether any match remains — the container's older
  `grep -rln … | xargs grep -c …` form runs `grep -c` on stdin once the
  edit lands and prints a bare `0` on success (item 3IcH4hQI):

  ```
  find cosmic/fs cosmic/child cosmic/format cosmic/flags cosmic/coverage cosmic/sandbox -name '*_test.tl' ! -path 'cosmic/fs/glob_test.tl' | xargs grep -c '^test_[A-Za-z0-9_]*()$' | grep -v ':0$'
  ```
  prints nothing, and the `find` names 29 files.
- The `*_test.tl` diff is deletions only:
  `git diff origin/main --numstat -- '*_test.tl' | awk '{a+=$1} END {print a+0}'`
  → `0` insertions. (`docs/design/cast-sites.tsv` is the one non-test
  file the diff may carry.)
- `bin/cosmic --make test` passes and still reports the same number of
  test files as before the edit.
