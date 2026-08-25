## Goal

G3 — an honest type layer. The `_test.tl` / `_example.tl` half of the
unguarded `T | nil` census is closed by a mechanism that already exists
and needs no checker change: `check.must`. AGENTS.md already says so
("In tests and examples, use `check.must` for fallible returns"). This
slice makes the tree match its own doctrine, leaving only library sites
needing judgment.

**Re-measured 2026-08-25, and the numbers moved.** The four narrowing
rules (item 3IPXM4K2, PR #1383) close 127 census sites by teaching the
checker guards the authors already wrote, 64 of them in the test half.
Re-running the census's Method (`docs/design/nil-flow.md`, `## Method`)
on a tree carrying those rules:

```
git ls-files '*.tl' | grep -v '/testdata/' | xargs o/bin/cosmic --check types
  359 sites without the rules, 232 with them
  of the 232: 115 in *_test.tl / *_example.tl, 117 elsewhere
```

So this slice's population is **115 sites in 38 files**, not the 179 in
~60 the original census recorded. Every count below is from that scan;
they hold only once 3IPXM4K2 lands, which is why it is this item's
blocker. Re-run the scan at pull time before trusting any of them.

## Change

For each flagged site in a `_test.tl` or `_example.tl`, wrap the
producing call in `check.must` so the local is a plain `T`:

```
local res = fetch.head(base .. "/x", {allow_private = true})
->
local res = check.must(fetch.head(base .. "/x", {allow_private = true}))
```

Adding `local check = require("cosmic.check")` where a file does not
already import it. `check.must` declares ONE return, so it composes in
argument and `for` positions without parenthesis-truncation.

Sites where `check.must` is wrong — a test that DELIBERATELY exercises
the nil branch, or one asserting on the error string — keep their
current shape and get a guard instead. Name each one in the PR.

**This is still a container, not a slice.** 115 sites across 38 files is
beyond one session's diff. Cut it by tree and file the pieces as
siblings, each carrying its own count and its own acceptance:

- `cosmic/**` — **101 sites in 29 files**, the bulk. Heaviest:
  `cosmic/time_parse_test.tl` 12, `cosmic/fetch/verbs_test.tl` 11,
  `cosmic/embed_test.tl` 9, `cosmic/embed_advanced_test.tl` 7,
  `cosmic/tty_pty_test.tl` 6, `cosmic/fs/path_test.tl` 6,
  `cosmic/fd_test.tl` 5, `cosmic/check_test.tl` 5. Large enough to want
  a second cut of its own — by subtree (`cosmic/fs/**`,
  `cosmic/fetch/**`, then the flat files) is the obvious one.
- `_tool/** _make/** _build/** _cli/**` — **12 sites in 7 files**,
  heaviest `_tool/doc/index_test.tl` 5.
- the tail — **2 sites**: `_perf/gate_test.tl` 1, `3p/tl/tl_test.tl` 1.
  Small enough to ride with the piece above rather than be its own item.

## Non-goals

- **No library file.** A `check.must` in library code would throw, and
  AGENTS.md forbids it. Only `_test.tl` and `_example.tl`.
- **No checker change.** `3p/tl/tl_patch.tl` and `_make/patch.tl` are
  untouched; this slice is edits at sites.
- **Do not change what a test asserts.** The wrap makes the type honest;
  a test that passes today must still pass, testing the same thing.
- **Do not add a cast.** `check.must` replaces `assert(x) as T`, never
  the other way round.
- **Do not fix a site the checker will close.** That is what 3IPXM4K2
  did and why this item waits on it: a guard the author already wrote is
  not work, and wrapping it anyway makes the census unattributable.

## Acceptance

- `bin/cosmic --make ci` ends `ci: PASS`.
- Re-running the census's Method over the tree reports the test/example
  share down from 115 by at least the count this slice claims, with the
  library share unmoved at 117.
- `bin/cosmic --make coverage` ends with `coverage ratchet ok` — a
  `check.must` that throws where the old code silently carried a nil
  would show up as a coverage or test failure, not a quiet pass.

## Enablement

none needed. `cosmic.check`'s contract is in AGENTS.md and
`cosmic --docs cosmic.check`; the sites are listed by
`docs/design/nil-flow.md`'s Method, re-run.
