#!/usr/bin/env cosmic
--- Tests for cosmic.sqlite data-layer contracts: blob binding affinity,
--- default busy timeout, and open() options (issue #531).

local fs = require("cosmic.fs")
local sqlite = require("cosmic.sqlite")

local TEST_TMPDIR = os.getenv("TEST_TMPDIR")

-- Blob binding

local function test_blob_bind_affinity()
  local db = sqlite.open(":memory:") as sqlite.Database
  db:exec("CREATE TABLE t (v BLOB)")
  local payload = "\0\1\2\255"
  local ok, err = db:exec("INSERT INTO t (v) VALUES (?)", sqlite.blob(payload))
  assert(ok, "blob insert should succeed: " .. tostring(err))

  local row = db:query_one("SELECT v, typeof(v) AS ty FROM t") as {string: any}
  assert(row, "should read the row back")
  assert(row.ty == "blob", "typeof should be blob, got " .. tostring(row.ty))
  assert(row.v == payload, "blob bytes should round-trip")
  db:close()
end
test_blob_bind_affinity()

local function test_plain_string_stays_text()
  local db = sqlite.open(":memory:") as sqlite.Database
  db:exec("CREATE TABLE t (v BLOB)")
  db:exec("INSERT INTO t (v) VALUES (?)", "\0\1\2")
  local row = db:query_one("SELECT typeof(v) AS ty FROM t") as {string: any}
  assert(row and row.ty == "text", "bare string should keep text affinity")
  db:close()
end
test_plain_string_stays_text()

local function test_blob_in_query_params()
  -- db:query binds through the hot-path row iterator; make sure the blob
  -- marker is honored there too.
  local db = sqlite.open(":memory:") as sqlite.Database
  local iter = db:query("SELECT typeof(?) AS ty", sqlite.blob("abc")) as sqlite.Rows
  assert(iter, "query should succeed")
  local row = iter()
  assert(row and row.ty == "blob", "query param should bind as blob")
  while iter() ~= nil do end
  db:close()
end
test_blob_in_query_params()

local function test_blob_bind_and_bind_list()
  local db = sqlite.open(":memory:") as sqlite.Database
  db:exec("CREATE TABLE t (a BLOB, b BLOB)")

  local stmt = db:prepare("INSERT INTO t (a, b) VALUES (?, ?)") as sqlite.Statement
  local ok, err = stmt:bind(sqlite.blob("x"), "y")
  assert(ok, "bind should succeed: " .. tostring(err))
  assert(stmt:exec(), "exec should succeed")
  stmt:close()

  ok, err = db:exec_list("INSERT INTO t (a, b) VALUES (?, ?)", {sqlite.blob("p"), "q"})
  assert(ok, "exec_list with blob should succeed: " .. tostring(err))

  local iter = db:query("SELECT typeof(a) AS ta, typeof(b) AS tb FROM t") as sqlite.Rows
  local n = 0
  for row in iter do
    n = n + 1
    assert(row.ta == "blob", "column a should be blob")
    assert(row.tb == "text", "column b should be text")
  end
  assert(n == 2, "should have inserted 2 rows, got " .. n)
  db:close()
end
test_blob_bind_and_bind_list()

local function test_blob_named_rejected()
  local db = sqlite.open(":memory:") as sqlite.Database
  db:exec("CREATE TABLE t (v BLOB)")
  local ok, err = db:exec_named("INSERT INTO t (v) VALUES (:v)", {v = sqlite.blob("x")})
  assert(not ok, "blob via named parameters should be rejected")
  assert(err and err:match("positional"), "error should point at positional binding, got: " .. tostring(err))
  db:close()
end
test_blob_named_rejected()

-- Busy timeout

local function test_busy_timeout_applied()
  -- PRAGMA busy_timeout reads back the connection's current timeout.
  local db = sqlite.open(":memory:") as sqlite.Database
  local row = db:query_one("PRAGMA busy_timeout") as {string: any}
  assert(row, "pragma should return a row")
  assert(row.timeout == 5000, "default busy timeout should be 5000ms, got " .. tostring(row.timeout))
  db:close()

  db = sqlite.open(":memory:", {busy_timeout_ms = 123}) as sqlite.Database
  row = db:query_one("PRAGMA busy_timeout") as {string: any}
  assert(row and row.timeout == 123, "busy_timeout_ms option should apply, got " .. tostring((row as {string: any}).timeout))
  db:close()

  db = sqlite.open(":memory:", {busy_timeout_ms = 0}) as sqlite.Database
  row = db:query_one("PRAGMA busy_timeout") as {string: any}
  assert(row and row.timeout == 0, "busy_timeout_ms=0 should disable waiting, got " .. tostring((row as {string: any}).timeout))
  db:close()
end
test_busy_timeout_applied()

-- read_only option

local function test_read_only_open()
  local path = fs.join(TEST_TMPDIR, "readonly_test.db")
  local db = sqlite.open(path) as sqlite.Database
  db:exec("CREATE TABLE t (v TEXT)")
  db:exec("INSERT INTO t (v) VALUES (?)", "hello")
  db:close()

  local rdb = sqlite.open(path, {read_only = true}) as sqlite.Database
  local row = rdb:query_one("SELECT v FROM t") as {string: any}
  assert(row and row.v == "hello", "read-only handle should read existing data")
  local ok, err = rdb:exec("INSERT INTO t (v) VALUES (?)", "nope")
  assert(not ok, "write through read-only handle should fail")
  assert(err, "read-only write failure should carry an error message")
  rdb:close()
end
test_read_only_open()

local function test_read_only_missing_file_fails()
  local path = fs.join(TEST_TMPDIR, "missing.db")
  local db, err = sqlite.open(path, {read_only = true})
  assert(db == nil, "read-only open of a missing file should fail")
  assert(err, "should return an error message")
end
test_read_only_missing_file_fails()
