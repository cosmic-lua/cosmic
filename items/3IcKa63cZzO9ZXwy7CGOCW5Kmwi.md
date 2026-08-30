## Change

`cosmic/fs/glob_test.tl` cannot join the runner-mode migration
mechanically, so it is carved out of batch 3/7 (3IU6AsZC) into this
item. Measured against origin/main c9b0b31f, 2026-08-30.

The file brackets its cases with top-level statements: it builds the
fixture at lines 11-15 (`local root = fs.join(TEST_TMPDIR,
"glob_root")`, `assert(fs.make_dirs(fs.join(root, "src", "deep")))`,
then a `for` loop writing seven files) and tears it down on its LAST
line, 129: `assert(fs.remove_all(root))`. Under legacy semantics the
self-calls ran between the two. Runner mode runs cases from a generated
tail AFTER the whole chunk, so the teardown removes the fixture before
any case executes.

This is measured, not predicted. Deleting the file's self-call lines
and running the gate produced `ci: FAIL (coverage)` with 9 of the
file's 11 cases failing on `opendir: .../glob_root: ENOENT`.

The change, in `cosmic/fs/glob_test.tl` only: move the bracket into the
cases so each case owns its fixture, then delete the self-call lines so
the file reaches runner mode like its siblings. The precedent to follow
is `_cli/citations_test.tl` (a972ab5a, PR #1508), which hit this exact
shape and resolved it by rewriting the bracket into the cases.

Which form the rewrite takes is a real decision this spec does NOT
settle, and it must be settled before the item is pullable: a
`setup()`/`teardown()` helper pair called at the head and tail of each
case, a single helper returning a per-case root under `TEST_TMPDIR`, or
whatever `_cli/citations_test.tl` actually did — that file has not been
read for this item. Refine by reading the precedent, choosing one form,
and naming it here with the helper's signature.

## Non-goals

No change to any other file — batch 3/7 (3IU6AsZC) covers the other 27
files in its scope and explicitly excludes this one. No change to
`cosmic/fs/glob.tl` itself, to `cosmic/test.tl`, `_tool/seam.tl` or
`_tool/discover.tl`. No assertion changes: the cases keep testing what
they test, and the case count must not move.
