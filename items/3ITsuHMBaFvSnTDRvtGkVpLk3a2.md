## Goal

The first whilp/cosmic release whose tag commit carries main 6b88a0db
(patch-directory mechanism, PR #1424) exists. The daily release cron
(06:00 UTC, release.yml) produces it; dispatching one early is a
human's call. As of 2026-08-27T03:10Z the latest release is
2026-08-27-afad5b5, which predates 6b88a0db (ancestry check fails per
3ITpcO21's spec).

## Result

Done when `git merge-base --is-ancestor 6b88a0db <tag sha>` succeeds
for the newest release tag. End this item then; it exists only so
3ITpcO21 (the pin bump) can carry a real blocker edge instead of being
re-offered by `next` while the release it needs does not exist yet.
