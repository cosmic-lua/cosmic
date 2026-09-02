## Evidence

Found by the fresh-context review of cosmic-lua/cosmic#1622 (item
3IkxXhOb, the doc path gate, a `reads: docs` / `reads: skills` tree
scan). On a warm local tree, renaming a file inside a declared
`reads:` tree (`mv` or `git mv`, both of which preserve mtime) leaves
nothing newer than the test's `.got` record, so make never schedules
the recipe and the cached verdict replays — the rename that the gate
exists to catch is invisible until something else touches the tree.
Measured on #1622's head `bbf66969`: `git mv skills/work/decompose.md
skills/work/x.md` then `bin/cosmic --make test _build/doc_paths_test.tl`
replays the cached PASS; `touch skills/work/x.md` then the same
command fails naming `docs/goals.md:8` as expected. The D18 content
key already includes input NAMES (`_cli/build/work.tl:85`), so once
scheduled the record is correctly invalidated; the gap is scheduling.
Every `reads:` tree scan in `_build/` shares it (docs_test,
workflows_test, guides_test, snippets_test, cast_sites_test,
fuzz_test). CI starts cold, so the merge boundary holds; local
"green" after a rename is fiction. Related but distinct from
3IkoLdmJ (stale record across an engine edit): that one is a missing
prerequisite, this one is a prerequisite whose mtime does not move.

## Change

`_cli/build/work.tl` (or the make rule it emits for a test with a
`reads:` header): make the test's prerequisite for a `reads:` tree a
stamp derived from the tree's LISTING (sorted paths, regenerated
cheaply on every run via an order-only or always-run rule) rather
than the files' mtimes alone, so a rename, add or delete inside the
tree changes the stamp and schedules the recipe. Add a test in
`_make/` or `_cli/build/` that renames a fixture input on a warm
tree and asserts the test re-runs. Measure the cost on a full
`--make test` and record it in the PR body.

## Non-goals

- No change to the D18 content key.
- No change to any `_build/*_test.tl`.
