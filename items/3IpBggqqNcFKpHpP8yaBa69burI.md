## Evidence

Found as an out-of-scope discovery while building board item `e2c2_GEaY`
(docs: sweep help.txt, redbean demo and AGENTS.md for shapes the bundling
PRs changed, PR cosmic-lua/cosmopolitan#375).

`tool/net/demo/.init.lua`'s `OnHttpRequest` and several sibling demo scripts
(`redbean.lua`, `redbean-form.lua`, `fetch.lua`, `unix-finger.lua`) call a
bare global `VisualizeControlCodes(...)` that no longer exists as a
`cosmo.*` binding — `tool/lua/test_cosmo.lua:89` documents its deliberate
removal, and `tool/net/help.txt:1809` still documents it as a plain global.

Confirmed live: running the built `redbean-demo` binary and issuing an HTTP
request that reaches the demo handler 500s with
`attempt to call a nil value (global 'VisualizeControlCodes')` — breaking
every demo page that formats a user string through it.

## Change

Restore `VisualizeControlCodes` (as a `cosmo.*` binding, matching
`help.txt:1809`'s documented shape) or remove every demo caller and the
`help.txt` entry, whichever the repo's binding-removal history in
`test_cosmo.lua:89` says was intended — the fix should make
`tool/net/demo/.init.lua`'s `OnHttpRequest` and the four sibling demo
scripts (`redbean.lua`, `redbean-form.lua`, `fetch.lua`,
`unix-finger.lua`) stop referencing a nonexistent global, and keep
`help.txt` in sync with whichever direction is chosen.

## Non-goals

Not a re-litigation of why the binding was removed (if it was) — this item
is about the demo scripts and `help.txt` now being inconsistent with
whatever the current `cosmo.*` surface actually provides, discovered via a
live 500 on the built binary.
