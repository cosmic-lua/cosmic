#!/usr/bin/env cosmic
--- Tests for abandoned cosmic.sqlite query iterators: close(), the
--- __close metamethod, and the GC backstop all release the underlying
--- prepared statement. Lives in its own file so advanced_test.tl stays
--- under the 500-line cap.

local check = require("cosmic.check")
local sqlite = require("cosmic.sqlite")

-- Abandoned query iterators: close(), <close>, and GC release the statement

local function test_query_close_releases_early()
  local db = check.must(sqlite.open(":memory:"))
  assert(db:exec("CREATE TABLE t (id INTEGER PRIMARY KEY, name TEXT)"))
  assert(db:exec("INSERT INTO t (name) VALUES ('a'), ('b'), ('c')"))

  local rows = check.must(db:query("SELECT * FROM t ORDER BY id"))
  local first = rows()
  assert(first and first.name == "a", "should get first row")
  assert(rows:close())
  assert(rows() == nil, "closed iterator must yield nil")
  assert(rows:err() == nil, "close is not a step error")

  -- The cached statement slot must be usable again for the same SQL.
  local n = 0
  for _ in check.must(db:query("SELECT * FROM t ORDER BY id")) do
    n = n + 1
  end
  assert(n == 3, "re-query after close should see all rows, got: " .. tostring(n))
  assert(db:close())
end
test_query_close_releases_early()

local function test_query_close_idempotent()
  local db = check.must(sqlite.open(":memory:"))
  assert(db:exec("CREATE TABLE t (id INTEGER PRIMARY KEY)"))
  assert(db:exec("INSERT INTO t DEFAULT VALUES"))

  local rows = check.must(db:query("SELECT * FROM t"))
  assert(rows:close())
  assert(rows:close())

  local drained = check.must(db:query("SELECT * FROM t"))
  while drained() ~= nil do end
  assert(drained:close())
  assert(db:close())
end
test_query_close_idempotent()

local function test_query_to_be_closed_scope()
  local db = check.must(sqlite.open(":memory:"))
  assert(db:exec("CREATE TABLE t (id INTEGER PRIMARY KEY, name TEXT)"))
  assert(db:exec("INSERT INTO t (name) VALUES ('a'), ('b')"))

  -- The repo build compiles Teal targeting 5.3 syntax, so exercise the
  -- __close metamethod directly instead of a `local rows <close> = ...`
  -- declaration (which works in user scripts running on the 5.4 runtime).
  local rows = check.must(db:query("SELECT * FROM t ORDER BY id"))
  local first = rows()
  assert(first and first.name == "a", "should get first row")
  local mt = getmetatable(rows) as {string: any} -- cast: raw metatable access
  local close_mm = mt["__close"] as function(any, any) -- cast: from any
  assert(close_mm, "Rows must have a __close metamethod")
  close_mm(rows, nil)
  assert(rows() == nil, "__close must release the iterator")

  local n = 0
  for _ in check.must(db:query("SELECT * FROM t ORDER BY id")) do
    n = n + 1
  end
  assert(n == 2, "re-query after <close> should see all rows, got: " .. tostring(n))
  assert(db:close())
end
test_query_to_be_closed_scope()

local function test_query_abandoned_iterator_collected()
  local db = check.must(sqlite.open(":memory:"))
  assert(db:exec("CREATE TABLE t (id INTEGER PRIMARY KEY)"))
  assert(db:exec("INSERT INTO t DEFAULT VALUES"))

  do
    local rows = check.must(db:query("SELECT * FROM t"))
    assert(rows() ~= nil, "should get a row")
    -- Abandon without close: the GC backstop must release the statement.
  end
  collectgarbage("collect")
  collectgarbage("collect")

  local n = 0
  for _ in check.must(db:query("SELECT * FROM t")) do
    n = n + 1
  end
  assert(n == 1, "query after GC of abandoned iterator should work")
  assert(db:close())
end
test_query_abandoned_iterator_collected()

local function test_query_list_close_early()
  local db = check.must(sqlite.open(":memory:"))
  assert(db:exec("CREATE TABLE t (id INTEGER PRIMARY KEY, name TEXT)"))
  assert(db:exec("INSERT INTO t (name) VALUES ('a'), ('b')"))

  local rows = check.must(db:query("SELECT * FROM t WHERE name != ? ORDER BY id", {"z"}))
  local first = rows()
  assert(first and first.name == "a", "should get first row")
  assert(rows:close())
  assert(rows() == nil, "closed query_list iterator must yield nil")
  assert(db:close())
