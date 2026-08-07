#!/usr/bin/env cosmic
--- Tests for cosmic.sqlite data-layer contracts: blob binding affinity,
--- default busy timeout, and open() options.

local check = require("cosmic.check")
local fs = require("cosmic.fs")
local sqlite = require("cosmic.sqlite")

local TEST_TMPDIR = os.getenv("TEST_TMPDIR")

-- Blob binding

local function test_blob_bind_affinity()
  local db = check.must(sqlite.open(":memory:"))
  assert(db:exec("CREATE TABLE t (v BLOB)"))
  local payload = "\0\1\2\255"
  local ok, err = db:exec("INSERT INTO t (v) VALUES (?)", sqlite.blob(payload))
  assert(ok, "blob insert should succeed: " .. tostring(err))

  local row = check.must(db:query_one("SELECT v, typeof(v) AS ty FROM t"),
    "should read the row back")
  assert(row.ty == "blob", "typeof should be blob, got " .. tostring(row.ty))
  assert(row.v == payload, "blob bytes should round-trip")
  assert(db:close())
end
test_blob_bind_affinity()

local function test_plain_string_stays_text()
  local db = check.must(sqlite.open(":memory:"))
  assert(db:exec("CREATE TABLE t (v BLOB)"))
  assert(db:exec("INSERT INTO t (v) VALUES (?)", "\0\1\2"))
  local row = check.must(db:query_one("SELECT typeof(v) AS ty FROM t"))
  assert(row.ty == "text", "bare string should keep text affinity")
  assert(db:close())
end
test_plain_string_stays_text()

local function test_blob_in_query_params()
  -- db:query binds through the hot-path row iterator; make sure the blob
  -- marker is honored there too.
  local db = check.must(sqlite.open(":memory:"))
  local iter = check.must(db:query("SELECT typeof(?) AS ty", sqlite.blob("abc")),
    "query should succeed")
  local row = iter()
  assert(row and row.ty == "blob", "query param should bind as blob")
  while iter() ~= nil do end
  assert(db:close())
end
test_blob_in_query_params()

local function test_blob_bind_and_bind_list()
  local db = check.must(sqlite.open(":memory:"))
  assert(db:exec("CREATE TABLE t (a BLOB, b BLOB)"))

  local stmt = check.must(db:prepare("INSERT INTO t (a, b) VALUES (?, ?)"))
  local ok, err = stmt:bind(sqlite.blob("x"), "y")
  assert(ok, "bind should succeed: " .. tostring(err))
  assert(stmt:exec(), "exec should succeed")
  stmt:close()

  ok, err = db:exec_list("INSERT INTO t (a, b) VALUES (?, ?)", {sqlite.blob("p"), "q"})
  assert(ok, "exec_list with blob should succeed: " .. tostring(err))

  local iter = check.must(db:query("SELECT typeof(a) AS ta, typeof(b) AS tb FROM t"))
  local n = 0
  for row in iter do
    n = n + 1
    assert(row.ta == "blob", "column a should be blob")
    assert(row.tb == "text", "column b should be text")
  end
  assert(n == 2, "should have inserted 2 rows, got " .. n)
  assert(db:close())
end
test_blob_bind_and_bind_list()

local function test_blob_named_rejected()
  local db = check.must(sqlite.open(":memory:"))
  assert(db:exec("CREATE TABLE t (v BLOB)"))
  local ok, err = db:exec_named("INSERT INTO t (v) VALUES (:v)", {v = sqlite.blob("x")})
  assert(not ok, "blob via named parameters should be rejected")
  assert(err and err:match("positional"), "error should point at positional binding, got: " .. tostring(err))
  assert(db:close())
end
test_blob_named_rejected()

-- Busy timeout

local function test_busy_timeout_applied()
  -- PRAGMA busy_timeout reads back the connection's current timeout.
  local db = check.must(sqlite.open(":memory:"))
  local row = check.must(db:query_one("PRAGMA busy_timeout"),
    "pragma should return a row")
  assert(row.timeout == 5000, "default busy timeout should be 5000ms, got " .. tostring(row.timeout))
  assert(db:close())

  db = check.must(sqlite.open(":memory:", {busy_timeout_ms = 123}))
  row = check.must(db:query_one("PRAGMA busy_timeout"))
  assert(row.timeout == 123, "busy_timeout_ms option should apply, got " .. tostring(row.timeout))
  assert(db:close())

  db = check.must(sqlite.open(":memory:", {busy_timeout_ms = 0}))
  row = check.must(db:query_one("PRAGMA busy_timeout"))
  assert(row.timeout == 0, "busy_timeout_ms=0 should disable waiting, got " .. tostring(row.timeout))
  assert(db:close())
