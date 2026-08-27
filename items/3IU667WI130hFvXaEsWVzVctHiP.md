## Goal

`bin/cosmic.pin` names a release whose tag commit carries main
`c78504bd` (#1439, the metatable is-dispatch entries; #1442's
closure-carry merge precedes it on main, so one gate covers both).
As of 2026-08-27T05:05Z the pin is `2026-08-27-6b88a0d`, and
`git merge-base --is-ancestor c78504bd 2026-08-27-6b88a0d^{commit}`
fails. The daily release cron (06:00 UTC, release.yml) should
produce an eligible release; dispatching one early is a human's
call, never this item's. The pin bump that follows is the same
two-line procedure 3ITpcO21 landed (PR #1434).

## Result

Done when a merged `bin/cosmic.pin` bump names a release whose tag
commit has `c78504bd` as an ancestor
(`git merge-base --is-ancestor c78504bd <tag sha>` succeeds). End
this item then. It exists so 3IU5Vhvy (retiring the guard-and-cast
workarounds, whose sources will then REQUIRE the patched checker at
cold build) carries a real blocker edge instead of being re-offered
by `next` while the pinned checker cannot compile them.

## Status at 2026-08-27T05:05Z

Still blocked, and the reason is external: the newest release is
`2026-08-27-6b88a0d` (published 03:28Z), whose tag commit is
`c9ecd10b`, and `git merge-base --is-ancestor c78504bd
c9ecd10b` fails — re-measured, the Goal's claim stands.

A release run IS in flight and will satisfy this: `release.yml` run at
head `cb39b65d` (main's tip), started 04:57Z, `workflow_dispatch`,
`in_progress`. Recent release runs take roughly 35 minutes end to end
(02:53Z → published 03:28Z), so expect its tag around 05:30Z. Verify
against the actual tag when it appears rather than assuming:

```
git fetch origin --tags
git merge-base --is-ancestor c78504bd <new-tag>^{commit}
```

**One pin bump settles two chains.** 3IU62YqO — under the runner-mode
migration container (3IOCdooE) — needs the pin to name a release
carrying the D29 compile seam (#1446, merged 04:40Z), and the same
`cb39b65d` release carries both that and `c78504bd`. Whoever bumps
should do it once, in one PR, and satisfy both items: check both
ancestries against the chosen tag, and say so in the PR body.
`c78504bd` is also not an ancestor of the current pin, and neither is
the seam's `3a045017`, so no eligible release exists yet for either.
