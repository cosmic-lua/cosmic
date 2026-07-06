#!/usr/bin/env cosmic
--- Advanced tests for cosmic.sqlite: nil handling, lists, transactions, named params.

local sqlite = require("cosmic.sqlite")

-- The module's Rows iterator record is not exported; mirror its shape here so
-- the fallible `db:query* -> Rows | nil` results can be cast for iteration.
local record Rows
  metamethod __call: function(self: Rows): {string: any}
  err: function(self: Rows): string
end

-- Nil handling in bind

local function test_exec_trailing_nils()
  local db = sqlite.open(":memory:") as sqlite.Database
  db:exec("CREATE TABLE t (a TEXT, b TEXT, c TEXT)")

  -- trailing nils should bind as NULL, not be dropped
  local ok, err = db:exec("INSERT INTO t (a, b, c) VALUES (?, ?, ?)", "hello", nil, nil)
  assert(ok, "exec with trailing nils should succeed: " .. tostring(err))

  for row in db:query("SELECT * FROM t") as Rows do
    assert(row.a == "hello", "a should be 'hello', got: " .. tostring(row.a))
    assert(row.b == nil, "b should be nil")
    assert(row.c == nil, "c should be nil")
  end
  db:close()
end
test_exec_trailing_nils()

local function test_exec_middle_nils()
  local db = sqlite.open(":memory:") as sqlite.Database
  db:exec("CREATE TABLE t (a TEXT, b TEXT, c TEXT)")

  local ok, err = db:exec("INSERT INTO t (a, b, c) VALUES (?, ?, ?)", nil, "middle", nil)
  assert(ok, "exec with middle nils should succeed: " .. tostring(err))

  for row in db:query("SELECT * FROM t") as Rows do
    assert(row.a == nil, "a should be nil")
    assert(row.b == "middle", "b should be 'middle'")
    assert(row.c == nil, "c should be nil")
  end
  db:close()
end
test_exec_middle_nils()

local function test_bind_trailing_nils()
  local db = sqlite.open(":memory:") as sqlite.Database
  db:exec("CREATE TABLE t (a TEXT, b INTEGER, c TEXT)")

  local stmt = db:prepare("INSERT INTO t (a, b, c) VALUES (?, ?, ?)") as sqlite.Statement
  local ok, err = stmt:bind("first", 42, nil)
  assert(ok, "bind with trailing nil should succeed: " .. tostring(err))
  stmt:exec()
  stmt:close()

  for row in db:query("SELECT * FROM t") as Rows do
    assert(row.a == "first", "a should be 'first'")
    assert(row.b == 42, "b should be 42")
    assert(row.c == nil, "c should be nil")
  end
  db:close()
end
test_bind_trailing_nils()

-- bind_list

local function test_bind_list()
  local db = sqlite.open(":memory:") as sqlite.Database
  db:exec("CREATE TABLE t (a TEXT, b INTEGER, c TEXT)")

  local stmt = db:prepare("INSERT INTO t (a, b, c) VALUES (?, ?, ?)") as sqlite.Statement
  local values = {"hello", nil, "world"}
  local ok, err = stmt:bind_list(values)
  assert(ok, "bind_list should succeed: " .. tostring(err))
  stmt:exec()
  stmt:close()

  for row in db:query("SELECT * FROM t") as Rows do
    assert(row.a == "hello", "a should be 'hello'")
    assert(row.b == nil, "b should be nil")
    assert(row.c == "world", "c should be 'world'")
  end
  db:close()
end
test_bind_list()

-- exec_list

local function test_exec_list()
  local db = sqlite.open(":memory:") as sqlite.Database
  db:exec("CREATE TABLE t (a TEXT, b TEXT, c TEXT, d INTEGER)")

  local values = {"one", nil, nil, 42}
  local ok, err = db:exec_list(
    "INSERT INTO t (a, b, c, d) VALUES (?, ?, ?, ?)",
    values)
  assert(ok, "exec_list should succeed: " .. tostring(err))

  for row in db:query("SELECT * FROM t") as Rows do
    assert(row.a == "one", "a should be 'one'")
    assert(row.b == nil, "b should be nil")
    assert(row.c == nil, "c should be nil")
    assert(row.d == 42, "d should be 42")
  end
  db:close()
