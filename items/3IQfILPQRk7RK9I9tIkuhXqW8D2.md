## Goal

G3 — an honest type layer. The non-`cosmic/**` half of the parent's
`check.must` sweep: the tooling trees and the tail, small enough to
land as one diff, and file-disjoint from the `cosmic/**` half so the
two can run in parallel.

**Measured.** The parent (3IPXQ1Zw) re-ran the census's Method
(`docs/design/nil-flow.md`, `## Method`) on a tree carrying the four
narrowing rules and recorded **12 sites in 7 files** across `_tool/**
_make/** _build/** _cli/**`, heaviest `_tool/doc/index_test.tl` 5,
plus a 2-site tail (`_perf/gate_test.tl` 1, `3p/tl/tl_test.tl` 1) —
**14 sites in ~9 files**, measured 2026-08-25 against a tree carrying
PR #1383, which has since landed (`57dda9bd`).

The candidate file set is a superset derived from the committed
pre-rules census, so the target files are known even before the scan
is re-run (measured 2026-08-26):

```text
awk -F'\t' '$1 ~ /_test\.tl$|_example\.tl$|_benchmark\.tl$/ && $1 !~ /^cosmic\//' \
  docs/design/nil-flow-sites.tsv | cut -f1 | uniq -c | sort -rn

  9 _tool/testrun_test.tl        3 _make/graph_test.tl    1 _make/root_test.tl
  5 _tool/doc/index_test.tl      2 _make/stage_test.tl    1 _fuzz/literal_fuzz_test.tl
  3 _tool/example_test.tl        1 _perf/gate_test.tl     1 _build/snippets_test.tl
  3 _tool/benchmark_test.tl      1 _make/vcs_test.tl      1 3p/tl/tl_test.tl
  3 _make/pin_test.tl
```

34 rows in 13 files before the rules; 14 in ~9 after them. The scan is
the authority on which 14 — re-run it at pull.

## Change

Re-run the census's Method (`docs/design/nil-flow.md`, `## Method`) to
get the current site list, and take every row whose path is NOT under
`cosmic/`. For each, wrap the producing call in `check.must` so the
local is a plain `T`:

```teal
local res = testrun.run(paths)
->
local res = check.must(testrun.run(paths))
```

Add `local check = require("cosmic.check")` where a file does not
already import it. `check.must` declares ONE return, so it composes in
argument and `for` positions without parenthesis-truncation.

A site where `check.must` is wrong — a test that DELIBERATELY exercises
the nil branch, or one asserting on the error string — keeps its
current shape and gets an explicit guard instead. Name every such site
in the PR, with the reason.

Headroom in the files most likely to gain a `require` line, measured
2026-08-26 (`wc -l`, against the 500-line cap): `_fuzz/literal_fuzz_test.tl`
466, `_make/pin_test.tl` 458, `_tool/doc/index_test.tl` 432,
`_tool/example_test.tl` 369, `_perf/gate_test.tl` 366,
`_make/graph_test.tl` 361. A wrap is an in-place edit, so the only
growth is at most one `require` line per file.

`grep -c 'check\.must(' <file>` over the 13 candidate files totals
**91** today (2026-08-26).

## Non-goals

- **No `cosmic/**` file.** That half is the sibling item; two diffs
  touching one file is the merge conflict this cut exists to avoid.
- **No library file.** A `check.must` in library code would throw, and
  AGENTS.md forbids it. Only `_test.tl`, `_example.tl` and
  `_benchmark.tl`.
- **No checker change.** `3p/tl/tl_patch.tl` and `_make/patch.tl` are
  untouched; this is edits at sites.
- **Do not change what a test asserts.** The wrap makes the type
  honest; a test that passes today must still pass, testing the same
  thing, with the same number of assertions.
- **Do not add a cast.** `check.must` replaces `assert(x) as T`, never
  the other way round.
- **Do not rewrite `docs/design/nil-flow.md` or its `.tsv`.** They are
  a dated snapshot against `e7ac1580`; a later census re-derives them.
- **Do not commit the throwaway strict checker.** The Method builds it
  inside `o/` and deletes it; no edit to `o/3p/tl/tl.lua` rides with
  the PR.

## Acceptance

- `bin/cosmic --make ci` ends `ci: PASS` (its coverage stage is what
  catches a `check.must` that throws where the old code silently
  carried a nil).
- Re-running the census's Method over the tree and filtering to the
  non-`cosmic/**` test files reports **0**:

  ```text
  git ls-files '*.tl' | grep -v '/testdata/' | xargs o/bin/cosmic --check types \
    | grep -E '^(_|3p/)' | grep -E '_(test|example|benchmark)\.tl'
  ```

  Any row that survives is a deliberate nil-branch test — name it and
  its reason in the PR.
- The same scan's `cosmic/**` test share and library share are
  UNMOVED from what the pull-time baseline recorded. Quote both
  numbers, before and after, in the PR.
- The diff touches only test, example and benchmark files:
  `git diff --name-only origin/main | grep -vE '_(test|example|benchmark)\.tl$'`
  prints nothing.

## Enablement

none needed. `cosmic.check`'s contract is in AGENTS.md and
`cosmic --docs cosmic.check`; the site list comes from
`docs/design/nil-flow.md`'s `## Method`, re-run, which the parent item
has already exercised twice. The four narrowing rules this item's
counts assume landed as `57dda9bd`.
