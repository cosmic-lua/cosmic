# Problem

A cosmic executable is queryable and writable through SQL today —
verified 2026-08-24 against the release binary (cosmos
2026.08.14-c3201810e): `SELECT name, sz FROM zipfile('<exe>')` from
`cosmic.sqlite` enumerates all 554 zip members, `CAST(data AS TEXT)`
extracts them, and on a copy `CREATE VIRTUAL TABLE z USING
zipfile('<copy>')` followed by `INSERT INTO z(name, data) VALUES
('hello.txt', ...)` produces a binary that still runs and serves the
new member at /zip/hello.txt; `DELETE FROM z WHERE name LIKE
'docs/%'` also leaves a working binary (the file grows ~23KB — zipfile
appends a fresh central directory, no vacuum). Nothing in the cosmic
tree pins any of this: the registration is one silent line in the fork
(tool/net/lsqlite3.c:2413 calling sqlite3_zipfile_init), so an
upstream merge or refactor could drop the whole capability and no gate
would notice. A `cosmic/sqlite/` test file exercising
read/insert/delete against a copied artifact (each test gets
TEST_TMPDIR) would freeze the contract the docs item demonstrates.
