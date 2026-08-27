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

## Status at 2026-08-27T05:02Z

Still blocked, and the reason is still external: no release published
since the last measurement. Newest release is `2026-08-27-6b88a0d`
(published 2026-08-27T03:28:45Z), tag commit `c9ecd10b`. Re-measured
against a fresh `git fetch origin --tags && git fetch origin main`:

```
$ git rev-parse 2026-08-27-6b88a0d^{commit}
c9ecd10b67bfe8519e3c93f39c82f51a80f23621
$ git merge-base --is-ancestor c78504bd 2026-08-27-6b88a0d^{commit}; echo $?
1                                    # FAIL — not an ancestor
$ git merge-base --is-ancestor 7b9f0749 2026-08-27-6b88a0d^{commit}; echo $?
1                                    # FAIL — not an ancestor
```

Both targets ARE on main, so the in-flight release will carry them:

```
$ git merge-base --is-ancestor c78504bd origin/main; echo $?
0
$ git merge-base --is-ancestor 7b9f0749 origin/main; echo $?
0
$ git rev-parse origin/main
cb39b65d9cc828b1e8873d1660da4a3408d92906
```

**Correction to a stale sha.** The D29 compile seam (#1446) is
`7b9f0749` on main, not `3a045017` — `git cat-file -t 3a045017`
returns `fatal: Not a valid object name`, so that sha was a
pre-squash branch commit and never landed. Check `7b9f0749`, not
`3a045017`, when judging the seam's chain.

Release run still in flight, unchanged since it started:
`release.yml` run 33040973681, `workflow_dispatch`, head
`cb39b65d9cc828b1e8873d1660da4a3408d92906` (main's tip), started
2026-08-27T04:57:16Z, status `in_progress` as of 05:01Z,
https://github.com/whilp/cosmic/actions/runs/33040973681 . The
previous successful release run took 02:53Z → published 03:28Z
(~35 min), so expect its tag around 05:30Z. Verify against the
actual tag when it appears rather than assuming:

```
git fetch origin --tags
git merge-base --is-ancestor c78504bd <new-tag>^{commit}
git merge-base --is-ancestor 7b9f0749 <new-tag>^{commit}
```

**One pin bump settles two chains.** 3IU62YqO — under the runner-mode
migration container (3IOCdooE) — needs the pin to name a release
carrying the D29 compile seam (#1446, merged 04:40Z), and the same
`cb39b65d` release carries both that and `c78504bd`. Whoever bumps
should do it once, in one PR, and satisfy both items: check both
ancestries against the chosen tag, and say so in the PR body. As of
this measurement neither `c78504bd` nor the seam's `7b9f0749` is an
ancestor of the current pin's tag, so no eligible release exists yet
for either.

## Update at 2026-08-27T05:12Z — the bump is open as PR #1450

The release arrived: `2026-08-27-cb39b65`, published 05:05:27Z, tag
commit `cb39b65d`. Both ancestries check out —
`git merge-base --is-ancestor c78504bd cb39b65d` succeeds, and so does
the same test for `7b9f0749` (#1446's merge, the D29 compile seam that
3IU62YqO needed).

The single bump both items called for is **PR #1450** (branch
`3IU62YqO-pin-bump`), open and in `check` under 3IU62YqO. It is
verified rather than assumed: the artifact's `sha256` matches the
release's own `SHA256SUMS`, a runner-mode probe type-checks clean
under the new binary and fails under the old one, and a cold tree
bootstrapped from the new pin runs `ci: PASS (5 stages)` and
`--make test _build/coldbuild_test.tl` green.

So this item's remaining condition is no longer "wait for a release" —
it is "#1450 merges". When it does, re-run the Result's check against
the merged `bin/cosmic.pin` and end this item; no second bump should
be filed.
