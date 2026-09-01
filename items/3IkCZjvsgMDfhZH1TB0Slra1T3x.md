## Goal

`unix.getsockopt`'s `SOL_SOCKET`/`SO_LINGER` overload silently drops
its `seconds` return value — a success-path arity bug found while
classifying the unix sockets/network census slice. A caller following
the documented two-value overload gets only one value back, with the
values shifted (the boolean lands where the integer was expected).

## Evidence

`third_party/lua/cosmo/lunix.c:2139-2148` — inside `LuaUnixGetsockopt`,
the `SOL_SOCKET`/`SO_LINGER` branch:

```c
// ├─→ seconds:int, enabled:bool
...
lua_pushinteger(L, l.l_linger);
lua_pushboolean(L, l.l_onoff);
...
return 1;
```

pushes two values (`l.l_linger` then `l.l_onoff`) but then executes
`return 1;`, so only the top-of-stack value (`l_onoff`, the `enabled`
boolean) actually reaches the caller — `seconds` is silently dropped.
This contradicts both the inline comment two lines above
(`// ├─→ seconds:int, enabled:bool`) and the
`tool/net/definitions.lua:6277` `@overload` annotation
(`seconds: integer, enabled: boolean`).

Probe (re-run yourself against current master):
```
$ o//tool/lua/lua -e '
local unix = require("unix")
local fd = assert(unix.socket(unix.AF_INET, unix.SOCK_STREAM))
assert(unix.setsockopt(fd, unix.SOL_SOCKET, unix.SO_LINGER, 5, true))
local a, b, c = unix.getsockopt(fd, unix.SOL_SOCKET, unix.SO_LINGER)
print("a=", a, "b=", b, "c=", c)
'
a=	true	b=	nil	c=	nil
```
(`a` here is the dropped-arity `enabled` boolean, not `seconds` — the
value ordering the doc declares first is missing entirely, and the one
value that does come through arrives in the wrong position relative to
the documented two-value shape.)

## Change

In `LuaUnixGetsockopt`'s `SOL_SOCKET`/`SO_LINGER` branch
(`third_party/lua/cosmo/lunix.c:2139-2148`), change `return 1;` to
`return 2;` so both pushed values (`seconds`, `enabled`) reach the
caller, matching the existing inline comment and the
`tool/net/definitions.lua:6277` `@overload` annotation exactly (no
annotation change needed — the annotation was already correct; only
the C return count was wrong).

## Non-goals

- No change to any other `unix.getsockopt`/`unix.setsockopt` overload
  — this is scoped to the `SO_LINGER` branch alone.
- No change to `tool/net/definitions.lua` — its `@overload` annotation
  for this case is already correct; the C implementation just wasn't
  honoring it.
- No re-litigating the sockets/network census's classification work —
  this is a success-path arity bug, unrelated to nil-admission.

## Acceptance

- `unix.getsockopt(fd, unix.SOL_SOCKET, unix.SO_LINGER)` returns
  exactly 2 values on success: `seconds` (integer) then `enabled`
  (boolean), matching the documented overload.
- A regression test (wherever this repo's existing
  `getsockopt`/`setsockopt` coverage lives — check first) pins both
  values and their order for the `SO_LINGER` case.
- `make -j$(nproc) o//tool/lua/test` passes.
