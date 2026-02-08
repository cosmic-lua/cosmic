#!/usr/bin/env cosmic
--- Tests for cosmic.sqlite wrapper module.

local path = require("cosmo.path")
local sqlite = require("cosmic.sqlite")

local TEST_TMPDIR = os.getenv("TEST_TMPDIR")

-- Basic operations

local function test_open_memory()
  local db, err = sqlite.open(":memory:")
  assert(db, "should open memory db: " .. tostring(err))
  db:close()
end
test_open_memory()

local function test_open_file()
  local dbpath = path.join(TEST_TMPDIR, "test.db")
  local db, err = sqlite.open(dbpath)
  assert(db, "should open file db: " .. tostring(err))
  db:close()
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
  local db = sqlite.open(":memory:")
  local ok, err = db:exec("CREATE TABLE t (id INTEGER PRIMARY KEY, name TEXT)")
  assert(ok, "exec should succeed: " .. tostring(err))
  db:close()
end
test_exec_create_table()

local function test_exec_invalid_sql()
  local db = sqlite.open(":memory:")
  local ok, err = db:exec("INVALID SQL SYNTAX")
  assert(not ok, "exec should fail on invalid SQL")
  assert(err, "should return error message")
  db:close()
end
test_exec_invalid_sql()

local function test_last_insert_rowid()
  local db = sqlite.open(":memory:")
  db:exec("CREATE TABLE t (id INTEGER PRIMARY KEY, name TEXT)")
  db:exec("INSERT INTO t (name) VALUES ('first')")
  assert(db:last_insert_rowid() == 1, "first insert should have rowid 1")
  db:exec("INSERT INTO t (name) VALUES ('second')")
  assert(db:last_insert_rowid() == 2, "second insert should have rowid 2")
  db:close()
end
test_last_insert_rowid()

local function test_changes()
  local db = sqlite.open(":memory:")
  db:exec("CREATE TABLE t (id INTEGER PRIMARY KEY, name TEXT)")
  db:exec("INSERT INTO t (name) VALUES ('a'), ('b'), ('c')")
  assert(db:changes() == 3, "should report 3 changes")
  db:exec("DELETE FROM t WHERE id < 3")
  assert(db:changes() == 2, "should report 2 changes after delete")
  db:close()
end
test_changes()

local function test_exec_with_params()
  local db = sqlite.open(":memory:")
  db:exec("CREATE TABLE t (id INTEGER PRIMARY KEY, name TEXT)")

  local ok, err = db:exec("INSERT INTO t (name) VALUES (?)", "Alice")
  assert(ok, "exec with param should succeed: " .. tostring(err))
  assert(db:last_insert_rowid() == 1, "should have inserted row")

  ok, err = db:exec("UPDATE t SET name = ? WHERE id = ?", "Bob", 1)
  assert(ok, "exec update should succeed: " .. tostring(err))

  ok, err = db:exec("DELETE FROM t WHERE name = ?", "Bob")
  assert(ok, "exec delete should succeed: " .. tostring(err))
  assert(db:changes() == 1, "should have deleted 1 row")
  db:close()
end
test_exec_with_params()

local function test_exec_multiple_params()
  local db = sqlite.open(":memory:")
  db:exec("CREATE TABLE t (a TEXT, b INTEGER, c REAL)")

  local ok, err = db:exec("INSERT INTO t (a, b, c) VALUES (?, ?, ?)", "hello", 42, 3.14)
  assert(ok, "exec with multiple params should succeed: " .. tostring(err))

  for row in db:query("SELECT * FROM t") do
    assert(row.a == "hello", "a should be 'hello'")
    assert(row.b == 42, "b should be 42")
    assert(math.abs((row.c as number) - 3.14) < 0.001, "c should be ~3.14")
  end
  db:close()
end
test_exec_multiple_params()

local function test_exec_no_params()
  local db = sqlite.open(":memory:")
  local ok, err = db:exec("CREATE TABLE t (id INTEGER PRIMARY KEY)")
  assert(ok, "exec without params should succeed: " .. tostring(err))
  ok, err = db:exec("INSERT INTO t DEFAULT VALUES")
  assert(ok, "exec without params should succeed: " .. tostring(err))
  db:close()
end
test_exec_no_params()

