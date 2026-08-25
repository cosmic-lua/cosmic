## Goal

G3 — an honest type layer. Exactly half the census is in test-shaped
files, and that half has a one-line fix that already exists and is
already doctrine: `check.must`. Closing it removes 179 of the 358 sites
without a single design decision, and leaves the remaining half as the
real work.

## Evidence

`docs/design/nil-flow.md` measured **179 sites in `*_test.tl`,
`*_example.tl` and `*_benchmark.tl`, 179 everywhere else**:

```text
awk -F'\t' '{print ($1 ~ /_test\.tl$|_example\.tl$|_benchmark\.tl$/)}' \
  docs/design/nil-flow-sites.tsv | sort | uniq -c
```

Top test-side files: `cosmic/time_parse_test.tl` 12,
`cosmic/fetch/verbs_test.tl` 11, `cosmic/embed_test.tl` 10,
`cosmic/tty_pty_test.tl` 9, `cosmic/embed_advanced_test.tl` 9,
`_tool/testrun_test.tl` 9.

AGENTS.md already prescribes the fix: "In tests and examples, use
`check.must` for fallible returns … it declares ONE return, so it
composes anywhere a value goes — `return check.must(f())`,
`g(x, check.must(f()))`."

**Do this after the `or` narrowing rule lands.** Of the 69 sites that
rule closes, a large share are the `(x or "nil")` shape inside
assertion messages — `_tool/testrun_test.tl:21` is the exemplar — and
rewriting them by hand first would be work undone twice.

## Change

Sweep the test-shaped half of `nil-flow-sites.tsv`, file by file,
replacing each unguarded union at a sink with `check.must` at the call
that produces it. Where `check.must` does not fit (a deliberate
nil-returning assertion, an iterator's exhaustion), guard explicitly and say
so in a comment.

Never add a cast, and never `assert(x) as T` — AGENTS.md names that as
the anti-pattern `check.must` replaces.

Split by directory if the diff gets unreadable: `cosmic/**` first, then
`_tool/ _eval/ _perf/ _docs/`.

## Non-goals

- Do not touch non-test files; that is the sibling slices' work.
- Do not weaken or delete an assertion to make a site disappear.
- Do not touch the checker or `3p/tl/tl_patch.tl`.

## Acceptance

- `bin/cosmic --make ci` ends `ci: PASS`, with the coverage ratchet
  unmoved or raised.
- Re-deriving the census shows zero rows whose path matches
  `_test\.tl$|_example\.tl$|_benchmark\.tl$`.
- `git diff` adds no `-- cast:` line and no `as` token
  (`git diff origin/main...HEAD | grep -c '^+.*-- cast:'` is `0`).
