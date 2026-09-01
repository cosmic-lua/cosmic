## Goal
Same as the `unix.gmtime` capture, for `unix.localtime` — its failure
tuple reuses the success shape's `mon`/`mday` slots for the error
string and errno, sharing `LuaUnixTime` with `gmtime`. Blocked on the
`unix.nanosleep` archetype item (`3IivGU58CJHrof9ObOc0YFjout2`) so the
fix mechanism is decided once and applied uniformly.

## Evidence
- C source: shared helper `LuaUnixTime`, `third_party/lua/cosmo/lunix.c:2808-2830`;
  entry point `unix.localtime` at `lunix.c:2842-2844` (measured at
  cosmic-lua/cosmopolitan master `fd0884d91eeaa2cd5659125282c1699e91bef715`):
  ```c
  static int LuaUnixLocaltime(lua_State *L) {
    return LuaUnixTime(L, "localtime", localtime_r);
  }
  ```
- `tool/net/definitions.lua:7149-7165` — identical `@return` shape to
  `gmtime`'s, applied to `unix.localtime(unixts)`.
- Probe:
  ```
  $ o//tool/lua/lua -e 'local unix=require"unix"; print(unix.localtime(9223372036854775807))'
  nil	localtime: EOVERFLOW: Overflow error	75
  ```
- cosmic-side spend, `grep -rn 'unix\.localtime' cosmic/`:
  ```
  cosmic/time.tl:158:  unix.localtime(unixts)
  ```
  `cosmic/time.tl`'s `localtime()` (around line 148-166) has the
  identical destructure-and-cast shape as `gmtime()`:
  `return nil, errno.format(mon as string, "localtime") -- cast: tuple element`

## Change
Same as the `unix.gmtime` capture — apply whatever fix (or documented
exception) board item `3IivGU58CJHrof9ObOc0YFjout2` settles on.

## Non-goals
Same as the `unix.gmtime` capture; this capture and that one may be
combined into one PR by the goal owner since both route through
`LuaUnixTime`, but are filed separately per the "each deviation gets
its own capture" rule.

## Acceptance
Same as the `unix.gmtime` capture, applied to `unix.localtime` and
`cosmic/time.tl`'s `localtime()`.
