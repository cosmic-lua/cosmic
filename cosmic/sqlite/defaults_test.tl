#!/usr/bin/env cosmic
--- Tests for the per-connection defaults sqlite.open() applies
--- (foreign_keys=ON, WAL journal mode with synchronous=NORMAL) and
--- their Options opt-outs. busy_timeout coverage lives in
--- data_test.tl.

local check = require("cosmic.check")
local sqlite = require("cosmic.sqlite")
local fs = require("cosmic.fs")

local TEST_TMPDIR = os.getenv("TEST_TMPDIR")

-- foreign_keys default

local function test_foreign_keys_enforced_by_default()
  local db = check.must(sqlite.open(":memory:"))
  assert(db:exec("CREATE TABLE parent (id INTEGER PRIMARY KEY)"))
  assert(db:exec("CREATE TABLE child (pid INTEGER REFERENCES parent(id))"))
  local ok, err = db:exec("INSERT INTO child (pid) VALUES (?)", {42})
  assert(not ok, "dangling reference should fail with foreign_keys on")
  assert(err and err:match("FOREIGN KEY constraint failed"),
    "error should name the FOREIGN KEY constraint, got: " .. tostring(err))
  assert(db:close())
end
test_foreign_keys_enforced_by_default()

local function test_foreign_keys_opt_out()
  local db = check.must(sqlite.open(":memory:", {foreign_keys = false}))
  assert(db:exec("CREATE TABLE parent (id INTEGER PRIMARY KEY)"))
  assert(db:exec("CREATE TABLE child (pid INTEGER REFERENCES parent(id))"))
  local ok, err = db:exec("INSERT INTO child (pid) VALUES (?)", {42})
  assert(ok, "foreign_keys=false should restore raw behavior: " .. tostring(err))
  assert(db:close())
end
test_foreign_keys_opt_out()

-- WAL + synchronous defaults

local function test_wal_default_on_file_db()
  local path = fs.join(TEST_TMPDIR, "wal_default.db")
  local db = check.must(sqlite.open(path))
  local mode = check.must(db:query_one("PRAGMA journal_mode")).journal_mode
  assert(mode == "wal", "file db should default to WAL, got: " .. tostring(mode))
  local sync = check.must(db:query_one("PRAGMA synchronous")).synchronous
  assert(sync == 1, "WAL default should set synchronous=NORMAL(1), got: " .. tostring(sync))
  assert(db:close())
end
test_wal_default_on_file_db()

local function test_wal_opt_out()
  local path = fs.join(TEST_TMPDIR, "wal_optout.db")
  local db = check.must(sqlite.open(path, {wal = false}))
  local mode = check.must(db:query_one("PRAGMA journal_mode")).journal_mode
  assert(mode == "delete", "wal=false should keep the rollback journal, got: " .. tostring(mode))
  local sync = check.must(db:query_one("PRAGMA synchronous")).synchronous
  assert(sync == 2, "wal=false should keep synchronous=FULL(2), got: " .. tostring(sync))
  assert(db:close())
end
test_wal_opt_out()

local function test_memory_db_ignores_wal()
  local db = check.must(sqlite.open(":memory:"))
  local mode = check.must(db:query_one("PRAGMA journal_mode")).journal_mode
  assert(mode == "memory", "in-memory db keeps journal_mode=memory, got: " .. tostring(mode))
  assert(db:exec("CREATE TABLE t (v TEXT)"))
  assert(db:exec("INSERT INTO t (v) VALUES (?)", {"x"}))
  assert(db:close())
end
test_memory_db_ignores_wal()

local function test_read_only_skips_wal()
  local path = fs.join(TEST_TMPDIR, "ro_defaults.db")
  local db = check.must(sqlite.open(path, {wal = false}))
  assert(db:exec("CREATE TABLE t (v TEXT)"))
  assert(db:exec("INSERT INTO t (v) VALUES (?)", {"hello"}))
  assert(db:close())

  local rdb = check.must(sqlite.open(path, {read_only = true}))
  local mode = check.must(rdb:query_one("PRAGMA journal_mode")).journal_mode
  assert(mode == "delete", "read-only open must not switch journal mode, got: " .. tostring(mode))
  local row = check.must(rdb:query_one("SELECT v FROM t"))
  assert(row and row.v == "hello", "read-only handle should read data")
  assert(rdb:close())
end
test_read_only_skips_wal()

local function test_wal_readers_not_blocked_by_writer()
  -- WAL persists in the file, so the second connection shares it; a
  -- reader proceeds while a writer holds an open transaction.
  local path = fs.join(TEST_TMPDIR, "wal_share.db")
  local a = check.must(sqlite.open(path))
  assert(a:exec("CREATE TABLE t (v TEXT)"))
  assert(a:exec("INSERT INTO t (v) VALUES (?)", {"one"}))
  local b = check.must(sqlite.open(path, {busy_timeout_ms = 0}))

  assert(a:exec("BEGIN IMMEDIATE"))
  assert(a:exec("INSERT INTO t (v) VALUES (?)", {"two"}))
  local c = check.must(b:query_one("SELECT COUNT(*) AS n FROM t")).n
  assert(c == 1, "reader should see pre-transaction state, got: " .. tostring(c))
  assert(a:exec("COMMIT"))
  local c2 = check.must(b:query_one("SELECT COUNT(*) AS n FROM t")).n
  assert(c2 == 2, "reader should see the committed row, got: " .. tostring(c2))
  assert(a:close())
  assert(b:close())
end
test_wal_readers_not_blocked_by_writer()
