## Goal

`bin/cosmic.pin` names a release whose checker carries #1455
(`2724a719`, "discover: read a definition's extent from the parser,
not a depth count"), so the runner-mode migration batches can pass
`_build/coldbuild_test.tl`: the pinned generation-1 checker must
discover every `test_*` definition, or a migrated file whose
definition it misses fails the cold build with an unused-function
refusal.

## Evidence

- Measured 2026-08-27T06:5xZ on the applied batch-1 edit: `--make ci`
  fails only `_build/coldbuild_test.tl`, with the pinned cb39b65
  checker refusing `_types/tlast_test.tl:39:1: warning: unused
  function test_cache_thaws_on_fresh_tl` — the old discover loses that
  definition (a `function` token in type position), so its generated
  tail omits the case and the local goes unreferenced. The tree's own
  checker (with #1455) sweeps the same edit clean, and the migration
  probe shows 65 files, 0 differences, name for name.
- Re-measured at pull (2026-08-27T13:5xZ): a qualifying release now
  exists. `2026-08-27-555873e` (published 13:13:47Z, prerelease as
  every daily cut is) resolves to `555873eb`, and `git merge-base
  --is-ancestor 2724a719 $(git rev-list -n1 2026-08-27-555873e)` exits
  0 — so the fix is in. It is also the newest release; `cb39b65`
  (05:05Z) is no longer the latest.
- Re-measured at pull, behaviourally, against the downloaded artifact
  rather than the tag: a two-definition `_test.tl` with no self-calls,
  whose first definition carries a `function` token in type position
  (`assert(v is function(any): (any, any), "shape")`), type-checks
  clean under `2026-08-27-555873e`'s `cosmic-lua` and fails under the
  currently-pinned `2026-08-27-cb39b65`'s with `probe2_test.tl:1:1:
  warning: unused function test_probe_typed`. Ancestry alone checks
  the release TAG's sha, not the sha its binary was built from; this
  checks the binary the pin will execute.
- Gate at pull: `git merge-base --is-ancestor 2724a719 <release tag
  sha>` must succeed for the release the bump names.

## Change

When a release cut from a main that contains `2724a719` exists (the
release workflow is dispatched by a human or cron — never dispatch one
for this item), bump `bin/cosmic.pin`'s url + sha256 to it, then
`bin/cosmic --make fetch && bin/cosmic --make ci`, fixing whatever the
new pin's types break (expected: nothing — no `cosmo.*` contract
change rides between cb39b65 and the target).

## Non-goals

No migration edits ride along — the batches (3IU6AZEx and siblings)
land separately once this unblocks them. No cosmos pin change unless
the release notes demand one.

## Acceptance

- `git merge-base --is-ancestor 2724a719 $(git rev-list -n1 <tag>)`
  exits 0 for the pinned release's tag.
- `bin/cosmic --make ci` from a state with no `o/bin/cosmic` (cold
  start from the new pin) ends `ci: PASS`.
- The perf compare gate against the previous pin, per the release
  procedure in AGENTS.md.

## Enablement

none — no board item gates this. The wait is external: a qualifying
release must exist first. Whoever pulls this checks the releases page
for a tag whose commit contains `2724a719`; if none exists yet, the
item is not workable and stays put (never dispatch a release for it).
