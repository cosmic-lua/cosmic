Stage 2 of 3ISnTFGe: once a cosmic release and pin bump carry the
directory-aware patch mechanism (paths_of_pin/read_all, PR #1424),
split 3p/tl/tl_patch.tl at its group seam into
3p/tl/tl_patch/ast_cache.tl (5 entries) and 3p/tl/tl_patch/narrow.tl
(15 entries), entries byte-identical, prose path references following
the rename (11 files, list in PR #1424's first-push diff 9ff72e9b —
the whole stage was built and validated there before the build lane
refused it). The wall, proven 2026-08-27 in run 33033225229:
generation 1 of a cold build fetches with the PINNED binary, and a
pin whose mechanism knows only the single-file layout applies no
patches, so tlast_gen fails on the unpatched tl ("no ast_hooks").
Pull-time gate: the pinned release binary resolves a scratch
directory-form patch (write a pin+<stem>_patch/ fixture in a temp
project and run the PINNED binary's --make fetch on it), or simpler,
bin/cosmic.pin names a release whose tag's commit has PR #1424's
merge as an ancestor. Acceptance oracle from the first push: a clean
re-fetch reproduces the applied tl.lua digest exactly
(77a25cb9597956bb…). The cold-build rule generalizes again: not just
sources needing the new checker, and not just any source (3ISnyPb7's
tree-wide correction), but tree LAYOUT needing new build-mechanism
code — the pin must learn to read a shape before the shape lands.