end
test_busy_timeout_applied()

-- read_only option

local function test_read_only_open()
  local path = fs.join(TEST_TMPDIR, "readonly_test.db")
  local db = check.must(sqlite.open(path))
  assert(db:exec("CREATE TABLE t (v TEXT)"))
  assert(db:exec("INSERT INTO t (v) VALUES (?)", "hello"))
  assert(db:close())

  local rdb = check.must(sqlite.open(path, {read_only = true}))
  local row = check.must(rdb:query_one("SELECT v FROM t"))
  assert(row.v == "hello", "read-only handle should read existing data")
  local ok, err = rdb:exec("INSERT INTO t (v) VALUES (?)", "nope")
  assert(not ok, "write through read-only handle should fail")
  assert(err, "read-only write failure should carry an error message")
  assert(rdb:close())
end
test_read_only_open()

local function test_read_only_missing_file_fails()
  local path = fs.join(TEST_TMPDIR, "missing.db")
  local db, err = sqlite.open(path, {read_only = true})
  assert(db == nil, "read-only open of a missing file should fail")
  assert(err, "should return an error message")
end
test_read_only_missing_file_fails()

-- constraint violations: exec must return false plus the
-- constraint's own message, never throw or silently succeed.

local function test_unique_constraint_violation()
  local db = check.must(sqlite.open(":memory:"))
  assert(db:exec("CREATE TABLE t (u TEXT UNIQUE)"))
  assert(db:exec("INSERT INTO t (u) VALUES (?)", "dup"))
  local ok, err = db:exec("INSERT INTO t (u) VALUES (?)", "dup")
  assert(not ok, "duplicate insert should fail")
  assert(err and err:match("UNIQUE constraint failed"),
    "error should name the UNIQUE constraint, got: " .. tostring(err))
  local row = check.must(db:query_one("SELECT COUNT(*) AS c FROM t"))
  assert(row.c == 1, "the failed insert must not add a row")
  assert(db:close())
end
test_unique_constraint_violation()

local function test_not_null_constraint_violation()
  local db = check.must(sqlite.open(":memory:"))
  assert(db:exec("CREATE TABLE t (n TEXT NOT NULL)"))
  local ok, err = db:exec("INSERT INTO t (n) VALUES (?)", nil)
  assert(not ok, "NULL insert into NOT NULL column should fail")
  assert(err and err:match("NOT NULL constraint failed"),
    "error should name the NOT NULL constraint, got: " .. tostring(err))
  assert(db:close())
end
test_not_null_constraint_violation()

-- SQLITE_BUSY: real lock contention between two connections
-- to the same file, not just the busy_timeout PRAGMA readback above.

local function test_busy_second_connection_write_blocked()
  local path = fs.join(TEST_TMPDIR, "busy_test.db")
  local a = check.must(sqlite.open(path))
  assert(a:exec("CREATE TABLE k (v TEXT)"))
  -- busy_timeout_ms=0: fail immediately instead of stalling the test.
  local b = check.must(sqlite.open(path, {busy_timeout_ms = 0}))

  assert(a:exec("BEGIN IMMEDIATE"))
  assert(a:exec("INSERT INTO k (v) VALUES (?)", "held"))

  local ok, err = b:exec("INSERT INTO k (v) VALUES (?)", "blocked")
  assert(not ok, "write while another connection holds the lock should fail")
  assert(err and err:match("locked"),
    "error should report the lock, got: " .. tostring(err))

  assert(a:exec("COMMIT"))
  local ok2, err2 = b:exec("INSERT INTO k (v) VALUES (?)", "after")
  assert(ok2, "write after the lock is released should succeed: " .. tostring(err2))
  assert(a:close())
  assert(b:close())
end
test_busy_second_connection_write_blocked()
