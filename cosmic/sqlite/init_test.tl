#!/usr/bin/env cosmic
--- Tests for cosmic.sqlite wrapper module.

local check = require("cosmic.check")
local fs = require("cosmic.fs")
local sqlite = require("cosmic.sqlite")

local TEST_TMPDIR = os.getenv("TEST_TMPDIR")

-- Basic operations

local function test_open_memory()
  local db = check.must(sqlite.open(":memory:"))
  assert(db:close())
end
test_open_memory()

local function test_open_file()
  local dbpath = fs.join(TEST_TMPDIR, "test.db")
  local db = check.must(sqlite.open(dbpath))
  assert(db:close())
end
test_open_file()

local function test_open_invalid_path()
  local db, err = sqlite.open("/nonexistent/path/to/db.sqlite")
  assert(db == nil, "should fail on invalid path")
  assert(err, "should return error message")
end
test_open_invalid_path()

-- Execution

local function test_exec_create_table()
  local db = check.must(sqlite.open(":memory:"))
  local ok, err = db:exec("CREATE TABLE t (id INTEGER PRIMARY KEY, name TEXT)")
  assert(ok, "exec should succeed: " .. tostring(err))
  assert(db:close())
end
test_exec_create_table()

local function test_exec_invalid_sql()
  local db = check.must(sqlite.open(":memory:"))
  local ok, err = db:exec("INVALID SQL SYNTAX")
  assert(not ok, "exec should fail on invalid SQL")
  assert(err, "should return error message")
  assert(db:close())
end
test_exec_invalid_sql()

local function test_last_insert_rowid()
  local db = check.must(sqlite.open(":memory:"))
  assert(db:exec("CREATE TABLE t (id INTEGER PRIMARY KEY, name TEXT)"))
  assert(db:exec("INSERT INTO t (name) VALUES ('first')"))
  assert(db:last_insert_rowid() == 1, "first insert should have rowid 1")
  assert(db:exec("INSERT INTO t (name) VALUES ('second')"))
  assert(db:last_insert_rowid() == 2, "second insert should have rowid 2")
  assert(db:close())
end
test_last_insert_rowid()

local function test_changes()
  local db = check.must(sqlite.open(":memory:"))
  assert(db:exec("CREATE TABLE t (id INTEGER PRIMARY KEY, name TEXT)"))
  assert(db:exec("INSERT INTO t (name) VALUES ('a'), ('b'), ('c')"))
  assert(db:changes() == 3, "should report 3 changes")
  assert(db:exec("DELETE FROM t WHERE id < 3"))
  assert(db:changes() == 2, "should report 2 changes after delete")
  assert(db:close())
end
test_changes()

local function test_exec_with_params()
  local db = check.must(sqlite.open(":memory:"))
  assert(db:exec("CREATE TABLE t (id INTEGER PRIMARY KEY, name TEXT)"))

  local ok, err = db:exec("INSERT INTO t (name) VALUES (?)", "Alice")
  assert(ok, "exec with param should succeed: " .. tostring(err))
  assert(db:last_insert_rowid() == 1, "should have inserted row")

  ok, err = db:exec("UPDATE t SET name = ? WHERE id = ?", "Bob", 1)
  assert(ok, "exec update should succeed: " .. tostring(err))

  ok, err = db:exec("DELETE FROM t WHERE name = ?", "Bob")
  assert(ok, "exec delete should succeed: " .. tostring(err))
  assert(db:changes() == 1, "should have deleted 1 row")
  assert(db:close())
end
test_exec_with_params()

local function test_exec_multiple_params()
  local db = check.must(sqlite.open(":memory:"))
  assert(db:exec("CREATE TABLE t (a TEXT, b INTEGER, c REAL)"))

  local ok, err = db:exec("INSERT INTO t (a, b, c) VALUES (?, ?, ?)", "hello", 42, 3.14)
  assert(ok, "exec with multiple params should succeed: " .. tostring(err))

  for row in check.must(db:query("SELECT * FROM t")) do
    assert(row.a == "hello", "a should be 'hello'")
    assert(row.b == 42, "b should be 42")
    assert(math.abs((row.c as number) - 3.14) < 0.001, "c ~3.14") -- cast: from any
  end
  assert(db:close())
