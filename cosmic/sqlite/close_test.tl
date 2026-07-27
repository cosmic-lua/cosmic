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
  db:exec("CREATE TABLE t (id INTEGER PRIMARY KEY, name TEXT)")
  db:exec("INSERT INTO t (name) VALUES ('a'), ('b'), ('c')")

  local rows = check.must(db:query("SELECT * FROM t ORDER BY id"))
  local first = rows()
  assert(first and first.name == "a", "should get first row")
  rows:close()
  assert(rows() == nil, "closed iterator must yield nil")
  assert(rows:err() == nil, "close is not a step error")

  -- The cached statement slot must be usable again for the same SQL.
  local n = 0
  for _ in check.must(db:query("SELECT * FROM t ORDER BY id")) do
    n = n + 1
  end
  assert(n == 3, "re-query after close should see all rows, got: " .. tostring(n))
  db:close()
end
test_query_close_releases_early()

local function test_query_close_idempotent()
  local db = check.must(sqlite.open(":memory:"))
  db:exec("CREATE TABLE t (id INTEGER PRIMARY KEY)")
  db:exec("INSERT INTO t DEFAULT VALUES")

  local rows = check.must(db:query("SELECT * FROM t"))
  rows:close()
  rows:close()

  local drained = check.must(db:query("SELECT * FROM t"))
  while drained() ~= nil do end
  drained:close()
  db:close()
end
test_query_close_idempotent()

local function test_query_to_be_closed_scope()
  local db = check.must(sqlite.open(":memory:"))
  db:exec("CREATE TABLE t (id INTEGER PRIMARY KEY, name TEXT)")
  db:exec("INSERT INTO t (name) VALUES ('a'), ('b')")

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
  db:close()
end
test_query_to_be_closed_scope()

local function test_query_abandoned_iterator_collected()
  local db = check.must(sqlite.open(":memory:"))
  db:exec("CREATE TABLE t (id INTEGER PRIMARY KEY)")
  db:exec("INSERT INTO t DEFAULT VALUES")

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
  db:close()
end
test_query_abandoned_iterator_collected()

local function test_query_list_close_early()
  local db = check.must(sqlite.open(":memory:"))
  db:exec("CREATE TABLE t (id INTEGER PRIMARY KEY, name TEXT)")
  db:exec("INSERT INTO t (name) VALUES ('a'), ('b')")

  local rows = check.must(db:query_list("SELECT * FROM t WHERE name != ? ORDER BY id", {"z"}))
  local first = rows()
  assert(first and first.name == "a", "should get first row")
  rows:close()
  assert(rows() == nil, "closed query_list iterator must yield nil")
  db:close()
end
test_query_list_close_early()
