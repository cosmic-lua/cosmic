## Goal

G5 — adversarial verification. A child of the salvage container
(`3IOCgCWGhARL1d3P9Cxaw9ICRlj`), sized by the inventory
(`3ISCk9jyvgHUio3gPwQuZkSURUB`). Port `cosmo.path.dirname`/`basename`/
`join`'s value-correctness edge cases, `cosmo.unix.readlink`'s
relative-path and bufsiz-clamping regression coverage, and
`cosmo.Slurp`'s `start`/`end` substring-range reads into `tool/lua/`,
wired into `o//tool/lua/test`.

## Evidence

Measured 2026-08-26 against cosmic-lua/cosmopolitan `fe7c36c4` (master),
from the repo root. Inventory rows (`3ISCk9jyvgHUio3gPwQuZkSURUB`):
`test/tool/net/path_test.lua` (`none`, `covered by
tool/lua/test_definitions_conformance.lua` in part),
`test/tool/net/readlink_test.lua` (`none`, `covered by` `—`),
`test/tool/net/slurp_test.lua` (`none`, `covered by
tool/lua/test_slurp_barf.lua` in part).

```text
wc -l test/tool/net/path_test.lua test/tool/net/readlink_test.lua \
      test/tool/net/slurp_test.lua
# 79  75  53  207 total
```

`tool/lua/test_definitions_conformance.lua` probes
`path.basename`/`dirname`/`join` ONCE each for return-type shape only.
`path_test.lua` is the only place their VALUES are checked across the
edge cases that matter for a path library: trailing slashes
(single/double/triple), `.`/`..` handling, `nil`/empty-string
arguments (several distinct skip-vs-empty-vs-error combinations),
non-string coercion (`path.basename(0)`), and a long-string stress
case. `readlink_test.lua` is a fork-authored (2026) regression test —
already written against `require("cosmo.unix")`/`require("cosmo.path")`
directly, no redbean legacy in it at all — for a specific bug class:
relative-path resolution (not just absolute), and the `bufsiz` clamp
(non-positive → `BUFSIZ`, huge → `0x7ffff000`) not crashing; nothing
else in `tool/lua/` calls `unix.readlink` at all.
`tool/lua/test_slurp_barf.lua` covers `Barf`'s `{mode, append,
offset}` options table and the error-message-names-the-path contract
for both `Slurp` and `Barf`; it never calls `Slurp` with a `start`/`end`
range, which `slurp_test.lua` is the only place doing (several
offset/negative-index combinations against one `'abc123'*5000`
payload).

`path_test.lua` and `slurp_test.lua` use bare globals (no `require`);
`readlink_test.lua` already requires `cosmo.unix`/`cosmo.path` and
needs no prelude at all. `slurp_test.lua` calls `Barf(path, data, 0, 0,
3)` once, using the OLD positional-argument form (mode, append,
offset) the fork replaced with an options table
(`tool/lua/test_slurp_barf.lua`'s own header: "Barf takes an options
table {mode, append, offset} instead of the old positional flags
footgun") — that one call becomes `Barf(path, 'XX', {offset = 3})` on
the way over; every other assertion in the file (the `Slurp` range
reads) moves verbatim.

`path_test.lua` also has two assertions (`assert(nil == path.join(nil))`,
`assert(nil == path.join(nil, nil))`) that contradict `path.join`'s
CURRENT, frozen contract: `tool/net/lpath.c:78-118`'s `LuaPathJoin`
raises `"missing argument"` on an all-nil call rather than returning
`nil`, already asserted the new way in
`tool/lua/test_definitions_conformance.lua:390-391`
(`assert(not pcall(path.join, nil), "join(nil) must raise")` and the
two-nil equivalent). Running the two `path_test.lua` lines as literally
written against the current `o/tool/lua/lua.dbg` fails both. Resolved
(`3IfEKZQg`): adapt the two lines to the pcall form on the way over,
the same adaptation class as the `Barf` call above — a still-live
function's calling convention changed, not a binding change.

## Change

| source | destination | prelude |
|---|---|---|
| `test/tool/net/path_test.lua` | `tool/lua/test_path_values.lua` | `local cosmo = require("cosmo")` / `local unix = require("cosmo.unix")` / `local path = require("cosmo.path")` |
| `test/tool/net/readlink_test.lua` | `tool/lua/test_unix_readlink.lua` | none — already requires what it needs |
| `test/tool/net/slurp_test.lua` | `tool/lua/test_slurp_ranges.lua` | `local cosmo = require("cosmo")` / `local unix = require("cosmo.unix")` / `local Slurp, Barf = cosmo.Slurp, cosmo.Barf` |

`slurp_test.lua`'s single positional `Barf(...)` call (line 34 of the
source) becomes `Barf(Path('foo'), 'XX', {offset = 3})` in the ported
file; every other line moves unchanged.

`path_test.lua`'s two `assert(nil == path.join(nil[, nil]))` lines
become:

```lua
assert(not pcall(path.join, nil), "join(nil) must raise")
assert(not pcall(path.join, nil, nil), "join(nil, nil) must raise")
```

every other assertion in the file (all `dirname`/`basename` cases,
every other `join` case including the long-string stress case and the
numeric-coercion case) moves unchanged.

`tool/lua/BUILD.mk:222-251` gets three new three-line rules
(`o/$(MODE)/tool/lua/test_path_values.ok: o/$(MODE)/tool/lua/lua.dbg
tool/lua/test_path_values.lua`, run, `@touch $@`, and the equivalent
for `test_unix_readlink` and `test_slurp_ranges`), and three new
`TOOL_LUA_TESTS` lines.

## Non-goals

- No binding change. `path.dirname`/`basename`/`join`, `unix.readlink`,
  and `Slurp`'s range semantics are frozen; the adapted `Barf` call and
  the two adapted `path.join(nil[, nil])` assertions move to their
  CURRENT calling convention because the OLD form no longer behaves
  that way — that is a syntax adaptation of a still-live function, not
  a binding change.
- Do not touch `test/tool/net/**` or `test/tool/BUILD.mk`; retirement is
  `3IOCgtWA`.
- Do not touch `tool/lua/test_slurp_barf.lua` or
  `test_definitions_conformance.lua`; these three files are new,
  standing alongside them.
- Do not merge the three files; each is a distinct binding and stays
  under its own stamp.

## Acceptance

```text
make -j$(nproc) o//tool/lua/test
```

passes; stamp count is 3 higher than before this slice
(`grep -c '^\to/$(MODE)/tool/lua/test_.*\.ok' tool/lua/BUILD.mk`).
`git status --porcelain` in cosmic-lua/cosmopolitan shows only the 3 new
`tool/lua/test_*.lua` files and the `tool/lua/BUILD.mk` diff.
