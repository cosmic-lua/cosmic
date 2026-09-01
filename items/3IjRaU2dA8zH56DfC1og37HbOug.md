## Goal

G3 — `unix.gmtime`'s declared failure shape is already honest
(`mon`/`mday` are `integer|string`/`integer|unix.Errno`,
tool/net/definitions.lua:7101-7107), documenting the same class of
sharing this census names — but no test in the tree exercises the
failure path: `tool/lua/test_unix_misc.lua`'s only `gmtime` coverage
is the success path. This capture adds the missing regression
coverage; it changes no contract.

## Evidence

Measured against cosmic-lua/cosmopolitan master `275b73b1d`.

`third_party/lua/cosmo/lunix.c:2813-2842`: `LuaUnixGmtime` calls the
shared `LuaUnixTime(L, "gmtime", gmtime_r)` helper (line 2841). On
success it pushes 11 values (lines 2820-2830); on failure (`gmtime_r`
returns NULL) it calls `LuaUnixSysretErrno(L, "gmtime", olderr)` —
exactly 3 values.

The annotation (`tool/net/definitions.lua:7100-7117`) already declares
this honestly:

```
---@param unixts integer
---@return integer|nil year nil when the call failed
---@return integer|string mon 1 ≤ mon ≤ 12, or the error string when the
--- call failed — failure returns exactly `nil, error, errno`, so its two
--- values land in the slots mon and mday occupy on success, not in slots
--- of their own past `zone`
---@return integer|unix.Errno mday 1 ≤ mday ≤ 31, or the errno when the
--- call failed
---@return integer hour 0 ≤ hour ≤ 23
...
```

Probe transcript, from the cosmopolitan repo root:

```
$ o//tool/lua/lua -e 'local unix=require("unix") print(unix.gmtime(9223372036854775807))'
nil	gmtime: EOVERFLOW: Overflow error	75
```

(3 values: `year` nil as declared, `mon` holds the error STRING,
`mday` holds errno `75` (`unix.EOVERFLOW`).)

`grep -n 'gmtime' tool/lua/test_unix_misc.lua tool/lua/test_signal.lua
tool/lua/test_definitions_conformance.lua`: only
`tool/lua/test_unix_misc.lua:37` (the one success-path assertion
block, `year,mon,mday,... = assert(unix.gmtime(1657297063))`); no
failure-path test exists.

Cosmic-side spend: `grep -n 'unix.gmtime' cosmic/time.tl` →
`cosmic/time.tl:127-132`, `local year, mon, mday, ... =
unix.gmtime(unixts) if year == nil then -- On failure the binding
returns (nil, err, errno): the error string -- arrives in the slot
mon occupies on success. return nil, errno.format(mon as string,
"gmtime") end` — a live wrapper coded against exactly this shape, with
an explicit `as string` cast on the shared slot.

## Change

`tool/lua/test_unix_misc.lua` only, appended after the existing
gmtime success block (currently lines 36-44):

```lua
-- gmtime's one reachable failure (a timestamp gmtime_r cannot
-- represent, EOVERFLOW) shares two return slots with its own success
-- breakdown (tool/net/definitions.lua); pin that shape live.
local goy, gom, god = unix.gmtime(9223372036854775807)
assert(goy == nil, "gmtime of an unrepresentable timestamp must report nil year")
assert(type(gom) == "string",
  "the error string must land in the slot mon occupies on success")
assert(god == unix.EOVERFLOW,
  "errno must land in the slot mday occupies on success")
```

## Non-goals

- No change to `third_party/lua/cosmo/lunix.c` or
  `tool/net/definitions.lua` — both are already correct.
- No addition to the pure-function `PROBES` ratchet in
  `tool/lua/test_definitions_conformance.lua` — kept in the same file
  as its sibling CAP-6 (`localtime`, which is not side-effect-free, as
  it reads `TZ` and the on-disk zoneinfo database) rather than split
  across two suites for a pair that shares one C helper
  (`LuaUnixTime`) and one annotation shape.
- No cosmic-side edit — `cosmic/time.tl`'s wrapper already
  destructures and branches on exactly this shape; nothing there
  changes.

## Acceptance

Run from the cosmopolitan repo root:

- `make -j$(nproc) o//tool/lua/test` exits 0.
- `grep -c 'EOVERFLOW' tool/lua/test_unix_misc.lua` reports 1 or more
  (today 0).

## Enablement

none needed. Independent of every other capture; touches only
`tool/lua/test_unix_misc.lua`, appended after the existing gmtime
block. Parallel-safe with CAP-6, which appends to the same file at a
different point (after its own new localtime block; either merge
order is fine).
