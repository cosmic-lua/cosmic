#!/usr/bin/env cosmic
local sqlite = require("cosmic.sqlite")

local function open_db(): sqlite.Database
  local db, err = sqlite.open(":memory:")
  assert(db ~= nil, "open failed: " .. tostring(err))
  local d = db as sqlite.Database
  assert(d:exec("CREATE TABLE t (id INTEGER PRIMARY KEY, name TEXT, score REAL)"))
  assert(d:exec("INSERT INTO t (name, score) VALUES ('alice', 1.5), ('bob', 2.5)"))
  return d
end

-- query_value tests

local function test_query_value_count()
  local db = open_db()
  local n, err = db:query_value("SELECT COUNT(*) FROM t")
  assert(n == 2, "expected 2, got " .. tostring(n) .. " (" .. tostring(err) .. ")")
  db:close()
end
test_query_value_count()

local function test_query_value_with_params()
  local db = open_db()
  local name = db:query_value("SELECT name FROM t WHERE id = ?", 2)
  assert(name == "bob", "expected bob, got " .. tostring(name))
  local score = db:query_value("SELECT score FROM t WHERE name = ?", "alice")
  assert(score == 1.5, "expected 1.5, got " .. tostring(score))
  db:close()
end
test_query_value_with_params()

local function test_query_value_first_column_first_row()
  local db = open_db()
  local v = db:query_value("SELECT name, score FROM t ORDER BY id")
  assert(v == "alice", "expected first column of first row, got " .. tostring(v))
  db:close()
end
test_query_value_first_column_first_row()

local function test_query_value_no_rows()
  local db = open_db()
  local v, err = db:query_value("SELECT name FROM t WHERE id = ?", 999)
  assert(v == nil, "expected nil for no rows")
  assert(err == nil, "expected no error for no rows, got " .. tostring(err))
  db:close()
end
test_query_value_no_rows()

local function test_query_value_null()
  local db = open_db()
  assert(db:exec("INSERT INTO t (name, score) VALUES (NULL, 9.0)"))
  local v, err = db:query_value("SELECT name FROM t WHERE score = 9.0")
  assert(v == nil and err == nil, "expected nil, no error for SQL NULL")
  db:close()
end
test_query_value_null()

local function test_query_value_bad_sql()
  local db = open_db()
  local v, err = db:query_value("SELECT nope FROM missing")
  assert(v == nil, "expected nil for bad SQL")
  assert(err ~= nil, "expected an error message")
  db:close()
end
test_query_value_bad_sql()

local function test_query_value_closed_db()
  local db = open_db()
  db:close()
  local v, err = db:query_value("SELECT 1")
  assert(v == nil and err ~= nil, "expected failure on closed database")
end
test_query_value_closed_db()

-- savepoint tests

local function count(db: sqlite.Database): number
  return db:query_value("SELECT COUNT(*) FROM t") as number
end

local function test_savepoint_commit()
  local db = open_db()
  local ok, err = db:savepoint(function(d: sqlite.Database)
      assert(d:exec("INSERT INTO t (name) VALUES ('carol')"))
    end)
  assert(ok, "savepoint failed: " .. tostring(err))
  assert(count(db) == 3, "expected insert to persist")
  db:close()
end
test_savepoint_commit()

local function test_savepoint_rollback_on_error()
  local db = open_db()
  local ok, err = db:savepoint(function(d: sqlite.Database)
      assert(d:exec("INSERT INTO t (name) VALUES ('carol')"))
      error("boom")
    end)
  assert(not ok, "expected savepoint to fail")
  assert(err and err:find("boom", 1, true), "expected raised error surfaced, got " .. tostring(err))
  assert(count(db) == 2, "expected insert rolled back")
  db:close()
end
test_savepoint_rollback_on_error()

local function test_savepoint_rollback_on_false()
  local db = open_db()
  local ok = db:savepoint(function(d: sqlite.Database): boolean
      assert(d:exec("INSERT INTO t (name) VALUES ('carol')"))
      return false
    end as function(sqlite.Database))
  assert(not ok, "expected savepoint to fail on returned false")
  assert(count(db) == 2, "expected insert rolled back")
  db:close()
end
test_savepoint_rollback_on_false()

local function test_savepoint_rollback_on_nil_err()
  local db = open_db()
  local ok, err = db:savepoint(function(d: sqlite.Database): any, string
      assert(d:exec("INSERT INTO t (name) VALUES ('carol')"))
      return nil, "signaled failure"
    end as function(sqlite.Database))
  assert(not ok, "expected savepoint to fail on nil+err")
  assert(err == "signaled failure", "expected error message, got " .. tostring(err))
  assert(count(db) == 2, "expected insert rolled back")
  db:close()
end
test_savepoint_rollback_on_nil_err()

local function test_savepoint_nested_inner_rollback()
  local db = open_db()
  local ok, err = db:savepoint(function(d: sqlite.Database)
      assert(d:exec("INSERT INTO t (name) VALUES ('outer')"))
      local inner_ok = d:savepoint(function(d2: sqlite.Database): boolean
          assert(d2:exec("INSERT INTO t (name) VALUES ('inner')"))
          return false
        end as function(sqlite.Database))
      assert(not inner_ok, "expected inner savepoint to roll back")
    end)
  assert(ok, "outer savepoint failed: " .. tostring(err))
  assert(count(db) == 3, "expected outer insert kept, inner rolled back")
  assert(db:query_value("SELECT COUNT(*) FROM t WHERE name = 'inner'") == 0,
    "expected inner insert gone")
  db:close()
end
test_savepoint_nested_inner_rollback()

local function test_savepoint_inside_transaction()
  local db = open_db()
  local ok, err = db:transaction(function(d: sqlite.Database)
      assert(d:exec("INSERT INTO t (name) VALUES ('tx')"))
      d:savepoint(function(d2: sqlite.Database): boolean
          assert(d2:exec("INSERT INTO t (name) VALUES ('sp')"))
          return false
        end as function(sqlite.Database))
    end)
  assert(ok, "transaction failed: " .. tostring(err))
  assert(count(db) == 3, "expected transaction insert kept, savepoint rolled back")
  db:close()
end
test_savepoint_inside_transaction()
