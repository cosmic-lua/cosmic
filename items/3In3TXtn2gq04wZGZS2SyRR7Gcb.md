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
  `dbdata.c` alone (`sqlite3_dbdata_init`, correct signature, confirmed at
  `shell.c:20715`) already accounts for the item separately named
  `dbdata` in `h38H_4UJ0`'s list. The rest of the recover machinery
  exposes a bespoke public API (`sqlite3_recover
  *sqlite3_recover_init(sqlite3*, const char*, const char*)`,
  `third_party/sqlite3/sqlite3.c:19560`) — a different return type and
  argument list than the registry table requires, so it cannot be
  entered in `kSqliteExtensions[]` at all.

## Answer — recorded 2026-09-02

**Corrected list: 13 real units**, confirmed directly against
`third_party/sqlite3/shell.c`'s Begin/End markers and each unit's
`int sqlite3_<x>_init(sqlite3*, char**, const sqlite3_api_routines*)`
definition (verified for all 13; `grep -n "Begin ext\|End ext"
third_party/sqlite3/shell.c` plus per-unit `grep -n "^int
sqlite3_.*_init("` and manual checks for `sha`/`base64`/`base85`, whose
init isn't matched by the first grep's exact pattern):

```
appendvfs base64 base85 completion dbdata decimal fileio ieee sha
shathree sqlar stmtrand uint
```

`backup` and `recover` are dropped entirely — neither is an ext/misc
unit with the registry's init shape (see Evidence above; re-confirmed).
`dbdata` needs no restatement: it already stood on its own in the
original list, sourced from `ext/recover/dbdata.c`'s
`sqlite3_dbdata_init` (shell.c lines 19701–20726), independent of the
bespoke `sqlite3_recover_init` API that `recover` would have named.

**13 does not divide into three batches of five.** Recommended
re-batching, alphabetical, sizes 5/5/3 (closest to the original "three
batches of five" intent):

- Batch 1 (5): `appendvfs base64 base85 completion dbdata`
- Batch 2 (5): `decimal fileio ieee sha shathree`
- Batch 3 (3): `sqlar stmtrand uint`

**Two registry-name / shell.c-marker mismatches, confirmed and located
precisely** (both in batch 2):

- `ieee`: init function is `sqlite3_ieee_init` (`shell.c:7800`, matches
  the registry name exactly — no mismatch there), but the shell.c
  section markers are `/* Begin ext/misc/ieee754.c */` /
  `/* End ext/misc/ieee754.c */` (`shell.c:7471,7834`) — the SOURCE
  FILE is `ieee754.c`, not `ieee.c`.
- `sha`: init function is `sqlite3_sha_init` (`shell.c:5625`, matches
  the registry name exactly), but the section markers are
  `ext/misc/sha1.c` (`shell.c:5230,5650`) — the source file is
  `sha1.c`.

**This is a real gap in `tool/lua/test_sqlite_extensions.lua` as it
stands today**, not just a "resolvable detail" — read closely
(lines 135–158): the test derives the shell.c marker directly from the
registry `name` (`local marker = "ext/misc/" .. name .. ".c"`), with
NO exception mechanism for a name/marker mismatch — `FROM_SRC_TREE`
(line 39) only exempts a unit from marker-matching entirely (used for
`zipfile`, whose source isn't shell.c-derived at all), it does not let
a unit's marker differ from its registry name while still being
matched. Registering `ieee` or `sha` as-is, with their real shell.c
files (`ieee754.c`/`sha1.c`) as `third_party/sqlite3/<name>.c`, would
make the marker lookup search for a nonexistent `ext/misc/ieee.c`/
`ext/misc/sha.c` marker and fail loudly at test time (confirmed by
reading the test's marker-derivation logic directly against the actual
shell.c markers found).

**Required test change (part of whichever batch lands `ieee`/`sha` —
batch 2 above):** add a small marker-stem override table to
`test_sqlite_extensions.lua`, parallel to `FROM_SRC_TREE` but for
"registry name differs from shell.c stem" rather than "not shell.c at
all" — e.g. a `MARKER_STEM = { ieee = "ieee754", sha = "sha1" }` table
consulted when building the marker string at line 139
(`local stem = MARKER_STEM[name] or name`), leaving every other unit's
marker-matching (including the byte-for-byte inlined-copy assertion at
lines 145–157) unchanged.

## Non-goals

- Not deciding whether `backup` or `recover` should be exposed some
  other way (e.g. a bespoke API surface outside the registry) — that is
  a new question if anyone wants it, not this one.
- Not writing the `MARKER_STEM` change itself — that is `h38H_4UJ0`'s
  batch 2 to land, per its own `## Change`.
