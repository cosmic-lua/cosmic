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

## Change

In `cosmic/surface_test.tl`, `embedded_modules()` (lines 18–36) treats a
directory as a module whenever `fs.is_dir(EMBEDDED .. "/" .. name)` is
true — no check that it actually has an entry point. In the shipped
binary a directory module's entry point is `init.lua` (confirmed in
`cosmic/searcher.tl`'s `zip_searcher`, which resolves `cosmic.foo` by
trying `"/zip/" .. rel .. ".lua"` then `"/zip/" .. rel .. "/init.lua"`, and
in `ZIP_TEMPLATES = {"/zip/?.lua", "/zip/?/init.lua"}`). `_build/public_surface.tl`'s
tree-side `modules()` already gates its directory branch the same way,
against the source tree: `fs.is_file(fs.join(dir, name, "init.tl"))`
(lines 77–78). Bring the embedded-side check to parity:

1. Change the directory branch's condition from

   ```lua
   elseif not lua and fs.is_dir(EMBEDDED .. "/" .. name) then
   ```

   to

   ```lua
   elseif not lua and fs.is_file(root .. "/" .. name .. "/init.lua") then
   ```

   (an `is_file` on `init.lua` subsumes the `is_dir` check — a compiled
   `init.lua` cannot exist unless `name` is a directory — so drop
   `fs.is_dir` entirely rather than keep both).

2. Parameterize `embedded_modules` on the root it scans, the same way
   `public_surface.tl`'s `modules(root: string)` is parameterized, so the
   fixed rule is unit-testable against a synthetic tree instead of only
   against whatever happens to be embedded in the binary under test.
   Change the signature from `embedded_modules(): {string}` to
   `embedded_modules(root: string): {string}`, replace every use of the
   `EMBEDDED` upvalue inside the function body with the `root` parameter,
   and update the one call site to pass the constant explicitly:

   ```lua
   local public = visibility.public_of(embedded_modules(EMBEDDED))
   ```

   The `EMBEDDED` constant itself (line 13) stays as it is — it is still
   needed at the call site.

3. Add a new test function to `cosmic/surface_test.tl`, alongside the
   existing `test_*` functions, that builds a synthetic tree under
   `TEST_TMPDIR` and asserts the fixed rule on it directly — mirroring
   `_build/public_surface_test.tl`'s `test_modules_reads_the_tree_by_position`
   (lines 57–73), which fixtures exactly this pair of cases (a directory
   with `init.tl` present, one without) against the tree-side `modules()`.
   The embedded-side fixture uses `.lua` names (compiled form) instead of
   `.tl`:

   ```lua
   local function test_embedded_modules_requires_an_entry_point()
     local root = fs.join(check.must(os.getenv("TEST_TMPDIR")), "embedded_surface")
     assert(fs.make_dirs(fs.join(root, "box")))
     assert(fs.make_dirs(fs.join(root, "wip")))
     assert(fs.write(fs.join(root, "shiny.lua"), "return {}\n"))
     assert(fs.write(fs.join(root, "box", "init.lua"), "return {}\n"))
     assert(fs.write(fs.join(root, "box", "shard.lua"), "return {}\n"))
     assert(fs.write(fs.join(root, "wip", "types.lua"), "return {}\n"))

     local got = embedded_modules(root)
     table.sort(got)
     assert(table.concat(got, " ") == "cosmic.box cosmic.shiny",
       "got: " .. table.concat(got, " "))
   end
   ```

   `wip` (a directory with a `.lua` file but no `init.lua`, standing in
   for `cosmic/template/{types,lex,parse}.tl` landing ahead of
   `cosmic/template/init.tl`) must be absent from `got`; today, before
   this change, it is spuriously included — this is the regression test
   for the Symptom section above. Call the new test function at file
   scope the same way every other `test_*` in this file is (this file
   predates D29 and self-calls: `test_embedded_modules_requires_an_entry_point()`
   immediately after its definition, matching the existing
   `test_the_rule_actually_partitions()` etc. below it).

No other file changes. `_build/public_surface.tl` and
`_build/public_surface_test.tl` are already correct and are not touched —
this closes the gap on the embedded side only.

## Non-goals

- Not touching `_build/public_surface.tl`'s tree-side `modules()` — it
  already gates on `init.tl` and is the reference this change matches.
- Not changing what counts as public (`cosmic/doc/visibility.tl`) — this
  is only about which directories `surface_test.tl` hands to that rule.
- Not adding a cross-check test asserting the embedded-side and
  tree-side rules agree with each other in general (beyond the existing
  `test_index_visibility_agrees_with_the_rule`, which covers a different
  pair of surfaces — the doc index and `visibility.is_public`); the fix
  here is bringing one rule to parity with the other's already-settled
  behavior, not adding new machinery to keep them in sync going forward.