end
test_exec_list()

local function test_exec_list_all_nils()
  local db = sqlite.open(":memory:") as sqlite.Database
  db:exec("CREATE TABLE t (a TEXT, b TEXT)")

  local values = {nil, nil}
  local ok, err = db:exec_list(
    "INSERT INTO t (a, b) VALUES (?, ?)",
    values)
  assert(ok, "exec_list with all nils should succeed: " .. tostring(err))

  for row in db:query("SELECT * FROM t") as Rows do
    assert(row.a == nil, "a should be nil")
    assert(row.b == nil, "b should be nil")
  end
  db:close()
end
test_exec_list_all_nils()

-- query_list

local function test_query_list()
  local db = sqlite.open(":memory:") as sqlite.Database
  db:exec("CREATE TABLE t (a TEXT, b TEXT)")
  db:exec("INSERT INTO t VALUES ('x', 'y'), ('a', 'b')")

  local values = {"x"}
  local rows = {}
  for row in db:query_list("SELECT * FROM t WHERE a = ?", values) as Rows do
    table.insert(rows, row)
  end
  assert(#rows == 1, "should get 1 row")
  assert((rows[1] as {string: any}).a == "x", "a should be 'x'")
  db:close()
end
test_query_list()

-- query_one

local function test_query_one_found()
  local db = sqlite.open(":memory:") as sqlite.Database
  db:exec("CREATE TABLE t (id INTEGER PRIMARY KEY, name TEXT)")
  db:exec("INSERT INTO t (name) VALUES ('Alice'), ('Bob')")

  local row = db:query_one("SELECT * FROM t WHERE id = ?", 1) as {string: any}
  assert(row, "should find row")
  assert(row.name == "Alice", "name should be Alice")
  db:close()
end
test_query_one_found()

local function test_query_one_not_found()
  local db = sqlite.open(":memory:") as sqlite.Database
  db:exec("CREATE TABLE t (id INTEGER PRIMARY KEY, name TEXT)")

  local row = db:query_one("SELECT * FROM t WHERE id = ?", 999)
  assert(row == nil, "should return nil for no match")
  db:close()
end
test_query_one_not_found()

local function test_query_one_returns_first()
  local db = sqlite.open(":memory:") as sqlite.Database
  db:exec("CREATE TABLE t (id INTEGER PRIMARY KEY, name TEXT)")
  db:exec("INSERT INTO t (name) VALUES ('Alice'), ('Bob'), ('Carol')")

  local row = db:query_one("SELECT * FROM t ORDER BY id") as {string: any}
  assert(row, "should find a row")
  assert(row.name == "Alice", "should return first row (Alice)")
  db:close()
end
test_query_one_returns_first()

-- transaction

local function test_transaction_commit()
  local db = sqlite.open(":memory:") as sqlite.Database
  db:exec("CREATE TABLE t (id INTEGER PRIMARY KEY, name TEXT)")

  local ok, err = db:transaction(function(d: sqlite.Database)
      d:exec("INSERT INTO t (name) VALUES (?)", "inside tx")
    end)
  assert(ok, "transaction should succeed: " .. tostring(err))

  local count = 0
  for _ in db:query("SELECT * FROM t") as Rows do
    count = count + 1
  end
  assert(count == 1, "should have 1 row after committed transaction")
  db:close()
end
test_transaction_commit()

local function test_transaction_rollback_on_error()
  local db = sqlite.open(":memory:") as sqlite.Database
  db:exec("CREATE TABLE t (id INTEGER PRIMARY KEY, name TEXT)")

  local ok, err = db:transaction(function(d: sqlite.Database)
      d:exec("INSERT INTO t (name) VALUES (?)", "will be rolled back")
      error("something went wrong")
    end)
  assert(not ok, "transaction should fail")
  assert(err and err:match("something went wrong"), "should include error message")

  local count = 0
  for _ in db:query("SELECT * FROM t") as Rows do
    count = count + 1
  end
  assert(count == 0, "should have 0 rows after rollback")
  db:close()
end
test_transaction_rollback_on_error()

local function test_transaction_multiple_ops()
  local db = sqlite.open(":memory:") as sqlite.Database
  db:exec("CREATE TABLE t (id INTEGER PRIMARY KEY, name TEXT)")

  local ok, _ = db:transaction(function(d: sqlite.Database)
      d:exec("INSERT INTO t (name) VALUES (?)", "Alice")
      d:exec("INSERT INTO t (name) VALUES (?)", "Bob")
      d:exec("INSERT INTO t (name) VALUES (?)", "Carol")
    end)
  assert(ok, "transaction should succeed")

  local count = 0
  for _ in db:query("SELECT * FROM t") as Rows do
    count = count + 1
  end
  assert(count == 3, "should have 3 rows")
  db:close()
end
test_transaction_multiple_ops()

local function test_transaction_rollback_on_false()
  -- A body that returns `false, err` (the library's own failure convention)
  -- must roll back. Before the fix, transaction() discarded the returned
  -- error and COMMITted, leaving the row behind.
  local db = sqlite.open(":memory:") as sqlite.Database
  db:exec("CREATE TABLE t (id INTEGER PRIMARY KEY, name TEXT)")

  local body: function(sqlite.Database): (boolean, string) = function(d: sqlite.Database): (boolean, string)
    d:exec("INSERT INTO t (name) VALUES (?)", "doomed")
    return false, "boom"
  end
  local ok, err = db:transaction(body)
  assert(ok == false, "should report failure, got ok=" .. tostring(ok))
  assert(err == "boom", "should surface the body error, got " .. tostring(err))

  local count = 0
  for _ in db:query("SELECT * FROM t") as Rows do
    count = count + 1
  end
  assert(count == 0, "row must roll back when body returns false, got " .. tostring(count))
  db:close()
end
test_transaction_rollback_on_false()

local function test_transaction_rollback_on_nil_err()
  -- `nil, err` is the same failure convention and must also roll back.
  local db = sqlite.open(":memory:") as sqlite.Database
  db:exec("CREATE TABLE t (id INTEGER PRIMARY KEY, name TEXT)")

  local body: function(sqlite.Database): (boolean, string) = function(d: sqlite.Database): (boolean, string)
    d:exec("INSERT INTO t (name) VALUES (?)", "doomed")
    return nil, "nope"
  end
  local ok, err = db:transaction(body)
  assert(ok == false, "should report failure, got ok=" .. tostring(ok))
  assert(err == "nope", "should surface the body error, got " .. tostring(err))

  local count = 0
  for _ in db:query("SELECT * FROM t") as Rows do
    count = count + 1
  end
  assert(count == 0, "row must roll back when body returns nil, err, got " .. tostring(count))
  db:close()
end
test_transaction_rollback_on_nil_err()

local function test_transaction_commits_on_no_return()
  -- A body that returns nothing (the common case) still commits.
  local db = sqlite.open(":memory:") as sqlite.Database
  db:exec("CREATE TABLE t (id INTEGER PRIMARY KEY, name TEXT)")

  local ok, err = db:transaction(function(d: sqlite.Database)
      d:exec("INSERT INTO t (name) VALUES (?)", "kept")
    end)
  assert(ok, "should commit when body returns nothing: " .. tostring(err))

  local count = 0
  for _ in db:query("SELECT * FROM t") as Rows do
    count = count + 1
  end
  assert(count == 1, "row must commit when body returns nothing, got " .. tostring(count))
  db:close()
end
test_transaction_commits_on_no_return()

-- Named parameters

local function test_bind_named()
  local db = sqlite.open(":memory:") as sqlite.Database
  db:exec("CREATE TABLE t (a TEXT, b INTEGER, c TEXT)")

  local stmt = db:prepare("INSERT INTO t (a, b, c) VALUES (:a, :b, :c)") as sqlite.Statement
  local ok, err = stmt:bind_named({a = "hello", c = "world"})
  assert(ok, "bind_named should succeed: " .. tostring(err))
  stmt:exec()
  stmt:close()

  for row in db:query("SELECT * FROM t") as Rows do
    assert(row.a == "hello", "a should be 'hello'")
    assert(row.b == nil, "b should be nil (unbound)")
    assert(row.c == "world", "c should be 'world'")
  end
  db:close()
end
test_bind_named()

local function test_exec_named()
  local db = sqlite.open(":memory:") as sqlite.Database
  db:exec("CREATE TABLE t (a TEXT, b INTEGER, c TEXT)")

  local ok, err = db:exec_named(
    "INSERT INTO t (a, b, c) VALUES (:a, :b, :c)",
    {a = "one", b = 42})
  assert(ok, "exec_named should succeed: " .. tostring(err))

  for row in db:query("SELECT * FROM t") as Rows do
    assert(row.a == "one", "a should be 'one'")
    assert(row.b == 42, "b should be 42")
    assert(row.c == nil, "c should be nil")
  end
  db:close()
end
test_exec_named()

local function test_exec_named_all_nil()
  local db = sqlite.open(":memory:") as sqlite.Database
  db:exec("CREATE TABLE t (a TEXT, b TEXT)")

  local ok, err = db:exec_named(
    "INSERT INTO t (a, b) VALUES (:a, :b)", {})
  assert(ok, "exec_named with empty params should succeed: " .. tostring(err))

  for row in db:query("SELECT * FROM t") as Rows do
    assert(row.a == nil, "a should be nil")
    assert(row.b == nil, "b should be nil")
  end
  db:close()
end
test_exec_named_all_nil()

local function test_query_named()
  local db = sqlite.open(":memory:") as sqlite.Database
  db:exec("CREATE TABLE t (id INTEGER PRIMARY KEY, name TEXT, city TEXT)")
  db:exec("INSERT INTO t (name, city) VALUES ('Alice', 'NYC'), ('Bob', 'LA'), ('Carol', 'NYC')")

  local names: {string} = {}
  for row in db:query_named(
    "SELECT * FROM t WHERE city = :city ORDER BY id",
    {city = "NYC"}) as Rows do
    table.insert(names, row.name as string)
  end
  assert(#names == 2, "should get 2 rows")
  assert(names[1] == "Alice", "first should be Alice")
  assert(names[2] == "Carol", "second should be Carol")
  db:close()
end
test_query_named()

--- A nested query for the SAME SQL text as a still-open outer query must
--- not corrupt either cursor: db:query's statement cache (see
--- cosmic.sqlite_stmt_cache) only hands out its cached slot for a given
--- SQL text once at a time, giving a nested query for that same text its
--- own separate statement instead.
local function test_same_sql_nested_query_reentrant()
  local db = sqlite.open(":memory:") as sqlite.Database
  db:exec("CREATE TABLE t (id INTEGER PRIMARY KEY, name TEXT)")
  db:exec("INSERT INTO t (name) VALUES ('a'), ('b'), ('c')")

  local pairs_seen: {string} = {}
  for outer in db:query("SELECT * FROM t ORDER BY id") as Rows do
    for inner in db:query("SELECT * FROM t ORDER BY id") as Rows do
      table.insert(pairs_seen, (outer.name as string) .. (inner.name as string))
    end
  end

  local expected = {"aa", "ab", "ac", "ba", "bb", "bc", "ca", "cb", "cc"}
  assert(#pairs_seen == 9, "expected 9 pairs, got " .. tostring(#pairs_seen))
  for i, pair in ipairs(expected) do
    assert(pairs_seen[i] == pair,
      "pair " .. i .. ": expected " .. pair .. ", got " .. tostring(pairs_seen[i]))
  end

  -- Once both iterators are drained, the cached slot for this SQL must be
  -- available again, not left permanently "checked out".
  local row, err = db:query_one("SELECT * FROM t WHERE id = 1")
  assert(row ~= nil, "query after nested reentrant use should still work: " .. tostring(err))
  db:close()
end
test_same_sql_nested_query_reentrant()

print("All sqlite tests passed")
