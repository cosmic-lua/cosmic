## Goal

G5 — adversarial verification. A child of the salvage container
(`3IOCgCWGhARL1d3P9Cxaw9ICRlj`), sized by the inventory
(`3ISCk9jyvgHUio3gPwQuZkSURUB`). Port the default-mode (non-`literal`)
formatting contract of `cosmo.EncodeJson` and `cosmo.EncodeLua` — pretty
printing, the `indent` option, `maxdepth` enforcement, and the cyclic /
too-deep placeholder spellings — into `tool/lua/`, wired into
`o//tool/lua/test`.

## Evidence

Measured 2026-08-26 against cosmic-lua/cosmopolitan `fe7c36c4` (master),
from the repo root. Inventory rows (`3ISCk9jyvgHUio3gPwQuZkSURUB`):
`test/tool/net/encodejson_test.lua` and `encodelua_test.lua`, both
`none`, both `covered by tool/lua/test_data_formats.lua` in part only.

```text
wc -l test/tool/net/encodejson_test.lua test/tool/net/encodelua_test.lua
# 172  152  324 total
grep -c 'pretty\|indent\|maxdepth\|cyclic' tool/lua/test_data_formats.lua
# 0
```

`tool/lua/test_data_formats.lua` tests `EncodeJson`'s NaN/Infinity
policy, the `null` sentinel, sparse-array handling, and `EncodeLua`'s
NEW `literal=true` refusal domain (reserved-word keys, byte 27,
`mininteger`, cyclic/too-deep *refusal*). It never calls `EncodeJson`
or `EncodeLua` with `{pretty=true}` or `{indent=...}`, never asserts
`maxdepth` enforcement, and never exercises the DEFAULT (non-literal)
placeholder spellings for a cyclic table (`"cyclic@0x%x"`) or excess
depth (`"greatdepth@0"`) that `encodelua_test.lua` pins. Those are the
two encoders' base serialization behavior, still live in the fork
(the C wrapping `cosmo.EncodeLua` gained a `literal` option — see the
top-of-repo commit "EncodeLua: a literal option that refuses what a
literal reader turns down" — it did not remove the default path), and
nothing else in `tool/lua/` exercises it.

`encodejson_test.lua` also spot-checks number spelling
(`123.456e-789 == '0.0'`, `9223372036854775807`,
`-9223372036854775807 - 1`) and object-key sort order — overlapping,
harmlessly, with `test_data_formats.lua`'s own edge-float assertions;
keep the overlap rather than trim it, since the port is a body move,
not a rewrite.

Neither file uses `require`; both call `EncodeJson`/`EncodeLua` and
`unix.pledge` as bare globals.

## Change

Two new files, each with the same two-line prelude:

```lua
local cosmo = require("cosmo")
local unix = require("cosmo.unix")
local EncodeJson, EncodeLua = cosmo.EncodeJson, cosmo.EncodeLua
```

| source | destination |
|---|---|
| `test/tool/net/encodejson_test.lua` | `tool/lua/test_encodejson_default.lua` |
| `test/tool/net/encodelua_test.lua` | `tool/lua/test_encodelua_default.lua` |

Both source files end in a `-- benchmark` comment block plus
`JsonEnc*`/`LuaEnc*`/`bench()` functions used only by the old redbean
benchmark harness (`Benchmark(...)`, which this fork does not carry
under `cosmo.*`) — drop that trailing block from both ported files; it
is dead weight, not assertions, and `Benchmark` has no `cosmo.*`
equivalent to alias it to.

`tool/lua/BUILD.mk:222-251` gets two new three-line rules, e.g.:

```make
o/$(MODE)/tool/lua/test_encodejson_default.ok: o/$(MODE)/tool/lua/lua.dbg tool/lua/test_encodejson_default.lua
	$< tool/lua/test_encodejson_default.lua
	@touch $@
```

...and two new `TOOL_LUA_TESTS` lines.

## Non-goals

- No binding change. If a ported assertion (e.g. an exact
  `maxdepth`-exceeded error string, or the `"greatdepth@0"` placeholder)
  no longer matches the fork's current output, that is evidence to
  update the ASSERTION to match the fork's real, current, frozen
  behavior — never a reason to touch `cosmo.EncodeJson`/`EncodeLua` or
  `tool/net/definitions.lua`.
- Do not touch `test/tool/net/**` or `test/tool/BUILD.mk`; retirement is
  `3IOCgtWA`.
- Do not fold this into `tool/lua/test_data_formats.lua`. The two files
  test different things (contract vs. default-mode formatting); keep
  them separate so each stays under a clear, single-purpose stamp.

## Acceptance

```text
make -j$(nproc) o//tool/lua/test
```

passes; stamp count is 2 higher than before this slice
(`grep -c '^\to/$(MODE)/tool/lua/test_.*\.ok' tool/lua/BUILD.mk`).
`git status --porcelain` in cosmic-lua/cosmopolitan shows only the 2 new
`tool/lua/test_*.lua` files and the `tool/lua/BUILD.mk` diff.
