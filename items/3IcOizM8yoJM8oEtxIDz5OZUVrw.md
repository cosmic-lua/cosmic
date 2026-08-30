## Evidence

Found during review-adjacent work on item 3IU4umVT (compile seam misses
`--make check`), out of that item's scope: `lines_of` in
`_tool/seam.tl` duplicates `_cli/lint.tl:305-308` byte for byte, and
both exist only to feed `discover.discover`. The splitter belongs in
`_tool/discover.tl`, with both callers (`_tool/seam.tl` and
`_cli/lint.tl`) using it from there instead of each carrying its own
copy.