end
test_exec_multiple_params()

local function test_exec_no_params()
  local db = check.must(sqlite.open(":memory:"))
  local ok, err = db:exec("CREATE TABLE t (id INTEGER PRIMARY KEY)")
  assert(ok, "exec without params should succeed: " .. tostring(err))
  ok, err = db:exec("INSERT INTO t DEFAULT VALUES")
  assert(ok, "exec without params should succeed: " .. tostring(err))
  assert(db:close())
end
test_exec_no_params()

-- Prepared statements

local function test_prepare_bind_exec()
  local db = check.must(sqlite.open(":memory:"))
  assert(db:exec("CREATE TABLE t (id INTEGER PRIMARY KEY, name TEXT)"))

  local stmt = check.must(db:prepare("INSERT INTO t (name) VALUES (?)"))

  local ok, err = stmt:bind("test")
  assert(ok, "bind should succeed: " .. tostring(err))

  ok, err = stmt:exec()
  assert(ok, "exec should succeed: " .. tostring(err))

  assert(db:last_insert_rowid() == 1, "should have inserted row")
  assert(stmt:close())
  assert(db:close())
end
test_prepare_bind_exec()

local function test_prepare_invalid_sql()
  local db = check.must(sqlite.open(":memory:"))
  local stmt, err = db:prepare("INVALID SQL")
  assert(stmt == nil, "should fail on invalid SQL")
  assert(err, "should return error message")
  assert(db:close())
end
test_prepare_invalid_sql()

local function test_statement_reset()
  local db = check.must(sqlite.open(":memory:"))
  assert(db:exec("CREATE TABLE t (id INTEGER PRIMARY KEY, name TEXT)"))

  local stmt = check.must(db:prepare("INSERT INTO t (name) VALUES (?)"))
  assert(stmt:bind("first"))
  assert(stmt:exec())
  stmt:reset()
  assert(stmt:bind("second"))
  assert(stmt:exec())
  assert(stmt:close())

  local count = 0
  for _ in check.must(db:query("SELECT * FROM t")) do
    count = count + 1
  end
  assert(count == 2, "should have 2 rows after reset and reuse")
  assert(db:close())
end
test_statement_reset()

-- Query iteration