-- Prepared statements

local function test_prepare_bind_exec()
  local db = sqlite.open(":memory:")
  db:exec("CREATE TABLE t (id INTEGER PRIMARY KEY, name TEXT)")

  local stmt = db:prepare("INSERT INTO t (name) VALUES (?)")
  assert(stmt, "should prepare statement")

  local ok, err = stmt:bind("test")
  assert(ok, "bind should succeed: " .. tostring(err))

  ok, err = stmt:exec()
  assert(ok, "exec should succeed: " .. tostring(err))

  assert(db:last_insert_rowid() == 1, "should have inserted row")
  stmt:close()
  db:close()
end
test_prepare_bind_exec()

local function test_prepare_invalid_sql()
  local db = sqlite.open(":memory:")
  local stmt, err = db:prepare("INVALID SQL")
  assert(stmt == nil, "should fail on invalid SQL")
  assert(err, "should return error message")
  db:close()
end
test_prepare_invalid_sql()

local function test_statement_reset()
  local db = sqlite.open(":memory:")
  db:exec("CREATE TABLE t (id INTEGER PRIMARY KEY, name TEXT)")

  local stmt = db:prepare("INSERT INTO t (name) VALUES (?)")
  stmt:bind("first")
  stmt:exec()
  stmt:reset()
  stmt:bind("second")
  stmt:exec()
  stmt:close()

  local count = 0
  for _ in db:query("SELECT * FROM t") do
    count = count + 1
  end
  assert(count == 2, "should have 2 rows after reset and reuse")
  db:close()
end
test_statement_reset()

-- Query iteration

