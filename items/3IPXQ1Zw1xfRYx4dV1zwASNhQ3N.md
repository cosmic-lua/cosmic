## Goal

G3 — an honest type layer. `docs/design/nil-flow.md` found 179 of the
359 unguarded `T | nil` sinks are in `_test.tl` and `_example.tl`
files, where the mechanism that closes them already exists and needs no
checker change: `check.must`. AGENTS.md already says so ("In tests and
examples, use `check.must` for fallible returns"). This slice makes the
tree match its own doctrine, which halves the census with mechanical
edits and leaves only library sites needing judgment.

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

The heaviest files, from the census: `cosmic/time_parse_test.tl` 12,
`cosmic/fetch/verbs_test.tl` 11, `cosmic/embed_test.tl` 10,
`cosmic/embed_advanced_test.tl` 9, `_tool/testrun_test.tl` 9,
`cosmic/codec_test.tl` 7.

Sites where `check.must` is wrong — a test that DELIBERATELY exercises
the nil branch, or one asserting on the error string — keep their
current shape and get a guard instead. Name each one in the PR.

**This slice is a candidate for decomposition.** 179 sites across ~60
files is beyond one session's diff. Cut it by tree
(`cosmic/**`, then `_tool/**` + `_make/**`, then the rest) and file the
pieces as siblings; the acceptance below then states each piece's own
count.

## Non-goals

- **No library file.** A `check.must` in library code would throw, and
  AGENTS.md forbids it. Only `_test.tl` and `_example.tl`.
- **No checker change.** `3p/tl/tl_patch.tl` and `_make/patch.tl` are
  untouched; this slice is edits at sites.
- **Do not change what a test asserts.** The wrap makes the type honest;
  a test that passes today must still pass, testing the same thing.
- **Do not add a cast.** `check.must` replaces `assert(x) as T`, never
  the other way round.

## Acceptance

- `bin/cosmic --make ci` ends `ci: PASS`.
- Re-running the census's Method over the tree reports the
  test/example share down from 179 by at least the count this slice
  claims, with the library share unmoved at 180.
- `bin/cosmic --make coverage` ends with `coverage ratchet ok` — a
  `check.must` that throws where the old code silently carried a nil
  would show up as a coverage or test failure, not a quiet pass.

## Enablement

none needed. `cosmic.check`'s contract is in AGENTS.md and
`cosmic --docs cosmic.check`; the sites are listed by
`docs/design/nil-flow.md`'s Method, re-run.
