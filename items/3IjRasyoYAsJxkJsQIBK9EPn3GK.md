## Goal

G3 — `unix.localtime` has NO test coverage at all in the tree, success
or failure (`grep -c localtime tool/lua/test_unix_misc.lua
tool/lua/test_signal.lua tool/lua/test_definitions_conformance.lua`
reports 0 in every file). This capture is now narrowed from its prior
scope: `localtime`'s own C behavior and `definitions.lua` annotation
are fixed by the sibling capture `3IjRaU2dA8zH56DfC1og37HbOug`
(`gmtime`), which — because `gmtime` and `localtime` share one C
helper, `LuaUnixTime` — necessarily updates `localtime`'s
`definitions.lua` entry in the SAME commit as `gmtime`'s. This capture
is BLOCKED BY `3IjRaU2dA8zH56DfC1og37HbOug` and does only the
`localtime`-specific test work once that lands: it adds `localtime`'s
first test, against the `unix.BrokenDownTime` table shape that
capture introduces.

## Evidence

Measured against a live fetch of cosmic-lua/cosmopolitan master
`e028f15b2`, built fresh in `/home/user/wt-7Gbq-census`.

`third_party/lua/cosmo/lunix.c:2862-2864`: `LuaUnixLocaltime` calls
the same shared `LuaUnixTime(L, "localtime", localtime_r)` helper
`LuaUnixGmtime` uses (see `3IjRaU2dA8zH56DfC1og37HbOug`'s Evidence),
swapping `gmtime_r` for `localtime_r`; the success/failure push shapes
are identical, and will be after that capture's fix too.

The current annotation (`tool/net/definitions.lua:7137-7184`) is
identical in shape to `gmtime`'s pre-fix annotation (both declare
`integer|string mon`, `integer|unix.Errno mday`, etc.) — it will
become `unix.BrokenDownTime|nil` once `3IjRaU2dA8zH56DfC1og37HbOug`
lands, since both bindings share the C helper that produces the
value.

`grep -n 'localtime' tool/lua/test_unix_misc.lua
tool/lua/test_signal.lua tool/lua/test_definitions_conformance.lua`:
no match in any of the three today — `localtime` has zero test
coverage in the active build graph. (`test/tool/net/lunix_test.lua`
has a near-duplicate `gmtime` block but is not wired into any
`BUILD.mk` rule and is dead — reported separately as an out-of-scope
finding in this item's own report, not fixed here.)

Probe transcript, from the cosmopolitan repo root (current, pre-fix
shape — will change to a `unix.BrokenDownTime` table once
`3IjRaU2dA8zH56DfC1og37HbOug` lands):

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
the same timestamp, so the success path can be pinned without
depending on the test runner's ambient timezone.)

Cosmic-side spend: `grep -n 'unix.localtime' cosmic/time.tl` →
`cosmic/time.tl:157-162`, the same shape as `gmtime`'s wrapper — see
`3IjRaU2dA8zH56DfC1og37HbOug`'s Evidence. Retiring it is that
capture's sibling consumption slice, not this one's.

## Change

`tool/lua/test_unix_misc.lua` only, appended after the existing
(post-fix) `gmtime` block that `3IjRaU2dA8zH56DfC1og37HbOug` writes:

```lua
-- localtime has no dedicated coverage today (`grep -c localtime
-- tool/lua/test_unix_misc.lua` reports 0 before this change). Pin
-- both paths against the unix.BrokenDownTime table shape
-- 3IjRaU2dA8zH56DfC1og37HbOug introduced for gmtime and localtime
-- together (same LuaUnixTime C helper, tool/net/definitions.lua):
-- TZ=UTC makes the success path degenerate to gmtime's own answer so
-- it can be pinned without depending on the runner's zone.
unix.setenv("TZ", "UTC", true)
local lbdt = assert(unix.localtime(1657297063))
assert(lbdt.year == 2022 and lbdt.mon == 7 and lbdt.mday == 8
  and lbdt.hour == 16 and lbdt.min == 17 and lbdt.sec == 43,
  "localtime(TZ=UTC) must match gmtime's breakdown for the same timestamp")

local lbad, lerr, leno = unix.localtime(9223372036854775807)
assert(lbad == nil, "localtime of an unrepresentable timestamp must report nil")
assert(type(lerr) == "string", "the error must be a string")
assert(leno == unix.EOVERFLOW, "errno must be EOVERFLOW")
```

## Non-goals

- No change to `third_party/lua/cosmo/lunix.c` or
  `tool/net/definitions.lua` — both are the sibling capture's job
  (`3IjRaU2dA8zH56DfC1og37HbOug`), which this one is blocked by.
- No fix to or removal of the dead `test/tool/net/lunix_test.lua`
  fixture — reported separately as an out-of-scope finding, not this
  capture's job.
- No cosmic-side edit — retiring `cosmic/time.tl`'s `localtime`
  wrapper is `3IjRaU2dA8zH56DfC1og37HbOug`'s sibling consumption
  slice, not this one's.
- The `unix.setenv("TZ", "UTC", true)` call is process-global and not
  reset by this test; place this block last in
  `tool/lua/test_unix_misc.lua` (or restore the prior `TZ` value)
  rather than leaving a silent test-order dependency for a later
  `TZ`-sensitive test.

## Acceptance

Run from the cosmopolitan repo root, AFTER
`3IjRaU2dA8zH56DfC1og37HbOug` has landed:

- `make -j$(nproc) o//tool/lua/test` exits 0.
- `grep -c 'localtime' tool/lua/test_unix_misc.lua` reports 1 or more
  (today 0).
- `grep -c 'EOVERFLOW' tool/lua/test_unix_misc.lua` reports 2 (one
  from `3IjRaU2dA8zH56DfC1og37HbOug`'s gmtime block, one from this
  one).

## Enablement

BLOCKED BY `3IjRaU2dA8zH56DfC1og37HbOug` — its C and `definitions.lua`
change (to the shared `LuaUnixTime` helper) must land first, or this
capture's assertions have no `unix.BrokenDownTime` shape to test
against. Once that lands, this capture is a pure test-file append,
parallel-safe with everything else in this batch.
