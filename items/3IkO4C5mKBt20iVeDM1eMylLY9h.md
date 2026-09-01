## Evidence

Reported by the builder of cosmic-lua/cosmopolitan#336 (`unix.getpgrp`
retyped to a bare `integer` in `tool/net/definitions.lua`). That item
scoped its Change to the annotation only, so the C side still says the
old shape: `third_party/lua/cosmo/lunix.c:1522-1524` (at #336's head
`5d9048de`) carries the header comment

```
//     ├─→ pgid:int
//     └─→ nil, error:str, errno:int
```

for `LuaUnixGetpgrp`, and the body still routes through `LuaUnixRc0`,
whose `rc == -1` branch is unreachable for `getpgrp(2)` (POSIX: always
successful; Linux implements it as `getpgid(0)`). The #321 precedent
(`sigpending`/`clearenv`) changed both the comment and the C body when
tightening a binding to infallible. Re-locate the lines at pull time
with `grep -n 'LuaUnixGetpgrp' third_party/lua/cosmo/lunix.c`.

## Change

`third_party/lua/cosmo/lunix.c`, `LuaUnixGetpgrp`: replace the two-branch
header comment with the single `├─→ pgid:int` line, and replace the
`LuaUnixRc0` call with a direct `lua_pushinteger(L, getpgrp()); return 1;`
so the function body matches the annotation #336 landed. No
`definitions.lua` change (already exact). Gate: `make -j$(nproc)
o//tool/lua/test` green; the existing `unix.getpgrp` conformance probe
in `tool/lua/test_definitions_conformance.lua` keeps the observed
one-slot shape pinned.

## Non-goals

- No change to `setpgrp`, `setpgid`, `getpgid`, `getsid`, `setsid`, or any
  other `LuaUnixRc0` caller — each has a real failure path.
