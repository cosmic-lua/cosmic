# Problem

The vendored SQLite compiles the zipfile virtual table
(third_party/sqlite3/zipfile.c, registered on every connection by
tool/net/lsqlite3.c:2413) but not FTS5: on the released binary
(cosmos 2026.08.14-c3201810e), `CREATE VIRTUAL TABLE d USING
fts5(name, body)` fails with `no such module: fts5`. That blocks the
natural pairing measured 2026-08-24: full-text search over a cosmic
executable's own embedded docs is two statements once FTS5 exists —
`CREATE VIRTUAL TABLE docs USING fts5(name, body)` then `INSERT INTO
docs SELECT name, CAST(data AS TEXT) FROM zipfile('<exe>') WHERE name
LIKE '%.md'` (the zipfile read half runs today: 554 members
enumerated from the release binary via `SELECT name, sz FROM
zipfile(...)`). Candidate change: add `-DSQLITE_ENABLE_FTS5` to
THIRD_PARTY_SQLITE3 flags in third_party/sqlite3/BUILD.mk (JSON1,
DESERIALIZE, SESSION are already enabled there, lines 133-136);
verify `make o//tool/lua/test` and measure binary size delta, since
FTS5 is a nontrivial amount of code carried by every cosmic artifact.
