--- `handle:reads_only()` and [`Sqlite.open`]'s `reads_only`: a handle held to
--- queries prepares a SELECT and a PRAGMA that reads, and refuses everything
--- else as it is prepared, saying what it refused.

local Fs = require("cosmic.fs")
local Sqlite = require("cosmic.sqlite")

--- A database file at `tmp` with one table of one row, closed.
local function made(tmp: string): string
  local path = tmp .. "/held.db"
  local db = assert(Sqlite.open(path, { writable = true }))
  assert(db:exec("CREATE TABLE t (a INTEGER); INSERT INTO t VALUES (1); PRAGMA user_version = 3"))
  assert(db:close())
  return path
end

local function test_queries_and_reading_pragmas_run(tmp: string)
  local db = assert(Sqlite.open(made(tmp), { reads_only = true }))
  for _, sql in ipairs({ "SELECT a FROM t", "WITH RECURSIVE c(x) AS (SELECT 1 UNION ALL SELECT x + 1 FROM c LIMIT 3) SELECT x FROM c",
      "PRAGMA table_info(t)", "PRAGMA user_version", "SELECT name FROM pragma_table_info('t')",
      "PRAGMA integrity_check", "SELECT sha256('x')" }) do
    assert(db:rows(sql))
  end
  assert(assert(assert(db:rows("PRAGMA user_version"))[1]):integer(1) == 3)
  assert(db:close())
end

local function test_everything_else_is_refused_saying_what(tmp: string)
  local path = made(tmp)
  local before = assert(Fs.read(path))
  local db = assert(Sqlite.open(path, { reads_only = true }))
  for sql, says in pairs({
      ["DELETE FROM t"] = "a write",
      ["INSERT INTO t VALUES (2)"] = "a write",
      ["CREATE TEMP TABLE u (a)"] = "a temporary or virtual table",
      ["ATTACH ':memory:' AS m"] = "an ATTACH",
      ["PRAGMA user_version = 9"] = "a PRAGMA that sets",
      ["PRAGMA query_only = 0"] = "a PRAGMA that sets",
      ["PRAGMA query_only(0)"] = "a PRAGMA that sets",
      ["PRAGMA main.query_only = 0"] = "a PRAGMA that sets",
      ["CREATE TABLE temp.u (a)"] = "a temporary or virtual table",
      ["PRAGMA writable_schema"] = "a PRAGMA that sets",
      ["BEGIN"] = "a transaction",
      ["ANALYZE"] = "a write",
  }) do
    local ok, why = db:run(sql)
    assert(not ok, sql .. " ran")
    assert(why.code == Sqlite.AUTH, sql .. ": " .. tostring(why))
    assert(why.message:find("reads_only", 1, true) ~= nil and why.message:find(says, 1, true) ~= nil,
      sql .. ": " .. why.message)
  end
  -- A VACUUM is refused through the ATTACH it runs.
  for _, sql in ipairs({ "VACUUM", "VACUUM INTO '" .. tmp .. "/copy.db'" }) do
    local vacuumed, why = db:exec(sql)
    assert(not vacuumed and why.message:find("VACUUM and VACUUM INTO attach one", 1, true) ~= nil,
      sql .. ": " .. tostring(why))
  end
  assert(not assert(Fs.status(tmp .. "/copy.db")).exists, "VACUUM INTO made a file")
  assert(db:close())
  assert(assert(Fs.read(path)) == before, "the database changed")
end

local function test_a_held_handle_stays_held(tmp: string)
  local db = assert(Sqlite.open(made(tmp)))
  assert(db:reads_only())
  assert(db:reads_only())
  local ok, why = pcall(function() db:limit("attached", 1) end)
  assert(not ok and tostring(why):find("attaches nothing", 1, true) ~= nil, tostring(why))
  assert(db:limit("attached", -1) == 0)
  assert(db:close())
end

local function test_writable_and_reads_only_raise(tmp: string)
  local ok, why = pcall(function()
    local _, _ = Sqlite.open(tmp .. "/w.db", { writable = true, reads_only = true })
  end)
  assert(not ok and tostring(why):find("both writable and reads_only", 1, true) ~= nil, tostring(why))
end

local function test_a_memory_database_filled_then_held()
  local db = assert(Sqlite.memory())
  assert(db:exec("CREATE TABLE t (a); INSERT INTO t VALUES (1)"))
  assert(db:reads_only())
  assert(db:rows("SELECT a FROM t"))
  local ok, why = db:run("UPDATE t SET a = 2")
  assert(not ok and why.code == Sqlite.AUTH, tostring(why))
  assert(db:close())
end

local function test_query_only_may_be_set_again_never_taken_off(tmp: string)
  local db = assert(Sqlite.open(made(tmp), { reads_only = true }))
  assert(db:exec("PRAGMA query_only = 1"))
  assert(db:exec("PRAGMA query_only = on"))
  assert(assert(assert(db:rows("PRAGMA query_only"))[1]):integer(1) == 1)
  assert(db:close())
end

--- An R*Tree prepares its writes of its own shadow tables as it connects, for a SELECT too: a held handle reads one,
--- and checks a database that holds one, but a write to it is still refused.
local function test_an_rtree_is_read_and_checked(tmp: string)
  local path = tmp .. "/boxes.db"
  local w = assert(Sqlite.open(path, { writable = true }))
  assert(w:exec("CREATE VIRTUAL TABLE r USING rtree(id, x0, x1); INSERT INTO r VALUES (1, 0, 1)"))
  assert(w:close())
  local db = assert(Sqlite.open(path, { reads_only = true }))
  assert(assert(assert(db:rows("SELECT count(*) FROM r WHERE x0 <= 0.5"))[1]):integer(1) == 1)
  assert(assert(assert(db:text_rows("PRAGMA integrity_check"))[1]):text(1) == "ok")
  assert(assert(assert(db:text_rows("SELECT rtreecheck('r')"))[1]):text(1) == "ok")
  for _, sql in ipairs({ "INSERT INTO r VALUES (2, 0, 1)", "DELETE FROM r_node" }) do
    local ok, _ = db:run(sql)
    assert(not ok, sql .. " ran")
  end
  assert(db:close())
end

--- A statement the handle kept for its SQL before the hold is prepared again under it: a write run before is
--- refused after, as it is prepared.
local function test_a_statement_kept_before_the_hold_is_refused_after()
  local db = assert(Sqlite.memory())
  assert(db:exec("CREATE TABLE t (x)"))
  assert(db:run("INSERT INTO t VALUES (?1)", { { integer = 1 } }))
  assert(db:run("INSERT INTO t VALUES (?1)", { { integer = 2 } }))
  assert(db:reads_only())
  local ran, why = db:run("INSERT INTO t VALUES (?1)", { { integer = 3 } })
  assert(not ran and why.code == Sqlite.AUTH, tostring(why))
  assert(#assert(db:text_rows("SELECT x FROM t")) == 2)
  assert(db:close())
end
