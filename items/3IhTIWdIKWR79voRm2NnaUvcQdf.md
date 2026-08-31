## Finding

`cosmic/surface_test.tl`'s `embedded_modules()` (around line 27) classifies
any embedded directory under `/zip/cosmic` as a public module by
`fs.is_dir()` alone, without checking for an `init.lua`/`init.tl` the way
`_build/public_surface.tl`'s `modules()` does.

## Symptom

A WIP directory added under `cosmic/` before its `init.tl` lands (e.g. an
in-progress multi-file module being built up file by file, such as
`cosmic/template/{types,lex,parse}.tl` landing ahead of `init.tl`) is
spuriously flagged by `cosmic/surface_test.tl` as an "undocumented public
module" — even though `_build/public_surface.tl`'s own `modules()`
correctly does not count it as public (it requires an `init.tl`/`init.lua`
present). The two surface-checking mechanisms disagree on what counts as a
module, and `surface_test.tl`'s directory-presence check is the stricter,
inconsistent one.

## Provenance

Surfaced 2026-08-31 while building item `3IKFaYlG` (handle «jABk_j8hq»,
"cosmic.template: compile templates to typed Teal") — that item's own spec
named a "sizing seam" allowing `lex`+`parse`+`types` to land as a first PR
ahead of `codegen`+`init`, but landing only that half hit this gate
spuriously (a directory with no `init.tl` yet, failing `surface_test.tl`
even though `_build/public_surface_test.tl` correctly ignored it). The
builder worked around it by landing the full item in one PR instead of
splitting at the seam; this defect is what made that split-landing
strategy load-bearing rather than optional, and is worth its own fix
independent of that item.
