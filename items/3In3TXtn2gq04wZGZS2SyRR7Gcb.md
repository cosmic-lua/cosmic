## Question

`h38H_4UJ0`'s "remaining fifteen" ext/misc units to extract names `backup`
and `recover`, both of which the builder found do not fit the sqlite
extension registry's `struct SqliteExtension.init` shape
(`int(sqlite3*, char**, const sqlite3_api_routines*)`). What should the
corrected batch list be, and does `recover`'s `dbdata.c` component (which
DOES fit) still count as the separately-named `dbdata` unit or as part of
`recover`?

## Evidence

Found by the builder of `h38H_4UJ0` while attempting batch 1 (`appendvfs
backup base64 base85 completion`):

- `backup` has no inlined section in `shell.c` at all:
  `grep -n "Begin ext.*backup" third_party/sqlite3/shell.c` returns
  nothing. `sqlite3_backup_init` (`third_party/sqlite3/sqlite3.c:10070`,
  `:84970`) is core SQLite's online-backup API, compiled directly into
  `sqlite3.c` — not one of the ext/misc loadable extensions `shell.c`
  inlines — and it returns `sqlite3_backup*`, not the registry's expected
  `int` signature. There is no unit here to extract.
- `recover` doesn't fit either: `shell.c` does inline
  `ext/recover/sqlite3recover.c`/`.h` and `ext/recover/dbdata.c`, but
  `dbdata.c` alone (`sqlite3_dbdata_init`, correct signature) already
  accounts for the item separately named `dbdata` in `h38H_4UJ0`'s list.
  The rest of the recover machinery exposes a bespoke public API
  (`sqlite3_recover *sqlite3_recover_init(sqlite3*, const char*, const
  char*)`, `third_party/sqlite3/sqlite3.c:19560`) — a different return
  type and argument list than the registry table requires, so it cannot
  be entered in `kSqliteExtensions[]` at all.
- Cross-checked, the other 13 named units (`appendvfs base64 base85
  completion dbdata decimal fileio ieee sha shathree sqlar stmtrand
  uint`) do correspond to real, extractable ext/misc-style units. Two
  have a `shell.c` section name that differs from the registry stem
  (`ieee` from `ext/misc/ieee754.c`, `sha` from `ext/misc/sha1.c`), which
  the agreement test's marker-matching would need a small exception
  table for — same shape as the existing `FROM_SRC_TREE` exception for
  `zipfile` — a resolvable implementation detail, not a blocker.

13 real units do not divide evenly into three batches of five as
`h38H_4UJ0`'s `## Change` specifies.

## Change

Correct `h38H_4UJ0`'s spec: drop `backup` and `recover` from the
"remaining fifteen," settle whether `dbdata` needs any restatement given
`recover`'s removal, and re-batch the 13 real remaining units (three
batches, sizes need not stay 5/5/5 — e.g. 5/4/4 or 5/5/3) alphabetically,
noting the `ieee`/`sha` marker-name exception the agreement test will
need.

## Non-goals

- Not deciding whether `backup` or `recover` should be exposed some
  other way (e.g. a bespoke API surface outside the registry) — that is
  a new question if anyone wants it, not this one.
