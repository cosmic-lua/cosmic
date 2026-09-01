## Finding

`cosmic.sandbox.merge()` silently drops the `scope` section from its
result, the same way it dropped `net` before item `3IhTfAF5` (handle
«dDNs_tnLQ») fixed that half.

## Symptom

`sandbox.merge({scope = {...}}, {other = {...}})` silently loses the
`scope` policy from the result with no error.

## Provenance

Anticipated in `3IhTfAF5`'s own spec `## Non-goals`: PR `#1600` (item
`3I7LKuM2` / handle «X8Ro_I6Dl») had not landed on `main` when that
item was written, so it explicitly deferred fixing `scope` rather than
speculating against a shape that might still change in review, asking
for re-verification once #1600 landed. #1600 has since merged.
`3IhTfAF5`'s builder re-verified on the current tree (post-merge):

```
sandbox.merge({scope = {...}}, {scope = {...}}).scope   -- nil
```

confirming the identical silent-drop bug now applies to `scope`.

## Change

In `cosmic/sandbox/init.tl`'s `merge()`, add a `scope` branch alongside
the (now-fixed) `net` branch and the existing `fs`/`sys` branches. Per
item `3IhTfAF5`'s landed fix (PR #1602) for the precedent shape: follow
the same pattern used there for `net` — `Scope`'s fields (`signal:
boolean`, `abstract_unix: boolean`, per `3I7LKuM2`'s landed shape) are
booleans, not lists, so this likely wants OR-composition (either policy
requesting `true` makes the merged result `true`) rather than the
concat-and-dedupe shape `merged_list`/`merged_int_list` use for list
fields — verify the exact composition semantics against `apply()`'s
actual use of `Scope` before choosing.

Extend `cosmic/sandbox/init_test.tl`'s `test_merge_composes_policies`
with `scope` coverage, mirroring the pattern the `net` fix (PR #1602)
used for its own coverage.

## Non-goals

Same non-goals as `3IhTfAF5`'s landed change: no changes to `apply()`,
`validate()`, or the `Report`/`Section` records — scoped to `merge()`'s
composition logic and its test only.

## Acceptance

- `bin/cosmic --make test cosmic/sandbox/init_test.tl` passes with the
  new `scope` coverage.
- `bin/cosmic --make ci` ends `ci: PASS`.
- A probe like `3IhTfAF5`'s (`sandbox.merge({scope=...}, {scope=...}).scope`)
  returns the composed value, not `nil`.
