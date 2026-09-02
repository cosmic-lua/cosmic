## Goal

`tool/net/demo/unix-subprocess.lua` and `tool/net/demo/unix-unix.lua`
save `unix.sigaction`'s previous disposition and later pass it back as
the handler argument to restore it. PR #338 changed `unix.sigaction`'s
success return from 3 positional values to one `unix.SignalAction`
table; both demos still destructure/pass the old shape, so after #338
merges, running either demo raises
`bad argument #2 to 'sigaction' (sigaction handler not integer or
function)` at the restore call.

## Evidence

Found and reproduced during review of board item `e615_d4Lc`
(`unix.sigaction` table fix, PR #338, cosmic-lua/cosmopolitan) — the
PR's own author held this out of scope (the demos are un-gated, not
run by `make -j$(nproc) o//tool/lua/test` or any CI target) and the
reviewer independently confirmed the exact failure by running the
demos against the PR-head-built `o//tool/lua/lua.dbg`:

```
bad argument #2 to 'sigaction' (sigaction handler not integer or function)
```

Call sites (at PR #338's head, `3fa52539b`):
- `tool/net/demo/unix-subprocess.lua:13-14, 24-25, 50-51`
- `tool/net/demo/unix-unix.lua:12-13`

Each saves `oldX = assert(unix.sigaction(SIG, SIG_IGN))` (now a table,
not the previous handler value) and later calls
`unix.sigaction(SIG, oldX)` to restore it — passing a table where the
binding now expects the OLD handler shape (integer or function), read
from the new table's `.handler` field.

## Change

In both files, change each restore call's argument from the saved
value directly to its `.handler` field — e.g.
`unix.sigaction(SIGINT, oldint)` → `unix.sigaction(SIGINT, oldint.handler)`
— at every call site listed above. No other change; this is the same
one-line fix `tool/lua/test_unix_misc.lua` already applied in #338 for
its own consumer.

## Non-goals

- No change to `unix.sigaction`'s binding or annotation — #338 already
  landed those.
- No change to any other demo or test file.

## Acceptance

- Both demos run to completion without the `sigaction handler not
  integer or function` error, against a tree carrying #338.
- `make -j$(nproc) o//tool/lua/test` still passes (these files are not
  gated by it, so this only confirms no regression elsewhere).
