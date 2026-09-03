## Evidence

Found as an out-of-scope discovery while building board item `Ba69_burI`
(demo: `VisualizeControlCodes` global gone but redbean/fetch/unix-finger
demos and `help.txt` still reference it, PR cosmic-lua/cosmopolitan#378).

`tool/net/demo/.init.lua`'s `OnHttpRequest` calls
`finger.GetSynFingerOs(finger.FingerSyn(syn))` without ever requiring or
defining a `finger` module — no `luaopen_finger` binding exists anywhere
in this tree. This 500s independently with `attempt to index a nil
value (global 'finger')`, confirmed live in the built `redbean-demo`
binary (built via `make -j$(nproc) o//tool/net/redbean-demo`).

The same pattern (missing `finger = require 'finger'`, or a removed
binding never cleaned up downstream) appears in
`tool/net/demo/finger.lua` and in `help.txt`'s FINGER MODULE section's
own worked example (around line 2538) — this looks like the same class
of "demo/help.txt drifted from a removed/renamed binding" bug as
`Ba69_burI`, but for a different symbol (`finger.*` instead of
`VisualizeControlCodes`).

## Change

Same shape as `Ba69_burI`: determine whether `finger.*` is a binding
that was removed and never cleaned up downstream (check binding-removal
history the way `tool/lua/test_cosmo.lua:89` documented
`VisualizeControlCodes`'s removal) or one that was never wired up in
the demo despite being documented. Fix `tool/net/demo/.init.lua`,
`tool/net/demo/finger.lua`, and `help.txt`'s FINGER MODULE section to
be consistent with whichever direction the binding's actual state
supports — restore the binding, or remove the demo/`help.txt`
references, matching `Ba69_burI`'s resolution pattern.

## Non-goals

Not `VisualizeControlCodes` itself — that's `Ba69_burI`, already
resolved. Not a broader audit of every demo script for drifted
bindings beyond `finger.*`.
