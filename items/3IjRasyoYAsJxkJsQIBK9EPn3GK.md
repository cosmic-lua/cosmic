## Goal

G3 — `unix.localtime`'s declared failure shape is already honest,
identical in structure to `unix.gmtime`'s (CAP-5) — but unlike
`gmtime`, `localtime` has NO test coverage at all in the tree today,
success or failure. This capture adds both.

## Evidence

Measured against cosmic-lua/cosmopolitan master `275b73b1d`.

`third_party/lua/cosmo/lunix.c:2844-2849`: `LuaUnixLocaltime` calls
the same shared `LuaUnixTime(L, "localtime", localtime_r)` helper
`LuaUnixGmtime` uses (CAP-5), swapping `gmtime_r` for `localtime_r`;
the success/failure push shapes are identical.

The annotation (`tool/net/definitions.lua:7150-7166`) already declares
this honestly, in the same shape as `gmtime`'s:

```
---@param unixts integer
---@return integer|nil year nil when the call failed
---@return integer|string mon 1 ≤ mon ≤ 12, or the error string when the
--- call failed — failure returns exactly `nil, error, errno`, so its two
--- values land in the slots mon and mday occupy on success, not in slots
--- of their own past `zone`
---@return integer|unix.Errno mday 1 ≤ mday ≤ 31, or the errno when the
--- call failed
...
function unix.localtime(unixts) end
```

`grep -n 'localtime' tool/lua/test_unix_misc.lua
tool/lua/test_signal.lua tool/lua/test_definitions_conformance.lua`:
no match in any of the three — `localtime` has zero test coverage in
the active build graph. (`test/tool/net/lunix_test.lua` does have a
near-duplicate `gmtime` block but is not wired into any `BUILD.mk`
rule and is dead — reported separately as an out-of-scope finding,
not fixed here.)

Probe transcript, from the cosmopolitan repo root:

```
$ o//tool/lua/lua -e '
local unix = require("unix")
unix.setenv("TZ", "UTC", true)
print(unix.localtime(1657297063))
print(unix.localtime(9223372036854775807))
'
2022	7	8	16	17	43	0	5	188	0	UTC
nil	localtime: EOVERFLOW: Overflow error	75
```

(With `TZ=UTC`, `localtime` degenerates to `gmtime`'s own answer for
the same timestamp — the same values `tool/lua/test_unix_misc.lua:37-44`
already asserts for `gmtime(1657297063)` — so the success path can be
pinned without depending on the test runner's ambient timezone. The
failure shape is identical to `gmtime`'s: `year` nil, `mon` the error
string, `mday` the errno `75`.)

Cosmic-side spend: `grep -n 'unix.localtime' cosmic/time.tl` →
`cosmic/time.tl:157-162`, the same shape as `gmtime`'s wrapper
(CAP-5): `local year, mon, mday, ... = unix.localtime(unixts) if year
== nil then ... return nil, errno.format(mon as string, "localtime")
end`.

## Change

`tool/lua/test_unix_misc.lua` only, appended after the existing
gmtime block (and, if CAP-5 lands first, after its new
gmtime-failure block too — either order is fine, both append at the
same point):

```lua
-- localtime has no dedicated coverage today (`grep -c localtime
-- tool/lua/test_unix_misc.lua` reports 0 before this change). Pin
-- both paths: TZ=UTC makes it degenerate to gmtime's own answer so
-- the success path is exercised without depending on the runner's
-- zone, and the failure shape mirrors gmtime's exactly (same
-- LuaUnixTime C helper, tool/net/definitions.lua).
unix.setenv("TZ", "UTC", true)
local lyear, lmon, lmday, lhour, lmin, lsec =
  assert(unix.localtime(1657297063))
assert(lyear == 2022 and lmon == 7 and lmday == 8 and lhour == 16
  and lmin == 17 and lsec == 43,
  "localtime(TZ=UTC) must match gmtime's breakdown for the same timestamp")

local loy, lom, lod = unix.localtime(9223372036854775807)
assert(loy == nil, "localtime of an unrepresentable timestamp must report nil year")
assert(type(lom) == "string",
  "the error string must land in the slot mon occupies on success")
assert(lod == unix.EOVERFLOW,
  "errno must land in the slot mday occupies on success")
```

## Non-goals

- No change to `third_party/lua/cosmo/lunix.c` or
  `tool/net/definitions.lua` — both are already correct.
- No fix to or removal of the dead `test/tool/net/lunix_test.lua`
  fixture — reported separately as an out-of-scope finding, not this
  capture's job.
- No addition to the pure-function `PROBES` ratchet in
  `tool/lua/test_definitions_conformance.lua` — `localtime` reads the
  `TZ` environment variable and the on-disk zoneinfo database, so it
  is not the "zero-risk... no side effects" binding that file scopes
  itself to.
- No cosmic-side edit — `cosmic/time.tl`'s wrapper already
  destructures and branches on exactly this shape; nothing there
  changes.
- The `unix.setenv("TZ", "UTC", true)` call is process-global and not
  reset by this test; flagged here so the implementer places this
  block last in `tool/lua/test_unix_misc.lua` (or restores the prior
  `TZ` value), rather than leaving a silent test-order dependency for
  a later `TZ`-sensitive test.

## Acceptance

Run from the cosmopolitan repo root:

- `make -j$(nproc) o//tool/lua/test` exits 0.
- `grep -c 'localtime' tool/lua/test_unix_misc.lua` reports 1 or more
  (today 0).
- `grep -c 'EOVERFLOW' tool/lua/test_unix_misc.lua` reports 2 once
  both this capture and CAP-5 have landed (1 if only this one has).

## Enablement

none needed. Independent of CAP-5 in content (different binding,
different C function) though both append to the same file — whichever
merges second rebases a short append; the `TZ` non-goal above is the
only real interaction to watch.
