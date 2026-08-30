## Goal

G5 — adversarial verification. A child of the salvage container
(`3IOCgCWGhARL1d3P9Cxaw9ICRlj`), sized by the inventory
(`3ISCk9jyvgHUio3gPwQuZkSURUB`). Port `lsqlite3.Database:readonly()`
and `lsqlite3.Statement:readonly()` coverage into `tool/lua/`, wired
into `o//tool/lua/test`. No `tool/lua/test_*.lua` file exercises
`lsqlite3` at all today.

## Evidence

Measured 2026-08-26 against cosmic-lua/cosmopolitan `fe7c36c4` (master),
from the repo root. Inventory row (`3ISCk9jyvgHUio3gPwQuZkSURUB`):
`test/tool/net/sqlite_test.lua`, `none`, `covered by` `—`.

```text
wc -l test/tool/net/sqlite_test.lua
# 31
ls tool/lua/test_sqlite*.lua 2>&1
# ls: cannot access 'tool/lua/test_sqlite*.lua': No such file or directory
grep -c 'lsqlite3' tool/lua/test_cosmo.lua
# 1
```

`tool/lua/test_cosmo.lua`'s one `lsqlite3` line only asserts
`require("cosmo.lsqlite3")` returns a table — no method is ever
called. `sqlite_test.lua` is the only place `db:readonly()` and
`st:readonly()` (statement-level readonly detection: a `select`
statement is readonly, an `insert` is not) are exercised at all,
including the `db:readonly("main")` named-database form and the
`db:readonly("foo")` unknown-database-name form (returns `nil`). This
is real, small, distinct coverage of a `lsqlite3` binding
`test_definitions_coverage.lua`'s own annotation ratchet lists
(`dblib`/`vmlib` methods) but that ratchet, by its own documented
scope, checks only that the method is ANNOTATED — never that it
behaves correctly.

The file uses `require "lsqlite3"` (old bare-name style, no dot); the
fork registers the same module at `cosmo.lsqlite3`.

## Change

One new file, `tool/lua/test_sqlite_readonly.lua`, from
`test/tool/net/sqlite_test.lua`, with its one `require` line changed:

```lua
local sqlite3 = require("cosmo.lsqlite3")
```

(replacing the source's `local sqlite3 = require "lsqlite3"` — every
other line, including the `file:/memdb1?vfs=memdb` URI-mode opens and
the `db:exec`/`db:prepare` calls, moves unchanged).

`tool/lua/BUILD.mk:222-251` gets one new three-line rule
(`o/$(MODE)/tool/lua/test_sqlite_readonly.ok: o/$(MODE)/tool/lua/lua.dbg
tool/lua/test_sqlite_readonly.lua`, run, `@touch $@`) and one new
`TOOL_LUA_TESTS` line.

## Non-goals

- No binding change. `db:readonly()`/`st:readonly()`'s return shapes
  are frozen.
- Do not touch `test/tool/net/**` or `test/tool/BUILD.mk`; retirement is
  `3IOCgtWA`.
- Do not expand this into a broader `lsqlite3` test suite; port exactly
  what `sqlite_test.lua` asserts. A fuller `lsqlite3` coverage gap (if
  one exists beyond `readonly()`) is a separate finding, not this
  slice's scope.

## Acceptance

```text
make -j$(nproc) o//tool/lua/test
```

passes; stamp count is 1 higher than before this slice
(`grep -c '^\to/$(MODE)/tool/lua/test_.*\.ok' tool/lua/BUILD.mk`).
`git status --porcelain` in cosmic-lua/cosmopolitan shows only the new
`tool/lua/test_sqlite_readonly.lua` file and the `tool/lua/BUILD.mk`
diff.
