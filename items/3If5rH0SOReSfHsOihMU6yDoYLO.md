## Change

Make SQLite's own `ext/misc` extensions available to the library as a named
registry, by extracting the ones already inlined in `shell.c` into standalone
translation units.

Eighteen core-team extensions are already vendored in this tree — `shell.c`
inlines them — and exactly one is reachable from the Lua binary:

```
$ grep -oE "sqlite3_[a-z0-9_]+_init\b" third_party/sqlite3/shell.c | sort -u
sqlite3_appendvfs_init  sqlite3_backup_init   sqlite3_base64_init
sqlite3_base85_init     sqlite3_completion_init sqlite3_dbdata_init
sqlite3_decimal_init    sqlite3_fileio_init   sqlite3_ieee_init
sqlite3_recover_init    sqlite3_regexp_init   sqlite3_series_init
sqlite3_sha_init        sqlite3_shathree_init sqlite3_sqlar_init
sqlite3_stmtrand_init   sqlite3_uint_init     sqlite3_zipfile_init
```

`zipfile` is the precedent and the template: it exists both inlined in `shell.c`
and as `third_party/sqlite3/zipfile.c`, is declared in
`third_party/sqlite3/extensions.h`, and is registered per connection at
`tool/net/lsqlite3.c:2413` (`sqlite3_zipfile_init(db->db, 0, 0)`). This item does
that seventeen more times and adds the registry the per-connection API needs.

### Shape

- One `third_party/sqlite3/<name>.c` per extension, extracted from `shell.c`'s
  copy, added to `THIRD_PARTY_SQLITE3` in `BUILD.mk`.
- Each `sqlite3_<name>_init` declared in `extensions.h` beside `zipfile`'s.
- **A registry**: a static `{const char *name; int (*init)(sqlite3*, char**, const
  sqlite3_api_routines*);}` table, so registration can be by name rather than by a
  hand-written call per extension. This is what makes the cosmic-side vocabulary
  possible; without it every new extension is an edit in two repos.
- **A `---@alias` in `tool/net/definitions.lua`** listing the registry's names as a
  literal union. Cosmic's `_types/gentype.tl` already renders a literal-union alias
  as a real Teal enum (`_types/gentype_alias_test.tl` asserts
  `local enum OpenMode "r" "w" "a" end`), so the cosmic-side extension vocabulary
  is generated, never hand-maintained, and a typo becomes a type error.
- **A test asserting the registry and the alias agree** — same shape as this repo's
  existing annotation-coverage ratchet, and the thing that keeps the two from
  drifting.

### Landing incrementally

The registry plus `series` and `regexp` is the first PR; the remaining extensions
follow in batches. The registry is what unblocks the cosmic side, so it must not
wait on all seventeen extractions.

### One extension deserves a decision, not a default

`fileio` provides `readfile()`, `writefile()` and `fsdir()` — filesystem read and
write callable from SQL. Extract it like the rest, but its presence in the registry
is what makes the cosmic-side default set a security question rather than an
ergonomics one; that argument belongs to the cosmic API item, and this item should
not register anything by default.

Gate: `make -j$(nproc) o//tool/lua/test`, plus the registry/alias agreement test,
plus a size delta per batch — seventeen extensions is not free and G9 ratchets it.

## Non-goals

- **Registers nothing.** Making an extension available is not making it active; the
  per-connection registration API is its own item.
- No behaviour change for `zipfile`'s current unconditional registration; that break
  belongs to the cosmic API item.
- No new third-party code — every byte here is already vendored.
