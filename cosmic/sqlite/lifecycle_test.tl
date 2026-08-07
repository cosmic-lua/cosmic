#!/usr/bin/env cosmic
--- Lifecycle tests for cosmic.sqlite: close ordering, the Statement
--- garbage-collection backstop, Rows early close, and the
--- multi-statement rejection on parameterized paths.
local sqlite = require("cosmic.sqlite")
local check = require("cosmic.check")

local function open_db(): sqlite.Database
  local db = check.must(sqlite.open(":memory:"))
  assert(db:exec("CREATE TABLE t (id INTEGER PRIMARY KEY, name TEXT)"))
  assert(db:exec("INSERT INTO t (name) VALUES ('alice'), ('bob')"))
  return db
end

-- Close with a live user-prepared Statement: the binding finalizes
-- outstanding statements during close, so close succeeds — and the
-- wrapper Statement's own close stays a safe no-op afterwards. (The
-- close-ordering fix — mark closed only after the raw close succeeds —
-- is defensive: no reachable failure path exists through lsqlite3
-- today, which this test also documents by construction.)
local function test_close_with_live_statement()
  local db = open_db()
  local stmt = check.must(db:prepare("SELECT name FROM t"))
  assert(db:close(), "close finalizes live statements and succeeds")
  assert(stmt:close())
  assert(db:close(), "close stays idempotent after success")
end
test_close_with_live_statement()

-- An abandoned db:prepare() handle is finalized by garbage collection,
-- so its raw statement is released as soon as the collector runs, not
-- held until the database closes.
local function test_statement_gc_backstop()
  local db = open_db()
  do
    local stmt = check.must(db:prepare("SELECT name FROM t"))
    local _ = stmt
  end
  collectgarbage("collect")
  collectgarbage("collect")
  assert(db:close(),
    "gc must have finalized the abandoned Statement so close succeeds")
end
test_statement_gc_backstop()

-- Rows:close ends iteration early (and <close> drives it); through
-- Statement:rows() it must not finalize the owning Statement, which
-- stays reusable.
local function test_rows_close_ends_iteration()
  local db = open_db()
  local stmt = check.must(db:prepare("SELECT id, name FROM t ORDER BY id"))
  assert(stmt:bind())
  do
    local rows < close > = stmt:rows()
    local row = rows()
    check.equal(row.id, 1)
    check.equal(row.name, "alice")
    assert(rows:close())
    local after = rows()
    check.equal(after, nil, "a closed Rows yields nothing")
    check.equal(rows:err(), nil, "close is not an error")
  end
  -- The Statement survives its Rows: rebind and drain it fully.
  assert(stmt:bind())
  local vals2 = stmt:rows()
  local n = 0
  while true do
    local id = vals2()
    if id == nil then break end
    n = n + 1
  end
  check.equal(n, 2, "statement must be reusable after Rows:close")
  check.equal(vals2:err(), nil)
  assert(stmt:close())
  assert(db:close())
end
test_rows_close_ends_iteration()

-- Parameterized exec/query of multi-statement SQL is rejected loudly:
-- sqlite compiles only the first statement, so the old behavior ran a
-- silent prefix and reported success.
local function test_multi_statement_rejected_with_params()
  local db = open_db()

  local ok, err = db:exec(
    "INSERT INTO t (name) VALUES (?); INSERT INTO t (name) VALUES ('x')",
    "carol")
  assert(not ok, "parameterized multi-statement exec must be rejected")
  assert(err and err:find("multi-statement", 1, true),
    "error must name the problem: " .. tostring(err))
  check.equal(db:query_value("SELECT COUNT(*) FROM t"), 2,
    "nothing may have run")

  local ok2, err2 = db:exec_list(
    "INSERT INTO t (name) VALUES (?); DELETE FROM t", {"carol"})
  assert(not ok2 and err2:find("multi-statement", 1, true),
    "exec_list must reject: " .. tostring(err2))

  local ok3, err3 = db:exec_named(
    "INSERT INTO t (name) VALUES (:n); DELETE FROM t", {n = "carol"})
  assert(not ok3 and err3:find("multi-statement", 1, true),
    "exec_named must reject: " .. tostring(err3))

  local rows, qerr = db:query("SELECT name FROM t; DELETE FROM t")
  assert(rows == nil and qerr and qerr:find("multi-statement", 1, true),
    "query must reject a silent second statement: " .. tostring(qerr))

  local rows2, qerr2 = db:query_list("SELECT ?; DELETE FROM t", {1})
  assert(rows2 == nil and qerr2 and qerr2:find("multi-statement", 1, true),
    "query_list must reject: " .. tostring(qerr2))

  assert(db:close())
end
test_multi_statement_rejected_with_params()

-- The rejection is lexical and must not misfire: semicolons inside
-- string literals, comments, or a trailing semicolon are ONE statement.
local function test_multi_statement_scan_false_positives()
  local db = open_db()

  assert(db:exec("INSERT INTO t (name) VALUES (?);", "semi"),
    "trailing semicolon is one statement")
  assert(db:exec("INSERT INTO t (name) VALUES (?); -- note; really\n", "c1"),
    "trailing comment after ; is one statement")
  assert(db:exec("INSERT INTO t (name) VALUES (?); /* a; b */", "c2"),
    "trailing block comment after ; is one statement")
  assert(db:exec("INSERT INTO t (name) VALUES ('a; b')"),
    "semicolon inside a string literal is one statement")
  local v = db:query_value("SELECT name FROM t WHERE name = ?", "a; b")
  check.equal(v, "a; b", "the literal value round-trips")
  assert(db:exec("INSERT INTO t (name) VALUES ('it''s; fine')"),
    "doubled-quote escape does not end the literal")

  -- The no-parameter exec form still runs multi-statement SQL.
  assert(db:exec(
      "INSERT INTO t (name) VALUES ('m1'); INSERT INTO t (name) VALUES ('m2')"),
    "no-parameter exec keeps multi-statement support")
  check.equal(db:query_value("SELECT COUNT(*) FROM t WHERE name LIKE 'm_'"), 2)

  assert(db:close())
end
test_multi_statement_scan_false_positives()

-- The transaction/savepoint callback type now declares the rollback
-- protocol, so a typed boolean return needs no cast.
local function test_transaction_callback_typed_rollback()
  local db = open_db()
  local ok = db:transaction(function(d: sqlite.Database): boolean
      assert(d:exec("INSERT INTO t (name) VALUES ('doomed')"))
      return false
    end)
  assert(not ok, "returned false must roll back")
  check.equal(db:query_value("SELECT COUNT(*) FROM t"), 2, "insert rolled back")

  local ok2, err2 = db:transaction(function(d: sqlite.Database): boolean, string
      assert(d:exec("INSERT INTO t (name) VALUES ('kept')"))
      return true
    end)
  assert(ok2, "returned true must commit: " .. tostring(err2))
  check.equal(db:query_value("SELECT COUNT(*) FROM t"), 3, "insert committed")
  assert(db:close())
end
test_transaction_callback_typed_rollback()
