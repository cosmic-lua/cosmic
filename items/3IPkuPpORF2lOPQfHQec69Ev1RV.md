## Goal

G3 — an honest type layer. The `return` class of
`docs/design/nil-flow.md` is 44 sites, and the worst of the whole
census is in it: a published `cosmic.*` function whose declared return
type cannot hold a nil its body can produce. A caller that trusts the
signature gets a runtime nil the type says is impossible.

## Evidence

```text
-- cosmic/time.tl:35
  return secs, nanos
```

`now()` is declared `function(): integer, integer`; its body is `local
secs, nanos = unix.clock_gettime(unix.CLOCK_REALTIME)`, and
`o/_types/types_gen/cosmo/unix.d.tl:1938` declares

```text
  clock_gettime: function(clock?: integer): integer | nil, integer, string, Errno
```

so slot 1 admits nil and slot 2 does not. One site, one slot: `secs`.
The same shape recurs at `cosmic/time.tl:44`.

The 44 sites split 22 in tests/examples and 22 in code
(`awk -F'\t' '$3=="return"' docs/design/nil-flow-sites.tsv`). Top
files: `cosmic/fetch/verbs_test.tl` 11, `cosmic/fs/find.tl` 4,
`cosmic/fs/path.tl` 3, `cosmic/fs/dir.tl` 3, `cosmic/time.tl` 2.

The 22 in code are the ones that matter: each is a wrapper
under-declaring over a fallible `cosmo.*` binding, which is exactly the
"honest nil — the type must admit failure" rule of AGENTS.md going
unenforced.

## Change

For each of the 22 non-test `return` sites, choose per site and say
which in the commit:

- **widen the declared return** to `T | nil, string` where the failure
  is real and callers should handle it — this changes a published
  signature, so it needs the caller sweep in the same diff; or
- **guard at the call that produces the union** and return a documented
  fallback where the failure is genuinely unreachable — with the reason
  in the doc comment, not a cast.

Never a cast, and never `as` at a return.

The 22 test-side sites belong to the `check.must` sweep slice, not
here.

## Non-goals

- Do not touch the checker or `3p/tl/tl_patch.tl`.
- Do not fix sites in other classes that happen to sit nearby.
- Do not change the `cosmo.*` contract; that is the `path.join` slice's
  territory and a whilp/cosmopolitan question.

## Acceptance

- `bin/cosmic --make ci` ends `ci: PASS`.
- Re-deriving the census shows zero `return` rows outside
  `*_test.tl`/`*_example.tl`/`*_benchmark.tl`.
- Every widened signature has its `@return` doc comment updated to
  match, and `cosmic --docs <module>` renders the new shape.
