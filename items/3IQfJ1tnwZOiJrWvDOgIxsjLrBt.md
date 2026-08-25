## Goal

G3 — an honest type layer. The `cosmic/**` half of the parent's
`check.must` sweep: the bulk of the test/example census, and the half
that still needs a cut of its own before any of it is pullable.

**Measured.** The parent (3IPXQ1Zw) re-ran the census's Method
(`docs/design/nil-flow.md`, `## Method`) on a tree carrying the four
narrowing rules and recorded **101 sites in 29 files** under
`cosmic/**`, measured 2026-08-25 against a tree carrying PR #1383,
which has since landed (`57dda9bd`). Heaviest:

```text
cosmic/time_parse_test.tl 12   cosmic/tty_pty_test.tl 6
cosmic/fetch/verbs_test.tl 11  cosmic/fs/path_test.tl 6
cosmic/embed_test.tl 9         cosmic/fd_test.tl 5
cosmic/embed_advanced_test.tl 7  cosmic/check_test.tl 5
```

The committed pre-rules census holds 145 rows in the same tree
(measured 2026-08-26):

```text
awk -F'\t' '$1 ~ /_test\.tl$|_example\.tl$|_benchmark\.tl$/ && $1 ~ /^cosmic\//' \
  docs/design/nil-flow-sites.tsv | wc -l
```

## Change

**This is a container, not a slice.** 101 sites across 29 files is
several sessions' worth of diff, and two sessions editing one file is
the merge conflict the cut exists to avoid. The next refinement pass
re-runs the Method, takes the current `cosmic/**` rows, and files
file-disjoint children under this item — the obvious cut is by
subtree, each child carrying its own measured file list, its own
count, and its own acceptance:

- `cosmic/fs/**`
- `cosmic/fetch/**`
- the flat `cosmic/*_test.tl` / `cosmic/*_example.tl` files, cut again
  by count if one pass is still too large

Each child then does what the sibling tooling item does: wrap each
flagged site's producing call in `check.must` so the local is a plain
`T`, adding `local check = require("cosmic.check")` where a file does
not already import it, and giving an explicit guard instead to any
site that deliberately exercises the nil branch.

## Non-goals

- **No file outside `cosmic/**`.** The tooling trees and the tail are
  the sibling item.
- **No library-code `check.must`.** It throws, and AGENTS.md forbids
  it. Only `_test.tl`, `_example.tl` and `_benchmark.tl` — including
  the `_test.tl` files that sit beside library sources under
  `cosmic/`.
- **No checker change.** `3p/tl/tl_patch.tl` and `_make/patch.tl` are
  untouched.
- **Do not change what a test asserts.**
- **Do not rewrite `docs/design/nil-flow.md` or its `.tsv`.**

## Acceptance

This container is done when its children are done and the outcome is
observable directly: re-running the census's Method over the tree
reports **0** rows under `cosmic/**` in `*_test.tl`, `*_example.tl`
and `*_benchmark.tl`, except deliberate nil-branch tests named in
their own PRs —

```text
git ls-files '*.tl' | grep -v '/testdata/' | xargs o/bin/cosmic --check types \
  | grep -E '^cosmic/' | grep -E '_(test|example|benchmark)\.tl'
```

— with the library share unmoved, and `bin/cosmic --make ci` ending
`ci: PASS`.

## Enablement

none needed for the decomposition. The site list comes from
`docs/design/nil-flow.md`'s `## Method`, re-run; `cosmic.check`'s
contract is in AGENTS.md and `cosmic --docs cosmic.check`. The four
narrowing rules these counts assume landed as `57dda9bd`.
