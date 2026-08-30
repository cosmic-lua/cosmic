## Goal

G5 — adversarial verification. A child of the salvage container
(`3IOCgCWGhARL1d3P9Cxaw9ICRlj`), sized by the inventory
(`3ISCk9jyvgHUio3gPwQuZkSURUB`). Port `cosmo.unix.getlogin`,
`cosmo.unix.uname`, and `cosmo.unix.tcgetattr`/`tcsetattr` coverage
into `tool/lua/`, wired into `o//tool/lua/test` — none of the three has
any test there today.

## Evidence

Measured 2026-08-26 against cosmic-lua/cosmopolitan `fe7c36c4` (master),
from the repo root. Inventory rows (`3ISCk9jyvgHUio3gPwQuZkSURUB`):
`test/tool/net/getlogin_test.lua`, `uname_test.lua`, `tcattr_test.lua`
— all `none`, `covered by` `—`.

```text
wc -l test/tool/net/getlogin_test.lua test/tool/net/uname_test.lua \
      test/tool/net/tcattr_test.lua
# 45  36  141  222 total
grep -rl 'unix\.\(getlogin\|uname\|tcgetattr\|tcsetattr\)' tool/lua/*.lua
# (no output)
```

No `tool/lua/test_*.lua` file calls any of these four functions.
`getlogin_test.lua` checks the login-name format and cross-references
`LOGNAME`/`USER` where present, tolerating a `nil` result (no
controlling terminal) rather than failing on it. `uname_test.lua`
checks every documented `unix.uname()` field is a non-empty string and
that two calls agree. `tcattr_test.lua` is the most substantial: it
checks the termios constants exist, that `tcgetattr`/`tcsetattr` fail
correctly on a non-tty (`/dev/null`) and an invalid fd, and — when a
`/dev/ptmx` pty is available — a full get/set/verify/modify round-trip
including toggling `ECHO` off and reading it back, plus `TCSADRAIN`
and `TCSAFLUSH` apply modes and a partial-table `tcsetattr` call.

None of the three files uses `require`; each calls `unix.*` as a bare
global.

## Change

Three new files, each with the same one-line prelude:

```lua
local unix = require("cosmo.unix")
```

| source | destination |
|---|---|
| `test/tool/net/getlogin_test.lua` | `tool/lua/test_unix_getlogin.lua` |
| `test/tool/net/uname_test.lua` | `tool/lua/test_unix_uname.lua` |
| `test/tool/net/tcattr_test.lua` | `tool/lua/test_unix_tcattr.lua` |

`tool/lua/BUILD.mk:222-251` gets three new three-line rules (same shape
as the existing entries: `o/$(MODE)/tool/lua/test_unix_getlogin.ok:
o/$(MODE)/tool/lua/lua.dbg tool/lua/test_unix_getlogin.lua`, run,
`@touch $@`, and the equivalent for `test_unix_uname` and
`test_unix_tcattr`), and three new `TOOL_LUA_TESTS` lines.

`tcattr_test.lua`'s pty-dependent block is already conditional on
`unix.open("/dev/ptmx", ...)` succeeding, with a printed skip note
otherwise — carry that structure verbatim; do not make the pty
assertions unconditional, since a CI runner without a pty device must
still pass.

## Non-goals

- No binding change. `unix.getlogin`/`uname`/`tcgetattr`/`tcsetattr`'s
  signatures and return shapes are frozen.
- Do not touch `test/tool/net/**` or `test/tool/BUILD.mk`; retirement is
  `3IOCgtWA`.
- Do not merge the three files; each is a distinct binding surface and
  stays under its own stamp.

## Acceptance

```text
make -j$(nproc) o//tool/lua/test
```

passes; stamp count is 3 higher than before this slice
(`grep -c '^\to/$(MODE)/tool/lua/test_.*\.ok' tool/lua/BUILD.mk`).
`git status --porcelain` in cosmic-lua/cosmopolitan shows only the 3 new
`tool/lua/test_*.lua` files and the `tool/lua/BUILD.mk` diff.
