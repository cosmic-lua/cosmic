## Evidence

Found by the builder of item 3IkoLdmJ (cosmic-lua/cosmic#1636, "make:
declare o/bin/cosmic as a reads: dependency of fixtures_test.tl") while
fixing that one file's stale-record bug. The same exposure — a
spawned-binary test whose engine dependency isn't declared, so its
cached record can replay a stale PASS across an engine rebuild — was
suspected in roughly 20 other files that spawn `TEST_BIN`'s `cosmic`
binary the same way `_make/fixtures_test.tl` did.

`3IkoLdmJ`'s actual merged fix (settled by board item `3Im3EEyh`, the
testrun_dep research question) is NOT a per-file `--- reads:`
declaration — an earlier commit tried that and abandoned it, because a
`reads:` header requires its path to already exist when `project.mk`
is generated, which fails on a cold checkout before `o/bin/cosmic`
exists. The merged fix is positional: `_make/graph.tl`'s `project_mk`
adds `o/bin/cosmic` to every test file's `deps_<stem>` list when
`exercises_the_engine(path)` — `path:match("^_make/") or
path:match("^_cli/")` — is true.

That positional rule already covers every file under `_make/**` or
`_cli/**`, confirmed empirically (both by `3Im3EEyh`'s review and
independently by a second reviewer querying a built `o/project.mk`
directly): `_make/build_test.tl`, `_make/artifact_test.tl`,
`_make/check_test.tl`, `_cli/args_test.tl`, `_cli/fence_test.tl`,
`_cli/build/recipe_test.tl`, and the rest of the ~20-file list, so far
as they sit under `_make/` or `_cli/`, all already carry `o/bin/cosmic`
in their `deps_<stem>` — NO per-file work is needed for any of them.

Only files OUTSIDE `_make/**`/`_cli/**` that also spawn the tree's
`cosmic` binary fall outside `exercises_the_engine`'s match:
`_tool/testrun_test.tl` and `_tool/lint_test.tl` are the two named
candidates; there may be others under `_tool/` or elsewhere in the
tree.

## Change

1. Audit which `_tool/*_test.tl` files (and any other file outside
   `_make/**`/`_cli/**`) actually spawn the tree's built `cosmic`
   binary the way `_make/fixtures_test.tl` originally did — re-measure
   the staleness bug per candidate file before fixing it (edit
   `_make/check.tl` trivially, rebuild, run the test twice, check
   `.in`/`.time` mtimes and content — not just `.got`'s mtime, which
   moves universally via `testrun_dep` regardless of whether the test
   actually re-executes; see `3Im3EEyh`'s spec for the confound and how
   to avoid it).
2. For files that do reproduce the bug: prefer widening
   `_make/graph.tl`'s `exercises_the_engine(path)` to also match
   `^_tool/` if that's true for all its test files, over adding
   per-file declarations — the same one-line, positional shape as
   `3IkoLdmJ`'s actual fix, not a per-file `reads:` (which the merged
   fix specifically avoided for the cold-build ordering reason above).
   If `_tool/`'s tests don't uniformly need this (some `_tool/*_test.tl`
   files may not spawn the binary at all), scope the widening precisely
   rather than blanket-including `^_tool/`.
3. Confirm the fix does not over-invalidate an unrelated pure-unit
   test's cached record (same check as `3Im3EEyh`'s reproduction: a
   control file outside the widened scope must show its `.in`/`.time`
   unchanged across an engine rebuild).

## Non-goals

- No change to what any of these tests assert.
- No per-file `--- reads:` declarations — superseded by the positional
  `exercises_the_engine` mechanism; do not reintroduce the abandoned
  approach.
- No re-litigating whether `_make/**`/`_cli/**` files need anything —
  settled: they don't, `3IkoLdmJ`'s merged fix already covers them.

## Acceptance

- Every `_tool/*_test.tl` (and any other outside-`_make/`/`_cli/` file)
  that genuinely spawns the tree's `cosmic` binary is confirmed to
  re-run on an engine rebuild, by the same `.in`/`.time` reproduction
  standard as `3Im3EEyh`, either via a widened `exercises_the_engine`
  or an equivalent positional fix.
- A file that does NOT spawn the binary is left untouched, with its
  cached record confirmed NOT to over-invalidate.
