## Goal

`lsqlite3.Database:serialize()` must return the database's serialized
bytes (or `nil` on an empty schema, per its own doc comment) without
crashing the process. Today it crashes on every successful call.

## Evidence

- C source: `tool/net/lsqlite3.c:1773-1784`:
  ```c
  static int db_serialize(lua_State *L) {
      sdb *db = lsqlite_checkdb(L, 1);
      sqlite_int64 size = 0;
      char *buffer = (char *)sqlite3_serialize(db->db, "main", &size, 0);
      if (buffer == NULL)
          return pusherrstr(L, "failed to serialize");
      lua_pushlstring(L, buffer, size);
      free(buffer);          /* line 1782: BUG */
      return 1;
  }
  ```
  `sqlite3_serialize()` documents its return value as normally
  allocated with `sqlite3_malloc()`, freed with `sqlite3_free()` — not
  libc `free()`. Line 1782 calls libc `free()` on a buffer sqlite3's
  own allocator owns, corrupting cosmopolitan's dlmalloc heap.
- `tool/net/definitions.lua:921-924`:
  ```
  --- Serialize a database to be restored later with `Database:deserialize`.
  ---@return string? -- `nil` if the database has no tables
  ---@nodiscard
  function lsqlite3.Database:serialize() end
  ```
- Probe (from the cosmopolitan repo root, `o//tool/lua/lua` built by
  `make -j$(nproc) o//tool/lua/lua`):
  ```
  $ o//tool/lua/lua -e 'local s=require("cosmo.lsqlite3"); local db=s.open_memory(); print(db:serialize())'
  Segmentation fault (exit 139)
  ```
  Reproduces on a freshly opened, completely empty in-memory database
  (no `CREATE TABLE` at all) and on a populated one alike — every
  successful call to `serialize()` crashes.
- gdb backtrace (`gdb -batch -ex run -ex bt --args o//tool/lua/lua.dbg
  probe.lua`, `ulimit -c unlimited`):
  ```
  Program received signal SIGSEGV, Segmentation fault.
  __mspace_free (msp=0x0, mem=0x7ffff7e43148) at third_party/dlmalloc/dlmalloc.c:926
  926	    if (!ok_magic(fm)) {
  #0  __mspace_free (...) at third_party/dlmalloc/dlmalloc.c:926
  #1  0x00000000042339d0 in db_serialize (L=...) at tool/net/lsqlite3.c:1782
  ```
  `msp=0x0` — the freed pointer does not belong to the Lua-side
  dlmalloc mspace at all, confirming the allocator mismatch.
- cosmic-side spend: `grep -rn 'serialize' cosmic/` — zero call sites.
  The crash is latent from cosmic's current public surface (no
  `cosmic.sqlite` API calls this binding) but live for anyone who
  reaches `require("cosmo.lsqlite3")` directly, and a landmine for any
  future backup/restore feature built on it.

## Change

In `tool/net/lsqlite3.c`, change line 1782 from `free(buffer);` to
`sqlite3_free(buffer);`. Re-run the probe above (and a populated-DB
variant) to confirm no crash, and confirm the returned string content
is correct (a valid SQLite serialization) on a populated database,
plus that `nil` is returned (not "failed to serialize" masking a
crash) for a genuinely empty schema. `definitions.lua`'s declared type
(`string?`, one return value) is a separate, secondary gap — see
"Non-goals" — but should be corrected if this capture's PR touches
the doc comment anyway (`db_serialize`'s failure path returns TWO
values, `nil, "failed to serialize"`, which the current `@return`
line does not mention at all).

## Non-goals

- Do not fold in the separate tuple-completeness question (the
  `@return string?` annotation dropping the second value that
  `pusherrstr` actually pushes on the `buffer == NULL` path) as a
  blocking requirement — note it, fix it if convenient, but the crash
  fix is the point of this capture.
- No change to `db_deserialize` (`tool/net/lsqlite3.c:1786-1798`,
  guarded by the same `SQLITE_ENABLE_DESERIALIZE`) unless inspection
  during the fix turns up the same allocator mismatch there — if so,
  say so in the PR rather than silently expanding scope.

## Acceptance

- `make -j$(nproc) o//tool/lua/test` passes.
- `db:serialize()` on an empty in-memory db returns `nil` (or the
  correct string) without crashing.
- A populated-database `serialize()` call returns a non-crashing,
  correctly-sized byte string.
- `tool/lua/test_definitions_conformance.lua` and
  `tool/lua/test_definitions_coverage.lua` still pass (annotation
  coverage/shape ratchets for `lsqlite3`).
