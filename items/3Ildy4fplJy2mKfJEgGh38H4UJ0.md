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
record the size delta.

**Corrected 2026-09-02** (item `3In3TXtn`, "h38H_4UJ0's 'remaining
fifteen' list includes backup and recover..."): the original
"remaining fifteen" list named `backup` and `recover`, neither of
which fits the registry's `struct SqliteExtension.init` shape
(`int(sqlite3*, char**, const sqlite3_api_routines*)`) — `backup` has
no `shell.c` ext/misc section at all (`sqlite3_backup_init` is core
SQLite's online-backup API, compiled into `sqlite3.c`, returning
`sqlite3_backup*`); `recover`'s only registry-shaped component
(`sqlite3_dbdata_init`) is already the separately-named `dbdata` unit,
and the rest of its machinery exposes the bespoke
`sqlite3_recover_init(sqlite3*, const char*, const char*)` API, wrong
shape for `kSqliteExtensions[]`. Both are dropped. The corrected,
confirmed set is **13 real units**, each verified directly against
`shell.c`'s Begin/End markers and its own `int sqlite3_<x>_init(...)`
definition:

```
appendvfs base64 base85 completion dbdata decimal fileio ieee sha
shathree sqlar stmtrand uint
```

Measured on #356: extracted units are archive members not yet
linked, so the shipped binary's size moves only by the alias text
until a registration API links them.

**Two registry-name / shell.c-marker mismatches**, both landing in
batch 2 below: `ieee`'s init function (`sqlite3_ieee_init`,
`shell.c:7800`) matches the registry name, but its shell.c section
markers name the source file `ext/misc/ieee754.c`
(`shell.c:7471,7834`); `sha`'s init (`sqlite3_sha_init`,
`shell.c:5625`) likewise matches the registry name, but its markers
name `ext/misc/sha1.c` (`shell.c:5230,5650`). `tool/lua/
test_sqlite_extensions.lua`'s marker lookup (lines 135–158) derives
the shell.c marker directly from the registry name
(`"ext/misc/" .. name .. ".c"`) with no override for this case —
`FROM_SRC_TREE` (line 39) only exempts a unit from marker-matching
entirely (used for `zipfile`, not shell.c-sourced at all), it does
not let a unit's marker differ from its name while still being
checked. Registering `ieee`/`sha` as-is would make the test search
for a nonexistent `ext/misc/ieee.c`/`ext/misc/sha.c` marker and fail.

## Change

Land the 13 real units in three PRs, alphabetical, sizes 5/5/3 (13
does not divide evenly into three fives), each against `master` of
cosmic-lua/cosmopolitan and each green on `make -j$(nproc)
o//tool/lua/test` with the size delta in the PR body:

- Batch 1 (5): `appendvfs base64 base85 completion dbdata`
- Batch 2 (5): `decimal fileio ieee sha shathree`
- Batch 3 (3): `sqlar stmtrand uint`

`fileio` is extracted like the rest and registers nothing; its
default availability is the cosmic API item's decision.

Batch 2's PR must also add a marker-stem override to
`tool/lua/test_sqlite_extensions.lua`, parallel to `FROM_SRC_TREE`
but for "registry name differs from shell.c stem" rather than "not
shell.c at all" — e.g. `local MARKER_STEM = { ieee = "ieee754", sha =
"sha1" }` consulted where the marker string is built (around line
139: `local stem = MARKER_STEM[name] or name`), leaving every other
unit's marker-matching, including the byte-for-byte inlined-copy
assertion, unchanged.

## Non-goals

- Registers nothing; no per-connection API.
- No change to `zipfile`'s unconditional registration.
- No new third-party code.
- Not exposing `backup` or `recover` some other way (e.g. a bespoke
  API surface outside the registry) — that is a new question for
  whoever wants it, not this item.
