## Goal

G5 — adversarial verification. A child of the salvage container
(`3IOCgCWGhARL1d3P9Cxaw9ICRlj`), sized by the inventory
(`3ISCk9jyvgHUio3gPwQuZkSURUB`). Port `cosmo.unix.setenv`,
`unsetenv`, and `clearenv`/`environ` coverage into `tool/lua/`, wired
into `o//tool/lua/test` — none of the three has any test there today.

## Evidence

Measured 2026-08-26 against cosmic-lua/cosmopolitan `fe7c36c4` (master),
from the repo root. Inventory rows (`3ISCk9jyvgHUio3gPwQuZkSURUB`):
`test/tool/net/setenv_test.lua`, `unsetenv_test.lua`, `clearenv_test.lua`
— all `none`, `covered by` `—`.

```text
wc -l test/tool/net/setenv_test.lua test/tool/net/unsetenv_test.lua \
      test/tool/net/clearenv_test.lua
# 42  42  44  128 total
grep -rl 'unix\.\(setenv\|unsetenv\|clearenv\|environ\)' tool/lua/*.lua
# (no output)
```

No `tool/lua/test_*.lua` file calls `unix.setenv`, `unix.unsetenv`,
`unix.clearenv`, or `unix.environ` at all. `setenv_test.lua` covers the
default-overwrite, explicit `overwrite=true`, and `overwrite=false`
(no-op) forms; `unsetenv_test.lua` covers unsetting a set variable, an
already-absent one, and interleaved multi-variable state;
`clearenv_test.lua` covers wiping the whole environment and confirms
`unix.environ()` reports empty afterward, then confirms `setenv` still
works post-clear. None of that three-argument `setenv` overload or the
`clearenv`/`environ` pairing is exercised anywhere else in the fork.

Neither file uses `require`; each calls `unix.setenv`/`unsetenv`/
`clearenv`/`environ`/`pledge` as bare globals and `os.getenv` (a
standard Lua global, unaffected).

## Change

Three new files, each with the same one-line prelude:

```lua
local unix = require("cosmo.unix")
```

| source | destination |
|---|---|
| `test/tool/net/setenv_test.lua` | `tool/lua/test_unix_setenv.lua` |
| `test/tool/net/unsetenv_test.lua` | `tool/lua/test_unix_unsetenv.lua` |
| `test/tool/net/clearenv_test.lua` | `tool/lua/test_unix_clearenv.lua` |

`tool/lua/BUILD.mk:222-251` gets three new three-line rules
(`o/$(MODE)/tool/lua/test_unix_setenv.ok: o/$(MODE)/tool/lua/lua.dbg
tool/lua/test_unix_setenv.lua`, run, `@touch $@`, and the same shape for
the other two), and three new `TOOL_LUA_TESTS` lines.

`clearenv_test.lua` wipes the WHOLE process environment
(`unix.clearenv()`), which — if the test runner shares a process with
later stamps or reuses environment state the runner itself depends on
(`TMPDIR`, `PATH`) — could affect what runs after it in the same
`make` invocation. Confirm each `tool/lua/test_*.ok` rule invokes a
fresh `o/$(MODE)/tool/lua/lua.dbg` process (it does, per the existing
rule shape: `$< tool/lua/test_<name>.lua` is one process per stamp), so
this is inert; note it in the ported file's header comment rather than
silently relying on process isolation nobody wrote down.

## Non-goals

- No binding change. `unix.setenv`/`unsetenv`/`clearenv`/`environ`'s
  signatures and return shapes are frozen.
- Do not touch `test/tool/net/**` or `test/tool/BUILD.mk`; retirement is
  `3IOCgtWA`.
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
