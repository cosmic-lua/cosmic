## Change

Decide which of SQLite's compile-time features the vendored library build enables,
and enable them in `third_party/sqlite3/BUILD.mk`.

The source already ships: the amalgamation carries FTS5 and RTREE gated behind
their flags (`grep -c fts5 third_party/sqlite3/sqlite3.c` = 2764). What is missing
is the flag, and only on the library — `THIRD_PARTY_SQLITE3_FLAGS` (the block
applied to `THIRD_PARTY_SQLITE3_A_OBJS`) carries JSON1, math functions,
DESERIALIZE, PREUPDATE_HOOK, SESSION and BATCH_ATOMIC_WRITE, while
`SQLITE_ENABLE_FTS3/4/5`, `RTREE`, `GEOPOLY`, `DBSTAT_VTAB` and friends appear
only in the **shell's** private CFLAGS block below it.

Measured on the shipped binary, so this is what a cosmic program sees today:

```
fts5    no — no such module: fts5        json1   AVAILABLE
fts4    no — no such module: fts4        math    AVAILABLE
rtree   no — no such module: rtree
geopoly no — no such module: geopoly
dbstat  no — no such module: dbstat
```

### The decision this item makes

Not "add `-DSQLITE_ENABLE_FTS5`" but "which of these earn their bytes", because
every flag is carried by every cosmic artifact and G9 ratchets exactly that. The
candidates, in descending order of obvious value:

- **FTS5** — full-text search. The pairing that motivates it: search over a cosmic
  executable's own embedded docs is two statements once FTS5 exists,
  `CREATE VIRTUAL TABLE docs USING fts5(name, body)` then
  `INSERT INTO docs SELECT name, CAST(data AS TEXT) FROM zipfile('<exe>') WHERE
  name LIKE '%.md'`. The zipfile half runs today (554 members enumerated from a
  release binary).
- **RTREE / GEOPOLY** — spatial indexing. Real capability, narrower audience.
- **DBSTAT_VTAB** — introspection of page usage; small, useful for tooling.
- **FTS3/FTS4** — superseded by FTS5; enable only if something needs them.

**The deciding measurement is the size delta per flag**, taken separately, not as a
bundle: build `o//tool/lua/lua` with each flag added on its own and record the
byte delta, then decide. A flag whose delta is large and whose audience is narrow
is the one to leave off, and the numbers are what make that arguable rather than
asserted.

Gate: `make -j$(nproc) o//tool/lua/test` passes, and the probe above reports
`AVAILABLE` for each enabled feature.

## Non-goals

- No new third-party code. Everything here is already vendored.
- No registration API. Compile-time features are present on every connection by
  construction; the opt-in vocabulary is a separate item and treats these as
  capabilities to *verify*, never to enable.
