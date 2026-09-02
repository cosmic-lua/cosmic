## Evidence

Reported by the builder of cosmic-lua/cosmopolitan#347. At
`f96adf44`, `third_party/lua/cosmo/lunix.c`'s `LuaUnixIsatty`
(`lunix.c:2955-2965`) checks `rc == -1` after `isatty(fd)` and returns
the `nil, error, errno` tuple on that path — but Cosmopolitan's
`isatty()` returns only 0 or 1 (`libc/calls/isatty.c`: every failure
collapses to 0 with errno set), so the branch is unreachable. That is
why item 3IiFcAtW (PR #307) retyped the annotation to `@return
boolean`, why `help.txt` says `└─→ bool`, and why #347's gate made the
lunix.c comment say the same: three documents now describe a binding
whose source still carries a failure path none of them admit. #307's
spec named the C-side alternative (surface EBADF/EPERM as a real
failure tuple) and deliberately did not adopt it; that stays not
adopted here — the contract `@return boolean` is settled by #307 and
the C follows it. Re-measure at pull time: `sed -n '2950,2966p'
third_party/lua/cosmo/lunix.c` and `grep -n 'return' libc/calls/isatty.c`.

## Change

`third_party/lua/cosmo/lunix.c`, `LuaUnixIsatty`: delete the
unreachable `rc == -1` branch and the `olderr` it exists for, leaving
`lua_pushboolean(L, isatty(fd))`-shaped code with exactly one return
path. Comment lines above it stay as #347 left them (`└─→ bool`). No
`definitions.lua` change, no `help.txt` change: the contract does not
move. `make -j$(nproc) o//tool/lua/test` green; if a test asserts the
old failure tuple from isatty, that test is asserting a path the
binding never took and is fixed to assert `false` — name it in the PR.

## Non-goals

- Not adopting #307's alternative (a failure tuple for EBADF/EPERM);
  that is a contract change and would be its own item with a
  `definitions.lua` + `help.txt` + shape-comment + cosmic regen
  chain.
- No other binding changes.
