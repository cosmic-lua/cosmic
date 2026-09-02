## Evidence

cosmic-lua/cosmopolitan#356 (item 3If5rH0S) landed the sqlite
extension registry with `regexp`, `series` and the pre-existing
`zipfile` — three of the eighteen core-team extensions `shell.c`
inlines. The registry's agreement test (`tool/lua/test_sqlite_
extensions.lua`) pins each unit to its `shell.c` section and the
`---@alias lsqlite3.Extension` union to the registry, so each further
batch is: extract N units by the same rule, add them to
`THIRD_PARTY_SQLITE3_A_SRCS`/`_OBJS`, declare their inits in
`extensions.h`, append them to the registry and the alias, and
record the size delta. Remaining fifteen: appendvfs backup base64
base85 completion dbdata decimal fileio ieee recover sha shathree
sqlar stmtrand uint. Measured on #356: extracted units are archive
members not yet linked, so the shipped binary's size moves only by
the alias text until a registration API links them.

## Change

Land the remaining fifteen in three PRs of five, alphabetical, each
against `master` of cosmic-lua/cosmopolitan and each green on
`make -j$(nproc) o//tool/lua/test` with the size delta in the PR
body. `fileio` is extracted like the rest and registers nothing;
its default availability is the cosmic API item's decision.

## Non-goals

- Registers nothing; no per-connection API.
- No change to `zipfile`'s unconditional registration.
- No new third-party code.
