## Goal

G5 — adversarial verification. A child of the salvage container
(`3IOCgCWGhARL1d3P9Cxaw9ICRlj`), sized by the inventory
(`3ISCk9jyvgHUio3gPwQuZkSURUB`). Port `cosmo.unix.pledge`'s real
sandbox-enforcement test (fork a child, sandbox it, violate it, confirm
the kernel kills it), plus `dup`/`dup2`, `gmtime`, ranged
`open`/`fstat`/`ftruncate`/`lseek`/`read`/`write`, `copy_file_range`,
and `opendir`/getdents into `tool/lua/`, wired into `o//tool/lua/test`.
None of these is tested anywhere in the fork today.

## Evidence

Measured 2026-08-26 against cosmic-lua/cosmopolitan `fe7c36c4` (master),
from the repo root. Inventory row (`3ISCk9jyvgHUio3gPwQuZkSURUB`):
`test/tool/net/lunix_test.lua`, `none`, `covered by
tool/lua/test_signal.lua tool/lua/test_unix_proc.lua` in part.

```text
wc -l test/tool/net/lunix_test.lua
# 191
grep -c 'pledge\|copy_file_range\|opendir\|gmtime\|dup(' tool/lua/*.lua
# (no matches across tool/lua/*.lua)
```

`tool/lua/test_signal.lua` covers `sigaction`/`sigprocmask`/`sigset`
dispatch but never `sigsuspend`; `tool/lua/test_unix_proc.lua` covers
`spawn`/`spawnp`/`execvp` but never `dup`/`dup2`. Nothing in
`tool/lua/` calls `unix.pledge` with an actual violation-and-kill check
(a real fork, `unix.pledge("stdio")`, then a forbidden `unix.socket()`
call, confirming the child dies by `SIGSYS`/`SIGABRT`) — that is the
single most important assertion in this file for a project whose own
build system runs every recipe fenced by default (`AGENTS.md`: "every
build here runs fenced by default"). `gmtime`, ranged
`open`/`fstat`/`ftruncate`/`lseek`/`read(fd, n, offset)`/
`write(fd, s, n)`, `copy_file_range` (including its short-copy/ENOSYS
fallback path), and `opendir`/getdents iteration are each tested
nowhere else either.

The one `:errno()` call in the file
(`assert(err:errno() == unix.EINTR)` after a `sigsuspend` that is
EXPECTED to be interrupted) needs adapting: the fork's `unix.sigsuspend`
returns `nil, err:string, errno:integer` on that same interruption
(same contract `tool/lua/test_unix_errno.lua` pins for every failing
`unix.*` call), so the ported line reads the errno POSITIONALLY —
`local ok, err, errno = unix.sigsuspend(oldmask); assert(errno ==
unix.EINTR)` — rather than calling a method that no longer exists.
Every other assertion in the file is unrelated to that contract and
moves unchanged.

The file uses no `require`; it calls `unix.*` as a bare global
throughout.

## Change

One new file, `tool/lua/test_unix_misc.lua`, from
`test/tool/net/lunix_test.lua`, with:

```lua
local unix = require("cosmo.unix")
```

...and the `sigsuspend` interruption check rewritten from
`assert(err:errno() == unix.EINTR)` to read the errno positionally
from `unix.sigsuspend`'s own third return value, per the fork's
`nil, err:string, errno:integer` failure contract (see Evidence).
Every other line — `strsignal`, `gmtime`, `dup`/`dup2`, the
`fork`+`wait`+exit-code check, the `pledge` violation-and-kill child,
the ranged file-I/O block, `copy_file_range` and its `ENOSYS`
fallback branch, and the `opendir`/getdents listing — moves unchanged.

`tool/lua/BUILD.mk:222-251` gets one new three-line rule
(`o/$(MODE)/tool/lua/test_unix_misc.ok: o/$(MODE)/tool/lua/lua.dbg
tool/lua/test_unix_misc.lua`, run, `@touch $@`) and one new
`TOOL_LUA_TESTS` line.

## Non-goals

- No binding change. `unix.pledge`, `unix.sigsuspend`'s return shape,
  `unix.copy_file_range`, and every other function this file calls are
  frozen; the one rewritten line adapts to the CURRENT, still-live
  `unix.sigsuspend` contract, it does not change it.
- Do not touch `test/tool/net/**` or `test/tool/BUILD.mk`; retirement is
  `3IOCgtWA`.
- Do not touch `tool/lua/test_signal.lua` or `test_unix_proc.lua`; this
  is a new, complementary file, not a merge into either.
- Do not split this file's content across multiple destination files.
  It is one source file with one verdict row in the inventory; it ports
  as one file, even though its content spans several `unix.*`
  sub-surfaces.

## Acceptance

```text
make -j$(nproc) o//tool/lua/test
```

passes; stamp count is 1 higher than before this slice
(`grep -c '^\to/$(MODE)/tool/lua/test_.*\.ok' tool/lua/BUILD.mk`).
`git status --porcelain` in cosmic-lua/cosmopolitan shows only the new
`tool/lua/test_unix_misc.lua` file and the `tool/lua/BUILD.mk` diff.
The `pledge` violation child specifically exits by `SIGSYS` (Linux) or
`SIGABRT`, proving real kernel enforcement, not a stub.
