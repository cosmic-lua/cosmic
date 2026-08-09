#!/usr/bin/env cosmic
local check = require("cosmic.check")
local sqlite = require("cosmic.sqlite")

local function open_db(): sqlite.Database
  local d = check.must(sqlite.open(":memory:"))
  assert(d:exec("CREATE TABLE t (id INTEGER PRIMARY KEY, name TEXT, score REAL)"))
  assert(d:exec("INSERT INTO t (name, score) VALUES ('alice', 1.5), ('bob', 2.5)"))
  return d
end

-- Scalar lookups after #1063 retired query_value: query_one is the one
-- way in, and it keeps the distinction query_value could not — a NULL
-- first column is a row that exists, not a missing one. That capability
-- is the reason the convenience went rather than the reverse.

local function test_query_one_scalar_with_params()
  local db = open_db()
  local row = check.must(db:query_one("SELECT name FROM t WHERE id = ?", {2}))
  check.equal(row.name, "bob")
  local scored = check.must(
    db:query_one("SELECT score FROM t WHERE name = ?", {"alice"}))
  check.equal(scored.score, 1.5)
  assert(db:close())
end
test_query_one_scalar_with_params()

local function test_query_one_null_column_is_not_a_missing_row()
  local db = open_db()
  assert(db:exec("INSERT INTO t (name, score) VALUES (NULL, 9.0)"))
  local present = check.must(db:query_one("SELECT name FROM t WHERE score = 9.0"))
  check.equal(present.name, nil, "the row exists; its column is NULL")
  local absent, err = db:query_one("SELECT name FROM t WHERE score = 99.0")
  check.equal(absent, nil, "no row at all")
  check.equal(err, nil, "an empty result is not a failure")
  assert(db:close())
end
test_query_one_null_column_is_not_a_missing_row()

local function test_query_one_on_a_closed_db_fails()
  local db = open_db()
  assert(db:close())
  local row, err = db:query_one("SELECT 1 AS one")
  assert(row == nil and err ~= nil, "expected failure on closed database")
end
test_query_one_on_a_closed_db_fails()

-- savepoint tests

local function count(db: sqlite.Database): number
  -- cast: a row column is `any`
  return check.must(db:query_one("SELECT COUNT(*) AS n FROM t")).n as number
end

local function test_savepoint_commit()
  local db = open_db()
  local ok, err = db:savepoint(function(d: sqlite.Database): boolean, string
      assert(d:exec("INSERT INTO t (name) VALUES ('carol')"))
      return true
    end)
  assert(ok, "savepoint failed: " .. tostring(err))
  assert(count(db) == 3, "expected insert to persist")
  assert(db:close())
end
test_savepoint_commit()

local function test_savepoint_rollback_on_error()
  local db = open_db()
  local ok, err = db:savepoint(function(d: sqlite.Database): boolean, string
      assert(d:exec("INSERT INTO t (name) VALUES ('carol')"))
      error("boom")
    end)
  assert(not ok, "expected savepoint to fail")
  assert(err and err:find("boom", 1, true), "expected raised error surfaced, got " .. tostring(err))
  assert(count(db) == 2, "expected insert rolled back")
  assert(db:close())
end
test_savepoint_rollback_on_error()

local function test_savepoint_rollback_on_false()
  local db = open_db()
  local ok = db:savepoint(function(d: sqlite.Database): boolean, string
      assert(d:exec("INSERT INTO t (name) VALUES ('carol')"))
      return false
    end)
  assert(not ok, "expected savepoint to fail on returned false")
  assert(count(db) == 2, "expected insert rolled back")
  assert(db:close())
end
test_savepoint_rollback_on_false()

local function test_savepoint_rejects_nil_verdict()
  -- nil is not a verdict: the callback contract is explicit, so a
  -- nil+err return rolls back with an error naming the contract.
  local db = open_db()
  local ok, err = db:savepoint(function(d: sqlite.Database): any, string
      assert(d:exec("INSERT INTO t (name) VALUES ('carol')"))
      return nil, "signaled failure"
    end)
  assert(not ok, "expected savepoint to fail on nil+err")
  assert(err and err:find("explicit verdict", 1, true),
    "should name the verdict contract, got " .. tostring(err))
  assert(count(db) == 2, "expected insert rolled back")
  assert(db:close())
end
test_savepoint_rejects_nil_verdict()

local function test_savepoint_nested_inner_rollback()
  local db = open_db()
  local ok, err = db:savepoint(function(d: sqlite.Database): boolean, string
      assert(d:exec("INSERT INTO t (name) VALUES ('outer')"))
      local inner_ok = d:savepoint(function(d2: sqlite.Database): boolean, string
          assert(d2:exec("INSERT INTO t (name) VALUES ('inner')"))
          return false
        end)
      assert(not inner_ok, "expected inner savepoint to roll back")
      return true
    end)
  assert(ok, "outer savepoint failed: " .. tostring(err))
  assert(count(db) == 3, "expected outer insert kept, inner rolled back")
  assert(check.must(db:query_one(
        "SELECT COUNT(*) AS n FROM t WHERE name = 'inner'")).n == 0,
    "expected inner insert gone")
  assert(db:close())
end
test_savepoint_nested_inner_rollback()

local function test_savepoint_inside_transaction()
  local db = open_db()
  local ok, err = db:transaction(function(d: sqlite.Database): boolean, string
      assert(d:exec("INSERT INTO t (name) VALUES ('tx')"))
      local sp_ok = d:savepoint(function(d2: sqlite.Database): boolean, string
          assert(d2:exec("INSERT INTO t (name) VALUES ('sp')"))
          return false
        end)
      assert(not sp_ok, "the savepoint should report its deliberate rollback")
      return true
    end)
  assert(ok, "transaction failed: " .. tostring(err))
  assert(count(db) == 3, "expected transaction insert kept, savepoint rolled back")
  assert(db:close())
end
test_savepoint_inside_transaction()

-- A failing RELEASE (e.g. a deferred foreign-key violation, checked when
-- the outermost savepoint releases like an implicit COMMIT) must roll back
-- to the savepoint instead of leaving it open.
local function test_savepoint_release_failure_rolls_back()
  local db = check.must(sqlite.open(":memory:"))
  assert(db:exec("CREATE TABLE parent (id INTEGER PRIMARY KEY)"))
  assert(db:exec([[CREATE TABLE child (
    id INTEGER PRIMARY KEY,
    parent_id INTEGER REFERENCES parent(id) DEFERRABLE INITIALLY DEFERRED
  )]]))
  assert(db:exec("INSERT INTO parent (id) VALUES (1)"))

  local ok, err = db:savepoint(function(d: sqlite.Database): boolean, string
      -- Orphan reference: passes at INSERT time (deferred), fails at RELEASE.
      assert(d:exec("INSERT INTO child (id, parent_id) VALUES (1, 99)"))
      return true
    end)
  assert(not ok, "savepoint must fail when RELEASE violates a deferred FK")
  assert(err and err:find("FOREIGN KEY", 1, true),
    "error should mention the FK violation, got: " .. tostring(err))

  local n = check.must(db:query_one("SELECT COUNT(*) AS n FROM child")).n
  assert(n == 0, "orphan row must be rolled back, got: " .. tostring(n))

  -- The connection must not be left inside an open transaction/savepoint.
  local begin_ok, begin_err = db:exec("BEGIN IMMEDIATE")
  assert(begin_ok, "connection must not be stuck inside an open transaction: "
    .. tostring(begin_err))
  assert(db:exec("ROLLBACK"))
  assert(db:close())
end
test_savepoint_release_failure_rolls_back()
