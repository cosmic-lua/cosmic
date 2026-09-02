## Evidence

Reported by the builder of cosmic-lua/cosmic#1627 (item 3Il3hsTd, the
cross-branch check of `_work/` doc pointers). That test reads
`origin/board` through `git ls-tree` at run time, but `_make/imports.tl`
builds a test's content key from its declared `reads:` inputs (`docs`,
`skills`) only, so under the `ci` lane's `o/` cache hand-forward a
rename on the board branch with no change under `docs/` or `skills/`
replays `_build/doc_paths_test.tl`'s cached verdict instead of
re-running the board case. The gate catches the rename on the next run
that touches the prose or starts cold; locally and in a warm CI cache
it is silent. Sibling of 3Il5nBDy (a rename INSIDE a reads: tree keeps
the verdict because mtime does not move): here the input is a git ref
the key cannot see at all. Re-measure at pull time on a warm tree:
run `bin/cosmic --make test _build/doc_paths_test.tl` twice, then
point the test's `BOARD_REF` at a ref lacking one of the nine
`_work/` files (or fetch a scratch branch that renames one) and run
again; read whether the record replays.

## Change

`_make/imports.tl` (or wherever the `reads:` header is parsed): a
`reads: ref:<name>` form declaring a git ref as an input, whose
contribution to the content key is the ref's current commit
(`git rev-parse <name>`, read once per graph build; absent ref keys as
empty and the test's own skip path handles it). `_build/doc_paths_test.tl`
declares `reads: ref:origin/board`. A test in `_make/` renames a file
on a scratch ref between two runs and asserts the second run is not a
replay. Measure the cost of the extra `rev-parse` per declared ref on
a full `--make test` and record it in the PR.

## Non-goals

- No change to what the doc path gate asserts.
- No general "always re-run" escape; the ref's commit is the key.
