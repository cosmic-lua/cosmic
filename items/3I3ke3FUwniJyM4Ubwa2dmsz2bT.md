Item `3I06cBmI` ("land's merge failures are indistinguishable: a 403 permission
refusal needs its own branch") was imported from whilp/cosmic#1190 with a spec
sidecar refined against the pre-migration `main`-branch `_work/` layout
(`_work/github.tl` with `merge_pull`, `_work/implementer.tl`'s `cmd_land`,
`_work/implementer_test.tl`, `_work/model.tl`, `_work/verdict.tl`, all pinned
to commit `a3cd318`). That layout no longer exists anywhere: `a3cd318` is an
ancestor of `origin/main`, not of the orphan `board` branch, and `origin/main`
today carries no `_work/` directory at all — the machinery migrated to the
`board` branch's own architecture (`_work/gh.tl`'s `merge(s, number)` and
`_work/gitland.tl`'s `cmd_land(s, id, force, why)`, built around
`store.Store` and `gate.verdict_line`, not the old design's plain strings).
Every fact command in the spec's facts block fails or reports something
different against the real `board`-branch tree. An implementer session
(2026-08-17) confirmed the mismatch is total, not a partial ambiguity, and
bounced the item back to `plan` rather than improvising a redesign.

Refining this item again needs someone to re-derive the "Change" section
against `_work/gh.tl` / `_work/gitland.tl` as they exist on `board` today,
and to decide how the frozen "verdict vocabulary" concept (`work-land:
REFUSED/ERROR/success`) maps onto `gitland.tl`'s actual `gate.verdict_line`
convention, since the two are not the same string shapes.
