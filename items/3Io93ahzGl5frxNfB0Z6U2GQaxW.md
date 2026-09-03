## Evidence

Found while researching `3InoAi3bSUyDIgESDOlE6CIBbi4` (the sqlite
extension-registry batch-1 extraction-rule item): wiring all five
batch-1 units (`appendvfs base64 base85 completion dbdata`) end to end
into a scratch build and running the real `o//tool/lua/lua.dbg`
against them surfaces a runtime registration failure for `appendvfs`
specifically, unrelated to extraction:

```
$ ./o/tool/lua/lua.dbg -e '
local sqlite3 = require("cosmo.lsqlite3")
local db = assert(sqlite3.open_memory())
print(db:register_extension("appendvfs"))'
nil	not an error	256
```

All other batch-1 units (`base64`, `base85`, `completion`, `dbdata`)
and all 11 already-landed units register cleanly.

Cause: `third_party/sqlite3/appendvfs.c`'s init (the shell.c-inlined
copy, tail of the file) deliberately returns
`SQLITE_OK_LOAD_PERMANENTLY` (`= SQLITE_OK | (1<<8) = 256`) on success
— the standard SQLite convention a VFS-registering extension uses to
tell the loader "keep this VFS installed after the caller resets
`sqlite3_auto_extension`." `db_register_extension` at
`tool/net/lsqlite3.c:1098` only checks `rc != SQLITE_OK` (i.e.
`rc != 0`), so it treats this legitimate success code as a hard
failure and reports the connection's stashed error message for
extended code `256`, which happens to render as SQLite's generic
`"not an error"` string.

This will block the batch-1 landing PR's own gate regardless of how
`3InoAi3b`'s extraction-rule question resolves:
`tool/lua/test_sqlite_register_extension.lua:173`
(`assert(db:register_extension(name))`) fails the moment `appendvfs`
is added to the registry, even with a fully correct extraction.

## Change

`tool/net/lsqlite3.c`'s `db_register_extension` (around line 1098):
treat `rc == SQLITE_OK_LOAD_PERMANENTLY` as success alongside
`rc == SQLITE_OK`, not as a failure. `SQLITE_OK_LOAD_PERMANENTLY` is
an existing, already-`#include`d sqlite3.h constant (extended-result-
code family), so no new definition is needed — only the success check
at the call site widens.

Add a regression case to
`tool/lua/test_sqlite_register_extension.lua` covering `appendvfs`
specifically (or whichever loadable unit is the first
`SQLITE_OK_LOAD_PERMANENTLY`-returning one landed), asserting
`db:register_extension("appendvfs")` returns success rather than
`nil, "not an error", 256`.

`tool/net/definitions.lua`'s existing `@return` annotation for
`register_extension` already documents a `boolean, string` shape;
confirm it needs no change (the fix only widens which underlying `rc`
values map to the documented `true`).

## Non-goals

- Not the batch-1 extraction-rule question itself (`3InoAi3b`) — this
  is a distinct, pre-existing defect in `lsqlite3.c`'s registration
  path, surfaced by wiring `appendvfs` in, not caused by it.
- Not auditing every other extension's init for the same
  `SQLITE_OK_LOAD_PERMANENTLY` pattern beyond confirming the fix is
  general (checks the `rc` value, not the specific extension name).