end
test_query_list_close_early()

-- Statement:rows() shares row_iter.tl's iteration body with db:query (see
-- cosmic.sqlite.row_iter); this exercises it directly, plus close
-- semantics: close()/__close end iteration but must NOT finalize the
-- underlying Statement -- unlike db:query's Rows (which owns a cache slot
-- or a throwaway statement), a Statement:rows() is a view over a
-- caller-owned Statement that outlives its iterators and can be
-- reset()+bound again after the Rows is done.

local function test_statement_rows_basic_iteration()
  local db = check.must(sqlite.open(":memory:"))
  assert(db:exec("CREATE TABLE t (id INTEGER PRIMARY KEY, name TEXT)"))
  assert(db:exec("INSERT INTO t (name) VALUES ('Alice'), ('Bob'), ('Carol')"))

  local stmt = check.must(db:prepare("SELECT * FROM t ORDER BY id"))
  local rows = stmt:rows()
  local names: {string} = {}
  for row in rows do
    table.insert(names, check.must(sqlite.column_text(row, "name")))
  end
  assert(#names == 3, "should get 3 rows")
  assert(names[1] == "Alice" and names[2] == "Bob" and names[3] == "Carol",
    "rows should be in insertion order, got: " .. table.concat(names, ","))
  assert(rows:err() == nil, "clean iteration should report no step error")
  assert(stmt:close())
  assert(db:close())
end
test_statement_rows_basic_iteration()

local function test_statement_rows_close_does_not_finalize_statement()
  local db = check.must(sqlite.open(":memory:"))
  assert(db:exec("CREATE TABLE t (id INTEGER PRIMARY KEY, name TEXT)"))
  assert(db:exec("INSERT INTO t (name) VALUES ('a'), ('b'), ('c')"))

  local stmt = check.must(db:prepare("SELECT * FROM t ORDER BY id"))
  local rows = stmt:rows()
  local first = rows()
  assert(first and first.name == "a", "should get first row")
  assert(rows:close())
  assert(rows() == nil, "closed iterator must yield nil")
  assert(rows:err() == nil, "close is not a step error")

  -- The Statement must still be usable: rows():close() must not have
  -- finalized raw_stmt out from under it.
  stmt:reset()
  local n = 0
  local rows2 = stmt:rows()
  while rows2() ~= nil do
    n = n + 1
  end
  assert(n == 3, "statement must be reusable after rows():close(), got: " .. tostring(n))
  assert(stmt:close())
  assert(db:close())
end
test_statement_rows_close_does_not_finalize_statement()

local function test_statement_rows_to_be_closed_scope()
  local db = check.must(sqlite.open(":memory:"))
  assert(db:exec("CREATE TABLE t (id INTEGER PRIMARY KEY, name TEXT)"))
  assert(db:exec("INSERT INTO t (name) VALUES ('a'), ('b')"))

  local stmt = check.must(db:prepare("SELECT * FROM t ORDER BY id"))
  local rows = stmt:rows()
  local first = rows()
  assert(first and first.name == "a", "should get first row")
  -- Exercise the __close metamethod directly (see the db:query tests
  -- above for why this repo's tests don't use `local x <close> = ...`).
  local mt = getmetatable(rows) as {string: any} -- cast: raw metatable access
  local close_mm = mt["__close"] as function(any, any) -- cast: from any
  assert(close_mm, "Statement:rows() must have a __close metamethod")
  close_mm(rows, nil)
  assert(rows() == nil, "__close must release the iterator")

  -- Again: the Statement must survive the Rows' __close.
  stmt:reset()
  local n = 0
  local rows2 = stmt:rows()
  while rows2() ~= nil do
    n = n + 1
  end
  assert(n == 2, "statement must be reusable after rows() <close>, got: " .. tostring(n))
  assert(stmt:close())
  assert(db:close())
end
test_statement_rows_to_be_closed_scope()

local function test_statement_rows_close_idempotent()
  local db = check.must(sqlite.open(":memory:"))
  assert(db:exec("CREATE TABLE t (id INTEGER PRIMARY KEY)"))
  assert(db:exec("INSERT INTO t DEFAULT VALUES"))

  local stmt = check.must(db:prepare("SELECT * FROM t"))
  local rows = stmt:rows()
  assert(rows:close())
  assert(rows:close())
  assert(stmt:close())
  assert(db:close())
end
test_statement_rows_close_idempotent()
