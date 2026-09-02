## Evidence

Found by the builder of item 3IkoLdmJ (cosmic-lua/cosmic#1636, "make:
declare o/bin/cosmic as a reads: dependency of fixtures_test.tl") while
fixing that one file's stale-record bug. The same exposure — a
spawned-binary test whose `--- reads:` declaration does not name
`o/bin/cosmic`, so its cached record can replay a stale PASS across an
engine rebuild — is present in roughly 20 other files that spawn
`TEST_BIN`'s `cosmic` binary the same way `_make/fixtures_test.tl` did,
among them `_make/build_test.tl`, `_make/artifact_test.tl`,
`_make/check_test.tl`, `_cli/args_test.tl`, `_cli/fence_test.tl`,
`_cli/build/recipe_test.tl`, and several `_tool/*_test.tl` files
(`_tool/testrun_test.tl`, `_tool/lint_test.tl`) not even under
`_make/`/`_cli/`. 3IkoLdmJ's own `## Change` named only
`_make/fixtures_test.tl`, so the builder correctly left the rest alone.

## Change

Audit every `_make/*_test.tl`, `_cli/**/*_test.tl`, and `_tool/*_test.tl`
file that spawns the `cosmic` binary built for the tree (`TEST_BIN` or
equivalent) and add `o/bin/cosmic` to its `--- reads:` declaration where
missing, following the same mechanism 3IkoLdmJ used
(`_make/imports.tl`'s `reads_of_file` folds a declared path into
`deps_<stem>`, the make prerequisite list). Re-measure the staleness
bug per file before fixing it (edit `_make/check.tl` trivially, rebuild,
run the test twice) to confirm each file actually reproduces the stale
replay before declaring it fixed, and confirm the fix does not
over-invalidate an unrelated pure-unit test cached record.

## Non-goals

- No change to what any of these tests assert.
- No change to the `reads:` mechanism itself (`_make/imports.tl`).
