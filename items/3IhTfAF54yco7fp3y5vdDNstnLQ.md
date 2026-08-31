## Finding

`cosmic.sandbox.merge()` (`cosmic/sandbox/init.tl`) silently drops the
`net` section entirely from its result — it was never wired in when net
landed (PR #1596) — and, as of item `3I7LKuM2` (handle «X8Ro_I6Dl»,
"sandbox: the facade reaches ABI 9"), now also drops the new `scope`
section the same way. No test covers merging either section.

## Symptom

`sandbox.merge({net = {...}}, {other = {...}})` silently loses the `net`
policy from the result with no error — the caller gets a merged Options
table that looks complete but is missing a section they explicitly
passed. Same for `scope` after `3I7LKuM2` lands. Any caller relying on
`merge()` to compose a `net` or `scope` policy across two Options values
(e.g. a base project policy merged with a per-call override) silently
loses that half of the policy.

## Provenance

Surfaced 2026-08-31 while building item `3I7LKuM2` (handle «X8Ro_I6Dl»)
— the builder noticed `merge()` had no `net` handling already (a
pre-existing gap from PR #1596) and confirmed the new `scope` section
they were adding had the identical gap, but fixing `merge()` was outside
that item's `## Change`. Left alone there; filed here as its own gap.
