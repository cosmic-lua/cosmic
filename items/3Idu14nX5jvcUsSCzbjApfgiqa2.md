## Goal

G5 — adversarial verification. A child of the salvage container
(`3IOCgCWGhARL1d3P9Cxaw9ICRlj`), sized by the inventory
(`3ISCk9jyvgHUio3gPwQuZkSURUB`). Port real fork+exec coverage for
`cosmo.unix.execvp`/`execvpe`/`fexecve` and `cosmo.unix.daemon` into
`tool/lua/`, wired into `o//tool/lua/test`.

## Evidence

Measured 2026-08-26 against cosmic-lua/cosmopolitan `fe7c36c4` (master),
from the repo root. Inventory rows (`3ISCk9jyvgHUio3gPwQuZkSURUB`):
`test/tool/net/execvp_test.lua` (`none`, `covered by
tool/lua/test_unix_proc.lua` in part) and `test/tool/net/daemon_test.lua`
(`none`, `covered by` `—`).

```text
wc -l test/tool/net/execvp_test.lua test/tool/net/daemon_test.lua
# 126  67  193 total
grep -c 'execvp\|daemon' tool/lua/test_unix_proc.lua
# 1
```

`tool/lua/test_unix_proc.lua` tests `unix.spawn`/`spawnp` (fork +
`fexecve`-under-the-hood via the C helper) and `unix.daemon` is not
mentioned there at all; its one `execvp` line is a single error-path
call at the very end (`unix.execvp("nonexistent...")` → `nil, err`).
`execvp_test.lua` covers that same error path for `execvp`,
`execvpe`, and `fexecve` individually, PLUS three real fork+exec
success paths not tested anywhere else in `tool/lua/`: `execvp`
replacing the child with `/bin/true` (exit-code check), `execvpe`
passing a CUSTOM environment through to a `sh -c 'exit
${MY_EXIT_CODE:-1}'` child (proving env propagation, not just PATH
lookup), and `execvp` with multiple `argv` entries (`sh -c 'exit 7'`).
`daemon_test.lua` is the only place `unix.daemon` is exercised at all —
it forks, calls `unix.daemon(true, true)` in the child, and confirms a
marker file gets written after daemonizing.

Neither file uses `require`; both call `unix.*` functions as bare
globals.

## Change

Two new files, each with the same one-line prelude:

```lua
local unix = require("cosmo.unix")
```

| source | destination |
|---|---|
| `test/tool/net/execvp_test.lua` | `tool/lua/test_unix_execvp.lua` |
| `test/tool/net/daemon_test.lua` | `tool/lua/test_unix_daemon.lua` |

`tool/lua/BUILD.mk:222-251` gets two new three-line rules
(`o/$(MODE)/tool/lua/test_unix_execvp.ok: o/$(MODE)/tool/lua/lua.dbg
tool/lua/test_unix_execvp.lua`, run, `@touch $@`, and the equivalent for
`test_unix_daemon`), and two new `TOOL_LUA_TESTS` lines.

`daemon_test.lua`'s marker-file wait (`unix.nanosleep(0, 200000000)`,
200ms) is a real, if generous, timing assumption already present in the
source; carry it as-is — the file already treats a missing marker as a
printed warning rather than a hard failure, so it is not flaky by
construction, just slow-by-a-fifth-of-a-second in the worst case.

## Non-goals

- No binding change. `unix.execvp`/`execvpe`/`fexecve`/`daemon`'s
  signatures and return shapes are frozen.
- Do not touch `test/tool/net/**` or `test/tool/BUILD.mk`; retirement is
  `3IOCgtWA`.
- Do not fold either file into `tool/lua/test_unix_proc.lua`. Each ports
  as its own file under its own stamp; the pre-existing
  `test_unix_proc.lua` is untouched by this slice.

## Acceptance

```text
make -j$(nproc) o//tool/lua/test
```

passes; stamp count is 2 higher than before this slice
(`grep -c '^\to/$(MODE)/tool/lua/test_.*\.ok' tool/lua/BUILD.mk`).
`git status --porcelain` in cosmic-lua/cosmopolitan shows only the 2 new
`tool/lua/test_*.lua` files and the `tool/lua/BUILD.mk` diff.
