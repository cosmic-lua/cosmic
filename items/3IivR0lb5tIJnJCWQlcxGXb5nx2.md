## Goal
G3, via cosmo-contracts: `unix.gmtime`'s failure tuple reuses the
success shape's `mon`/`mday` slots for the error string and errno —
same defect family as `unix.nanosleep`'s archetype (board item
`3IivGU58CJHrof9ObOc0YFjout2`). Unlike `unix.setitimer`/
`unix.sigaction`, this one IS already honestly annotated (the union is
declared), but the underlying contract issue — a positional slot
serving two incompatible purposes across success and failure — is
unresolved, matching what makes nanosleep itself "still captured"
despite its own honest annotation. Blocked on the archetype item so
the fix mechanism is decided once and applied uniformly.

## Evidence
- C source: shared helper `LuaUnixTime`, `third_party/lua/cosmo/lunix.c:2808-2830`;
  entry point `unix.gmtime` at `lunix.c:2835-2837` (measured at
  cosmic-lua/cosmopolitan master `fd0884d91eeaa2cd5659125282c1699e91bef715`):
  ```c
  static int LuaUnixGmtime(lua_State *L) {
    return LuaUnixTime(L, "gmtime", gmtime_r);
  }
  ```
  Success pushes 11 values (year..zone); failure
  (`lunix.c:2827-2829`) calls `LuaUnixSysretErrno` — the standard
  3-value triple, landing in `year`/`mon`/`mday`'s positions.
- `tool/net/definitions.lua:7099-7116`:
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
  ---@return integer min 0 ≤ min ≤ 59
  ---@return integer sec 0 ≤ sec ≤ 60
  ---@return integer gmtoffsec ±93600 seconds
  ---@return integer wday 0 ≤ wday ≤ 6
  ---@return integer yday 0 ≤ yday ≤ 365
  ---@return integer dst 1 if daylight savings, 0 if not, -1 if unknown
  ---@return string zone
  ---@nodiscard
  function unix.gmtime(unixts) end
  ```
- Probe (a timestamp `gmtime_r` cannot represent — EOVERFLOW):
  ```
  $ o//tool/lua/lua -e 'local unix=require"unix"; print(unix.gmtime(9223372036854775807))'
  nil	gmtime: EOVERFLOW: Overflow error	75
  ```
- cosmic-side spend, `grep -rn 'unix\.gmtime' cosmic/`:
  ```
  cosmic/time.tl:128:  unix.gmtime(unixts)
  ```
  `cosmic/time.tl`'s `gmtime()` (around line 118-136) destructures the
  full 11-value success arity and on `year == nil` writes:
  `return nil, errno.format(mon as string, "gmtime") -- cast: tuple element`
  — a justified narrowing cast working around the exact deviation this
  capture documents; the module's own header comment explains gmtime
  and localtime "each destructure their own binding" precisely because
  of this shape.

## Change
This is the same underlying contract shape as `unix.nanosleep`'s
archetype: apply whatever fix board item `3IivGU58CJHrof9ObOc0YFjout2`
lands on (a return arity that never overlaps a real success value's
position, or a documented, accepted exception) to `gmtime`/`localtime`
equally. Land the `cosmic/time.tl` cast-removal (or justification)
alongside.

## Non-goals
- Does not re-litigate `unix.clock_gettime` (#277) — a different
  function, already settled.
- Does not itself resolve `unix.localtime` — filed as its own sibling
  capture sharing the same implementation and evidence pattern; the
  goal owner may choose to combine both into one PR since both route
  through `LuaUnixTime`, but they are filed separately per this
  item's "each deviation gets its own capture" rule.

## Acceptance
- Whatever contract fix `3IivGU58CJHrof9ObOc0YFjout2` settles on is
  applied identically to `gmtime` (or the shape is formally accepted as
  unfixable/by-design, in which case this capture closes as "won't
  fix, documented").
- `make -j$(nproc) o//tool/lua/test` passes.
- `cosmic/time.tl`'s `gmtime()` (and its test) pass under `--make ci`,
  with its narrowing cast removed if the underlying shape changes, or
  left in place with an updated comment if the record is "won't fix."
