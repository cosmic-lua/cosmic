`number to integer` is a whole cast bucket a narrowing could delete:
30 sites (measured 2026-08-25: `git ls-files '*.tl' | xargs grep -c
-- "-- cast: number to integer"` summed), e.g.
_tool/testrun.tl:112's `(128 + r.signal) as integer` and
cosmic/errno.tl:121. Teal has no guard that narrows `number` to
`integer` — `math.type(x) == "integer"` checks it at runtime but the
checker learns nothing. Upstream-first per G3: propose the narrowing
to tl; the carried-patch mechanism (3p/tl/tl_patch.tl, applied by
_make/patch.tl, precedent: the assert/nil narrowing) is the
fork-if-blocked vehicle. Scope includes converting the closable
sites and shrinking the bucket in _build/casts_baseline.tl in the
same change, so the ratchet records the win.