local function test_query_rows()
  local db = sqlite.open(":memory:")
  db:exec("CREATE TABLE t (id INTEGER PRIMARY KEY, name TEXT)")
  db:exec("INSERT INTO t (name) VALUES ('Alice'), ('Bob'), ('Carol')")

  local names: {string} = {}
  for row in db:query("SELECT * FROM t ORDER BY id") do
    table.insert(names, row.name as string)
  end

  assert(#names == 3, "should get 3 rows")
  assert(names[1] == "Alice", "first name should be Alice")
  assert(names[2] == "Bob", "second name should be Bob")
  assert(names[3] == "Carol", "third name should be Carol")
  db:close()
end
test_query_rows()

local function test_query_with_params()
  local db = sqlite.open(":memory:")
  db:exec("CREATE TABLE t (id INTEGER PRIMARY KEY, name TEXT)")
  db:exec("INSERT INTO t (name) VALUES ('Alice'), ('Bob'), ('Carol')")

  local names: {string} = {}
  for row in db:query("SELECT * FROM t WHERE id > ? ORDER BY id", 1) do
    table.insert(names, row.name as string)
  end

  assert(#names == 2, "should get 2 rows")
  assert(names[1] == "Bob", "first should be Bob")
  assert(names[2] == "Carol", "second should be Carol")
  db:close()
end
test_query_with_params()

local function test_query_empty_results()
  local db = sqlite.open(":memory:")
  db:exec("CREATE TABLE t (id INTEGER PRIMARY KEY)")

  local count = 0
  for _ in db:query("SELECT * FROM t") do
    count = count + 1
  end
  assert(count == 0, "should get 0 rows from empty table")
  db:close()
end
test_query_empty_results()

local function test_statement_values()
  local db = sqlite.open(":memory:")
  db:exec("CREATE TABLE t (a TEXT, b INTEGER, c REAL)")
  db:exec("INSERT INTO t VALUES ('hello', 42, 3.14)")

  local stmt = db:prepare("SELECT * FROM t")
  local iter = stmt:values()
  local a, b, c = iter()

  assert(a == "hello", "first value should be 'hello'")
  assert(b == 42, "second value should be 42")
  assert(math.abs((c as number) - 3.14) < 0.001, "third value should be ~3.14")
  stmt:close()
  db:close()
end
test_statement_values()

-- Index conversion (1-indexed)

local function test_column_name_1indexed()
  local db = sqlite.open(":memory:")
  db:exec("CREATE TABLE t (first_col TEXT, second_col INTEGER, third_col REAL)")
  db:exec("INSERT INTO t VALUES ('a', 1, 1.0)")  -- Need a row to step to

  local stmt = db:prepare("SELECT * FROM t")
  assert(stmt:columns() == 3, "should have 3 columns")
  -- column_name requires step() to be called first (lsqlite3 limitation)
  stmt:exec()  -- Step to first row
  assert(stmt:column_name(1) == "first_col", "column 1 should be 'first_col'")
  assert(stmt:column_name(2) == "second_col", "column 2 should be 'second_col'")
  assert(stmt:column_name(3) == "third_col", "column 3 should be 'third_col'")
  stmt:close()
  db:close()
end
test_column_name_1indexed()

-- Resource cleanup

local function test_manual_close()
  local db = sqlite.open(":memory:")
  assert(db, "should open db")
  db:close()
  -- second close should be safe (no error)
  db:close()
end
test_manual_close()

local function test_auto_close()
  -- Test that db can be opened and closed without issue
  local db = sqlite.open(":memory:")
  db:exec("CREATE TABLE t (id INTEGER)")
  db:close()
end
test_auto_close()

local function test_statement_close()
  local db = sqlite.open(":memory:")
  db:exec("CREATE TABLE t (id INTEGER)")
  local stmt = db:prepare("SELECT * FROM t")
  assert(stmt, "should prepare")
  stmt:close()
  db:close()
end
test_statement_close()

local function test_double_close_safe()
  local db = sqlite.open(":memory:")
  local stmt, _ = db:prepare("SELECT 1")
  stmt:close()
  stmt:close()
  db:close()
  db:close()
end
test_double_close_safe()

-- Integration tests

local function test_transaction()
  local db = sqlite.open(":memory:")
  db:exec("CREATE TABLE t (id INTEGER PRIMARY KEY, name TEXT)")

  db:exec("BEGIN TRANSACTION")
  db:exec("INSERT INTO t (name) VALUES ('inside tx')")
  db:exec("ROLLBACK")

  local count = 0
  for _ in db:query("SELECT * FROM t") do
    count = count + 1
  end
  assert(count == 0, "should have 0 rows after rollback")

  db:exec("BEGIN TRANSACTION")
  db:exec("INSERT INTO t (name) VALUES ('committed')")
  db:exec("COMMIT")

  count = 0
  for _ in db:query("SELECT * FROM t") do
    count = count + 1
  end
  assert(count == 1, "should have 1 row after commit")
  db:close()
end
test_transaction()

local function test_multiple_params()
  local db = sqlite.open(":memory:")
  db:exec("CREATE TABLE t (a TEXT, b INTEGER, c REAL)")

  local stmt = db:prepare("INSERT INTO t (a, b, c) VALUES (?, ?, ?)")
  stmt:bind("hello", 42, 3.14)
  stmt:exec()
  stmt:close()

  for row in db:query("SELECT * FROM t") do
    assert(row.a == "hello", "a should be 'hello'")
    assert(row.b == 42, "b should be 42")
    assert(math.abs((row.c as number) - 3.14) < 0.001, "c should be ~3.14")
  end
  db:close()
end
test_multiple_params()

local function test_null_values()
  local db = sqlite.open(":memory:")
  db:exec("CREATE TABLE t (id INTEGER PRIMARY KEY, name TEXT)")
  db:exec("INSERT INTO t (name) VALUES (NULL)")

  for row in db:query("SELECT * FROM t") do
    assert(row.name == nil, "name should be nil")
  end
  db:close()
end
test_null_values()

local function test_nested_queries()
  local db = sqlite.open(":memory:")
  db:exec("CREATE TABLE parents (id INTEGER PRIMARY KEY, name TEXT)")
  db:exec("CREATE TABLE children (id INTEGER PRIMARY KEY, parent_id INTEGER, name TEXT)")
  db:exec("INSERT INTO parents (name) VALUES ('Alice'), ('Bob')")
  db:exec("INSERT INTO children (parent_id, name) VALUES (1, 'Child1'), (1, 'Child2'), (2, 'Child3')")

  local results: {string} = {}
  for parent in db:query("SELECT * FROM parents ORDER BY id") do
    for child in db:query("SELECT * FROM children WHERE parent_id = ? ORDER BY id", parent.id) do
      table.insert(results, (parent.name as string) .. "->" .. (child.name as string))
    end
  end

  assert(#results == 3, "should get 3 parent-child pairs")
  assert(results[1] == "Alice->Child1", "first pair")
  assert(results[2] == "Alice->Child2", "second pair")
  assert(results[3] == "Bob->Child3", "third pair")
  db:close()
end
test_nested_queries()

-- Nil handling in bind

local function test_exec_trailing_nils()
  local db = sqlite.open(":memory:")
  db:exec("CREATE TABLE t (a TEXT, b TEXT, c TEXT)")

  -- trailing nils should bind as NULL, not be dropped
  local ok, err = db:exec("INSERT INTO t (a, b, c) VALUES (?, ?, ?)", "hello", nil, nil)
  assert(ok, "exec with trailing nils should succeed: " .. tostring(err))

  for row in db:query("SELECT * FROM t") do
    assert(row.a == "hello", "a should be 'hello', got: " .. tostring(row.a))
    assert(row.b == nil, "b should be nil")
    assert(row.c == nil, "c should be nil")
  end
  db:close()
end
test_exec_trailing_nils()

local function test_exec_middle_nils()
  local db = sqlite.open(":memory:")
  db:exec("CREATE TABLE t (a TEXT, b TEXT, c TEXT)")

  local ok, err = db:exec("INSERT INTO t (a, b, c) VALUES (?, ?, ?)", nil, "middle", nil)
  assert(ok, "exec with middle nils should succeed: " .. tostring(err))

  for row in db:query("SELECT * FROM t") do
    assert(row.a == nil, "a should be nil")
    assert(row.b == "middle", "b should be 'middle'")
    assert(row.c == nil, "c should be nil")
  end
  db:close()
end
test_exec_middle_nils()

local function test_bind_trailing_nils()
  local db = sqlite.open(":memory:")
  db:exec("CREATE TABLE t (a TEXT, b INTEGER, c TEXT)")

  local stmt = db:prepare("INSERT INTO t (a, b, c) VALUES (?, ?, ?)")
  local ok, err = stmt:bind("first", 42, nil)
  assert(ok, "bind with trailing nil should succeed: " .. tostring(err))
  stmt:exec()
  stmt:close()

  for row in db:query("SELECT * FROM t") do
    assert(row.a == "first", "a should be 'first'")
    assert(row.b == 42, "b should be 42")
    assert(row.c == nil, "c should be nil")
  end
  db:close()
end
test_bind_trailing_nils()

-- bind_list

local function test_bind_list()
  local db = sqlite.open(":memory:")
  db:exec("CREATE TABLE t (a TEXT, b INTEGER, c TEXT)")

  local stmt = db:prepare("INSERT INTO t (a, b, c) VALUES (?, ?, ?)")
  local values = {"hello", nil, "world"}
  local ok, err = stmt:bind_list(values, 3)
  assert(ok, "bind_list should succeed: " .. tostring(err))
  stmt:exec()
  stmt:close()

  for row in db:query("SELECT * FROM t") do
    assert(row.a == "hello", "a should be 'hello'")
    assert(row.b == nil, "b should be nil")
    assert(row.c == "world", "c should be 'world'")
  end
  db:close()
end
test_bind_list()

-- exec_list

local function test_exec_list()
  local db = sqlite.open(":memory:")
  db:exec("CREATE TABLE t (a TEXT, b TEXT, c TEXT, d INTEGER)")

  local values = {"one", nil, nil, 42}
  local ok, err = db:exec_list(
    "INSERT INTO t (a, b, c, d) VALUES (?, ?, ?, ?)",
    values, 4)
  assert(ok, "exec_list should succeed: " .. tostring(err))

  for row in db:query("SELECT * FROM t") do
    assert(row.a == "one", "a should be 'one'")
    assert(row.b == nil, "b should be nil")
    assert(row.c == nil, "c should be nil")
    assert(row.d == 42, "d should be 42")
  end
  db:close()
end
test_exec_list()

local function test_exec_list_all_nils()
  local db = sqlite.open(":memory:")
  db:exec("CREATE TABLE t (a TEXT, b TEXT)")

  local values = {nil, nil}
  local ok, err = db:exec_list(
    "INSERT INTO t (a, b) VALUES (?, ?)",
    values, 2)
  assert(ok, "exec_list with all nils should succeed: " .. tostring(err))

  for row in db:query("SELECT * FROM t") do
    assert(row.a == nil, "a should be nil")
    assert(row.b == nil, "b should be nil")
  end
  db:close()
end
test_exec_list_all_nils()

-- query_list

local function test_query_list()
  local db = sqlite.open(":memory:")
  db:exec("CREATE TABLE t (a TEXT, b TEXT)")
  db:exec("INSERT INTO t VALUES ('x', 'y'), ('a', 'b')")

  local values = {"x"}
  local rows = {}
  for row in db:query_list("SELECT * FROM t WHERE a = ?", values, 1) do
    table.insert(rows, row)
  end
  assert(#rows == 1, "should get 1 row")
  assert((rows[1] as {string:any}).a == "x", "a should be 'x'")
  db:close()
end
test_query_list()

-- query_one

local function test_query_one_found()
  local db = sqlite.open(":memory:")
  db:exec("CREATE TABLE t (id INTEGER PRIMARY KEY, name TEXT)")
  db:exec("INSERT INTO t (name) VALUES ('Alice'), ('Bob')")

  local row = db:query_one("SELECT * FROM t WHERE id = ?", 1)
  assert(row, "should find row")
  assert(row.name == "Alice", "name should be Alice")
  db:close()
end
test_query_one_found()

local function test_query_one_not_found()
  local db = sqlite.open(":memory:")
  db:exec("CREATE TABLE t (id INTEGER PRIMARY KEY, name TEXT)")

  local row = db:query_one("SELECT * FROM t WHERE id = ?", 999)
  assert(row == nil, "should return nil for no match")
  db:close()
end
test_query_one_not_found()

local function test_query_one_returns_first()
  local db = sqlite.open(":memory:")
  db:exec("CREATE TABLE t (id INTEGER PRIMARY KEY, name TEXT)")
  db:exec("INSERT INTO t (name) VALUES ('Alice'), ('Bob'), ('Carol')")

  local row = db:query_one("SELECT * FROM t ORDER BY id")
  assert(row, "should find a row")
  assert(row.name == "Alice", "should return first row (Alice)")
  db:close()
end
test_query_one_returns_first()

-- transaction

local function test_transaction_commit()
  local db = sqlite.open(":memory:")
  db:exec("CREATE TABLE t (id INTEGER PRIMARY KEY, name TEXT)")

  local ok, err = db:transaction(function(d: sqlite.Database)
    d:exec("INSERT INTO t (name) VALUES (?)", "inside tx")
  end)
  assert(ok, "transaction should succeed: " .. tostring(err))

  local count = 0
  for _ in db:query("SELECT * FROM t") do
    count = count + 1
  end
  assert(count == 1, "should have 1 row after committed transaction")
  db:close()
end
test_transaction_commit()

local function test_transaction_rollback_on_error()
  local db = sqlite.open(":memory:")
  db:exec("CREATE TABLE t (id INTEGER PRIMARY KEY, name TEXT)")

  local ok, err = db:transaction(function(d: sqlite.Database)
    d:exec("INSERT INTO t (name) VALUES (?)", "will be rolled back")
    error("something went wrong")
  end)
  assert(not ok, "transaction should fail")
  assert(err and err:match("something went wrong"), "should include error message")

  local count = 0
  for _ in db:query("SELECT * FROM t") do
    count = count + 1
  end
  assert(count == 0, "should have 0 rows after rollback")
  db:close()
end
test_transaction_rollback_on_error()

local function test_transaction_multiple_ops()
  local db = sqlite.open(":memory:")
  db:exec("CREATE TABLE t (id INTEGER PRIMARY KEY, name TEXT)")

  local ok, _ = db:transaction(function(d: sqlite.Database)
    d:exec("INSERT INTO t (name) VALUES (?)", "Alice")
    d:exec("INSERT INTO t (name) VALUES (?)", "Bob")
    d:exec("INSERT INTO t (name) VALUES (?)", "Carol")
  end)
  assert(ok, "transaction should succeed")

  local count = 0
  for _ in db:query("SELECT * FROM t") do
    count = count + 1
  end
  assert(count == 3, "should have 3 rows")
  db:close()
end
test_transaction_multiple_ops()

print("All sqlite tests passed")