local function test_query_rows()
  local db = check.must(sqlite.open(":memory:"))
  assert(db:exec("CREATE TABLE t (id INTEGER PRIMARY KEY, name TEXT)"))
  assert(db:exec("INSERT INTO t (name) VALUES ('Alice'), ('Bob'), ('Carol')"))

  local names: {string} = {}
  for row in check.must(db:query("SELECT * FROM t ORDER BY id")) do
    table.insert(names, row.name as string) -- cast: from any
  end

  assert(#names == 3, "should get 3 rows")
  assert(names[1] == "Alice", "first name should be Alice")
  assert(names[2] == "Bob", "second name should be Bob")
  assert(names[3] == "Carol", "third name should be Carol")
  assert(db:close())
end
test_query_rows()

local function test_query_with_params()
  local db = check.must(sqlite.open(":memory:"))
  assert(db:exec("CREATE TABLE t (id INTEGER PRIMARY KEY, name TEXT)"))
  assert(db:exec("INSERT INTO t (name) VALUES ('Alice'), ('Bob'), ('Carol')"))

  local names: {string} = {}
  for row in check.must(db:query("SELECT * FROM t WHERE id > ? ORDER BY id", 1)) do
    table.insert(names, row.name as string) -- cast: from any
  end

  assert(#names == 2, "should get 2 rows")
  assert(names[1] == "Bob", "first should be Bob")
  assert(names[2] == "Carol", "second should be Carol")
  assert(db:close())
end
test_query_with_params()

local function test_query_empty_results()
  local db = check.must(sqlite.open(":memory:"))
  assert(db:exec("CREATE TABLE t (id INTEGER PRIMARY KEY)"))

  local count = 0
  for _ in check.must(db:query("SELECT * FROM t")) do
    count = count + 1
  end
  assert(count == 0, "should get 0 rows from empty table")
  assert(db:close())
end
test_query_empty_results()

local function test_statement_rows_positional_lookup()
  local db = check.must(sqlite.open(":memory:"))
  assert(db:exec("CREATE TABLE t (a TEXT, b INTEGER, c REAL)"))
  assert(db:exec("INSERT INTO t VALUES ('hello', 42, 3.14)"))

  local stmt = check.must(db:prepare("SELECT * FROM t"))
  local rows = stmt:rows()
  local row = rows()

  assert(row.a == "hello", "first value should be 'hello'")
  assert(row.b == 42, "second value should be 42")
  assert(math.abs((row.c as number) - 3.14) < 0.001, "third ~3.14") -- cast: from any
  assert(stmt:close())
  assert(db:close())
end
test_statement_rows_positional_lookup()

-- Iterator error surfacing (step errors must not masquerade as end-of-rows)

-- abs() of the most-negative int64 overflows at step() time (not prepare).
local OVERFLOW = "SELECT abs(-9223372036854775808) AS x"

local function test_query_err_nil_on_clean_iteration()
  local db = check.must(sqlite.open(":memory:"))
  assert(db:exec("CREATE TABLE t (id INTEGER PRIMARY KEY)"))
  assert(db:exec("INSERT INTO t (id) VALUES (1), (2)"))
  local iter = check.must(db:query("SELECT * FROM t"))
  local count = 0
  for _ in iter do count = count + 1 end
  assert(count == 2, "should iterate all rows")
  assert(iter:err() == nil, "clean iteration should report no error")
  assert(db:close())
end
test_query_err_nil_on_clean_iteration()

local function test_query_step_error_surfaced()
  local db = check.must(sqlite.open(":memory:"))
  local iter = check.must(db:query(OVERFLOW))
  for _ in iter do end
  local err = iter:err()
  assert(err ~= nil, "step error must be surfaced, not swallowed as end-of-rows")
  assert(string.find(err, "overflow"),
    "error should mention overflow: " .. tostring(err))
  assert(db:close())
end
test_query_step_error_surfaced()

local function test_query_one_step_error()
  local db = check.must(sqlite.open(":memory:"))
  local row, err = db:query_one(OVERFLOW)
  assert(row == nil, "query_one should return nil on a step error")
  assert(type(err) == "string", "query_one should surface the step error")
  assert(db:close())
end
test_query_one_step_error()

-- A NULL first column is an ordinary row through rows(): a map row can
-- never be mistaken for end-of-iteration (the hazard that killed values()).
local function test_rows_null_first_column()
  local db = check.must(sqlite.open(":memory:"))
  assert(db:exec("CREATE TABLE t (a TEXT, b INTEGER, c TEXT)"))
  assert(db:exec("INSERT INTO t VALUES (NULL, 42, 'z')"))
  local stmt = check.must(db:prepare("SELECT * FROM t"))
  local row = stmt:rows()()
  assert(row ~= nil, "a NULL first column must not end iteration")
  assert(row.a == nil, "first column should be nil (SQL NULL)")
  assert(row.b == 42, "second column should survive")
  assert(row.c == "z", "third column should survive")
  assert(stmt:close())
  assert(db:close())
end
test_rows_null_first_column()

-- Use-after-close returns errors instead of throwing/crashing
local function test_use_after_close()
  local db = check.must(sqlite.open(":memory:"))
  assert(db:exec("CREATE TABLE t (id INTEGER)"))
  assert(db:close())
  local ok, exec_err = db:exec("INSERT INTO t (id) VALUES (1)")
  assert(not ok and type(exec_err) == "string", "exec after close should error")
  local iter, query_err = db:query("SELECT * FROM t")
  assert(iter == nil and type(query_err) == "string", "query after close should error")
  -- 0 is a legitimate live value, so closed reports nil, err instead.
  local rowid, rerr = db:last_insert_rowid()
  assert(rowid == nil and type(rerr) == "string", "rowid after close: nil, err")
  local nchanged, cerr = db:changes()
  assert(nchanged == nil and type(cerr) == "string", "changes after close: nil, err")
end
test_use_after_close()

-- Index conversion (1-indexed)

local function test_column_name_1indexed()
  local db = check.must(sqlite.open(":memory:"))
  assert(db:exec("CREATE TABLE t (first_col TEXT, second_col INTEGER, third_col REAL)"))
  assert(db:exec("INSERT INTO t VALUES ('a', 1, 1.0)")) -- Need a row to step to

  local stmt = check.must(db:prepare("SELECT * FROM t"))
  assert(stmt:columns() == 3, "should have 3 columns")
  -- column_name requires step() to be called first (lsqlite3 limitation)
  assert(stmt:exec()) -- Step to first row
  assert(stmt:column_name(1) == "first_col", "column 1 should be 'first_col'")
  assert(stmt:column_name(2) == "second_col", "column 2 should be 'second_col'")
  assert(stmt:column_name(3) == "third_col", "column 3 should be 'third_col'")
  assert(stmt:close())
  assert(db:close())
end
test_column_name_1indexed()

-- Resource cleanup

local function test_manual_close()
  local db = check.must(sqlite.open(":memory:"))
  assert(db:close())
  -- second close should be safe (no error)
  assert(db:close())
end
test_manual_close()

local function test_auto_close()
  -- Test that db can be opened and closed without issue
  local db = check.must(sqlite.open(":memory:"))
  assert(db:exec("CREATE TABLE t (id INTEGER)"))
  assert(db:close())
end
test_auto_close()

local function test_statement_close()
  local db = check.must(sqlite.open(":memory:"))
  assert(db:exec("CREATE TABLE t (id INTEGER)"))
  local stmt = check.must(db:prepare("SELECT * FROM t"))
  assert(stmt:close())
  assert(db:close())
end
test_statement_close()

local function test_double_close_safe()
  local db = check.must(sqlite.open(":memory:"))
  local stmt = check.must(db:prepare("SELECT 1"))
  assert(stmt:close())
  assert(stmt:close())
  assert(db:close())
  assert(db:close())
end
test_double_close_safe()

-- Integration tests

local function test_transaction()
  local db = check.must(sqlite.open(":memory:"))
  assert(db:exec("CREATE TABLE t (id INTEGER PRIMARY KEY, name TEXT)"))

  assert(db:exec("BEGIN TRANSACTION"))
  assert(db:exec("INSERT INTO t (name) VALUES ('inside tx')"))
  assert(db:exec("ROLLBACK"))

  local count = 0
  for _ in check.must(db:query("SELECT * FROM t")) do
    count = count + 1
  end
  assert(count == 0, "should have 0 rows after rollback")

  assert(db:exec("BEGIN TRANSACTION"))
  assert(db:exec("INSERT INTO t (name) VALUES ('committed')"))
  assert(db:exec("COMMIT"))

  count = 0
  for _ in check.must(db:query("SELECT * FROM t")) do
    count = count + 1
  end
  assert(count == 1, "should have 1 row after commit")
  assert(db:close())
end
test_transaction()

local function test_multiple_params()
  local db = check.must(sqlite.open(":memory:"))
  assert(db:exec("CREATE TABLE t (a TEXT, b INTEGER, c REAL)"))

  local stmt = check.must(db:prepare("INSERT INTO t (a, b, c) VALUES (?, ?, ?)"))
  assert(stmt:bind("hello", 42, 3.14))
  assert(stmt:exec())
  assert(stmt:close())

  for row in check.must(db:query("SELECT * FROM t")) do
    assert(row.a == "hello", "a should be 'hello'")
    assert(row.b == 42, "b should be 42")
    assert(math.abs((row.c as number) - 3.14) < 0.001, "c ~3.14") -- cast: from any
  end
  assert(db:close())
end
test_multiple_params()

local function test_null_values()
  local db = check.must(sqlite.open(":memory:"))
  assert(db:exec("CREATE TABLE t (id INTEGER PRIMARY KEY, name TEXT)"))
  assert(db:exec("INSERT INTO t (name) VALUES (NULL)"))

  for row in check.must(db:query("SELECT * FROM t")) do
    assert(row.name == nil, "name should be nil")
  end
  assert(db:close())
end
test_null_values()

local function test_nested_queries()
  local db = check.must(sqlite.open(":memory:"))
  assert(db:exec("CREATE TABLE parents (id INTEGER PRIMARY KEY, name TEXT)"))
  assert(db:exec("CREATE TABLE children (id INTEGER PRIMARY KEY, parent_id INTEGER, name TEXT)"))
  assert(db:exec("INSERT INTO parents (name) VALUES ('Alice'), ('Bob')"))
  assert(db:exec("INSERT INTO children (parent_id, name) VALUES (1, 'Child1'), (1, 'Child2'), (2, 'Child3')"))

  local results: {string} = {}
  for parent in check.must(db:query("SELECT * FROM parents ORDER BY id")) do
    for child in check.must(db:query("SELECT * FROM children WHERE parent_id = ? ORDER BY id", parent.id)) do
      -- cast: from any
      table.insert(results, (parent.name as string) .. "->" .. (child.name as string))
    end
  end

  assert(#results == 3, "should get 3 parent-child pairs")
  assert(results[1] == "Alice->Child1", "first pair")
  assert(results[2] == "Alice->Child2", "second pair")
  assert(results[3] == "Bob->Child3", "third pair")
  assert(db:close())
end
test_nested_queries()

-- Error return paths (no-throw on invalid SQL)

local function test_query_invalid_sql()
  local db = check.must(sqlite.open(":memory:"))
  local iter, err = db:query("INVALID SQL SYNTAX")
  assert(iter == nil, "query should return nil on invalid SQL")
  assert(type(err) == "string", "should return error string")
  assert(db:close())
end
test_query_invalid_sql()

local function test_query_list_invalid_sql()
  local db = check.must(sqlite.open(":memory:"))
  local iter, err = db:query_list("INVALID SQL SYNTAX", {})
  assert(iter == nil, "query_list should return nil on invalid SQL")
  assert(type(err) == "string", "should return error string")
  assert(db:close())
end
test_query_list_invalid_sql()

local function test_query_named_invalid_sql()
  local db = check.must(sqlite.open(":memory:"))
  local iter, err = db:query_named("INVALID SQL SYNTAX", {})
  assert(iter == nil, "query_named should return nil on invalid SQL")
  assert(type(err) == "string", "should return error string")
  assert(db:close())
end
test_query_named_invalid_sql()

local function test_query_one_invalid_sql()
  local db = check.must(sqlite.open(":memory:"))
  local row, err = db:query_one("INVALID SQL SYNTAX")
  assert(row == nil, "query_one should return nil on invalid SQL")
  assert(type(err) == "string", "should return error string")
  assert(db:close())
end
test_query_one_invalid_sql()

-- FIX 3: query_one must finalize the prepared statement so db:close() succeeds
-- and subsequent queries work (statement leak regression test).
local function test_query_one_close_after_hit()
  local db = check.must(sqlite.open(":memory:"))
  assert(db:exec("CREATE TABLE t (id INTEGER PRIMARY KEY, name TEXT)"))
  assert(db:exec("INSERT INTO t (name) VALUES ('alice')"))

  -- query_one that returns a row must not leak the iterator/statement
  local row = check.must(db:query_one("SELECT * FROM t WHERE name = ?", "alice"))
  assert(row.name == "alice", "row.name should be 'alice'")

  -- A subsequent query must still work (leaked stmt could lock the table)
  local row2 = db:query_one("SELECT * FROM t WHERE name = ?", "alice")
  assert(row2 ~= nil, "second query_one should still work after first")

  -- db:close() must succeed without error (lsqlite3 fails if stmts unfinalized)
  assert(db:close())
end
test_query_one_close_after_hit()
