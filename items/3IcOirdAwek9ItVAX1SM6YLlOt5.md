## Evidence

Found during review-adjacent work on item 3IU4umVT (compile seam misses
`--make check`), which closed `_tool/seam.tl`'s third call site but left
two pre-existing defects in `Augmented.mode` untouched, out of that
item's scope:

1. **`Augmented.mode` has no reader.** Item 3IOCdHTM (the original seam
   landing, #1446) added the field so callers could refuse `mixed` mode
   with the lint's message shape, and no caller does — `grep -rn
   '\.mode' _cli/ _make/ cosmic/ --include='*.tl'` against
   `_tool/seam.tl`'s `Augmented` record shows the field is set but never
   read anywhere in the tree.
2. **`augment` returns `mode = "empty"` for a non-test path**, pinned at
   `_tool/seam_test.tl:54`. `empty` already means "a test file with no
   `test_*` definitions" elsewhere in the discovery vocabulary
   (`_tool/discover.tl`); using the same string for "this path is not a
   test file at all" is a conflation the first consumer of `.mode` will
   read as a bug.

Both live in `_tool/seam.tl` (85 lines at last measurement, well under
the 500-line cap) and its test file.
