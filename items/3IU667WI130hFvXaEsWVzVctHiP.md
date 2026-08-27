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
