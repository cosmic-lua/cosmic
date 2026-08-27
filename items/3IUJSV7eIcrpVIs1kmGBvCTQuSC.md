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
- The latest release is `2026-08-27-cb39b65` (published 05:05Z), cut
  from `cb39b65d` — an ancestor of #1455's merge, so no published
  release carries the fix yet.
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

Blocked on nothing on the board — the wait is for the next release
run, an external event. Whoever pulls this checks the releases page
first; if no qualifying release exists yet, the item is not workable
and stays put.
