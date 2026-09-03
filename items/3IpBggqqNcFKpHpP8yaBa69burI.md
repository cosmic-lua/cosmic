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

## Rework (round 2)

Round 1's `request-changes` was against the PR DESCRIPTION only, not the
diff (same head `360524c8`, zero commits since): round 1 found the
description's unqualified "now returns 200" claim didn't hold for a plain
`curl` (default User-Agent) — every route still 500s, because
`.init.lua`'s `OnHttpRequest` unconditionally hits a separate, already-filed
`finger` module bug (`finger` is nil, no `luaopen_finger` registered
anywhere in `tool/net/*.c`) before reaching this PR's fixed call sites; only
`curl -A ''` (suppressed User-Agent) reaches the fixed paths and returns
200. Round 1 explicitly said the CODE was correct and complete.

The builder edited only the PR description (no new commits) to state the
verification precisely: `curl -A ''` gets 200 on `redbean.lua`,
`fetch.lua`, `unix-finger.lua` (405 on `redbean-form.lua` via GET, which is
that handler's own POST-only method gate — 200 on POST), while a normal
request (any User-Agent) still 500s today via the separate `finger` bug,
disclosed as out of scope with its practical blast radius spelled out.

Round 2 independently re-verified from a fresh clone at the same head:
CI green (`build` check, success); single commit, no diff drift; `curl`
with default UA 500s on all four routes with exactly
`attempt to index a nil value (global 'finger')` at `.init.lua:77`; `curl
-A ''` returns 200/200/200 and 405-then-200(POST) respectively; `finger`
is confirmed unregistered anywhere in `tool/net/*.c`/`*.h`; and
`VisualizeControlCodes` is confirmed absent from `redbean.c`'s `kLuaFuncs`
table (the actual registration backing the bare global these demo scripts
called), corroborating `test_cosmo.lua:89`'s removal-list guard for the
`cosmo.*` surface. The corrected description now matches every one of
these observations exactly. Accepted.
