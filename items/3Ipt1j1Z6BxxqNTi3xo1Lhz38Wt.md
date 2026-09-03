## Evidence

`q0zL_uDdq` ("casts: _make's verb registry returns a typed Verb, closing
the 8 dynamic-name-lookup sites") specifies closing all 8
`dynamic name lookup` sites in one PR: 7 in `_make/init.tl` (via a new
`policy.must_verb` helper) and 1 in `cosmic/searcher_test.tl:57-58`.

A builder verified the 7 `_make/init.tl` sites close cleanly:
`policy.must_verb(by_name, name)` (an `assert`-backed helper on
`PolicyModule`, D30's infallible-by-type contract boundary) type-checks
and keeps `_make/init.tl` under the 500-line cap.

The 8th site does not close as specified. The spec's own probe
(`for _, s in ipairs(package.searchers) do local ok, why = pcall(s,
"x") end` → "Type check passed") is insufficient: it never exercises
`why` the way the actual test does. Reproduced against the pinned
checker with the cast removed:

    cosmic/searcher_test.tl:58:19: warning: why (of type function(? string, ? <any type>): <any type>) can never be a string
    cosmic/searcher_test.tl:58:19: error: why (of type function(? string, ? <any type>): <any type>) can never be a string
    cosmic/searcher_test.tl:58:29: error: cannot resolve a type for why here

Root cause: the pinned tl's own builtin declares `package.searchers` as
`{ function(string): (function(?string, ?any): any, any) }`
(`o/3p/tl/tl.tl:337`) — every searcher entry is typed to return exactly
`(loader-function, any)` on a call, with no `string` alternative. But
this test's whole point is that a *declining* searcher returns a bare
`string` instead of a loader — a real, working Lua/tl idiom the
builtin type doesn't model. No cast-free rebinding both type-checks
and preserves the real runtime semantics (a captured third return
value type-checks but binds the wrong slot; wrapping in an inline
`pcall` fails with "excess return values, expected 1, got 2"). Fixing
the underlying gap means patching tl's builtin `package.searchers`
annotation via `3p/tl/tl_patch/` — outside this item's stated file
scope.

Because 1 of 8 sites doesn't close, the item's `_build/casts_baseline.tl`
/ `docs/design/cast-sites.tsv --reconcile` / `docs/design/casts.md`
section-deletion steps can't run as written either — they all assume
the `dynamic name lookup` class reaches zero rows.

## The question

Decide the shape of the fix, then hand back a rewritten spec for
whichever item takes it:

1. Split `q0zL_uDdq`: close the 7 `_make/init.tl` sites now (as
   already verified) and reclassify or re-scope the `casts.tl`/tsv
   reconcile steps to a 7-of-8 partial close (leaving one
   `dynamic name lookup` row); file the 8th site as its own item,
   blocked on a `3p/tl/tl_patch/` entry teaching `package.searchers`
   the declining-searcher (`string` return) shape; or
2. Keep `q0zL_uDdq` whole and rewrite its spec to include the
   `3p/tl/tl_patch/` entry for `package.searchers` as part of this
   item's own `## Change`, closing all 8 sites in one PR (a materially
   larger, checker-patch-touching item than currently specced).
