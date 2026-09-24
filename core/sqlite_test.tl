--- SQLite at the Lua boundary, as core/sqlite.c keeps it: a value keeps
--- its type across it, a parameter is bound by an explicit call, and a
--- handle or statement that has been closed raises from every method
--- rather than failing quietly.
---
--- Each test drives a raw handle and statement directly, not the typed
--- helpers `cosmic.sqlite` builds over them, so every C method is held
--- to its own promise.

local Sqlite = require("cosmic.sqlite")
local Store = require("cosmic.store")

--- Asserts `value, message` is the failure shape SQLite's methods use:
--- `nil` or `false`, then a non-empty message. SQLite has no errno, so
--- there is no third slot.
local function failed(value: any, message: any)
  assert(value == nil or value == false,
    "a failure must lead with nil or false, not " .. tostring(value))
  assert(type(message) == "string" and message ~= "",
    "a failure must say what went wrong")
end

--- Asserts calling `fn` with `...` raises rather than returning.
local function raises(fn: any, ...: any)
  local ok = pcall(fn as function(any...): (any...), ...)
  assert(not ok, "the call must raise")
end

local function memory(): Sqlite.Handle
  local handle, trouble = Sqlite.memory()
  assert(handle ~= nil, trouble)
  return handle
end

local function prepared(handle: Sqlite.Handle, sql: string): Sqlite.Statement
  local statement, trouble = handle:prepare(sql)
  assert(statement ~= nil, trouble)
  return statement
end

local function test_exec_runs_and_reports_a_failure()
  local handle = memory()
  local ok, trouble = handle:exec("CREATE TABLE t (a); INSERT INTO t VALUES (1)")
  assert(ok == true, trouble)
  failed(handle:exec("INSERT INTO missing VALUES (1)"))
  local _, why = handle:exec("INSERT INTO missing VALUES (1)")
  assert(why:find("no such table: missing", 1, true) ~= nil, why)
  failed(handle:exec("not sql"))
  handle:close()
end

local function test_changes_counts_the_last_statement()
  local handle = memory()
  assert(handle:exec("CREATE TABLE t (a)"))
  assert(handle:exec("INSERT INTO t VALUES (1), (2), (3)"))
  assert(handle:changes() == 3)
  assert(handle:exec("DELETE FROM t WHERE a > 1"))
  assert(handle:changes() == 2)
  handle:close()
end

local function test_prepare_reports_bad_sql()
  local handle = memory()
  failed(handle:prepare("SELECT FROM WHERE"))
  failed(handle:prepare("SELECT * FROM missing"))
  handle:close()
end

--- SQLite compiles SQL holding only whitespace or a comment into no
--- statement at all; a statement object over nothing could only ever
--- claim to be finalized, so the call fails instead.
local function test_prepare_refuses_sql_that_holds_no_statement()
  local handle = memory()
  failed(handle:prepare(""))
  failed(handle:prepare("   \n"))
  failed(handle:prepare("-- only a comment"))
  handle:close()
end

--- A statement is one statement: anything after it would never run.
local function test_prepare_refuses_sql_that_holds_two_statements()
  local handle = memory()
  failed(handle:prepare("SELECT 1; SELECT 2"))
  failed(handle:prepare("SELECT 1; not sql"))
  prepared(handle, "SELECT 1;  -- a trailing comment\n"):finalize()
  handle:close()
end

local function test_last_insert_rowid_names_the_row_just_made()
  local handle = memory()
  assert(handle:exec("CREATE TABLE t (a)"))
  assert(handle:exec("INSERT INTO t VALUES ('x'), ('y')"))
  assert(handle:last_insert_rowid() == 2)
  handle:close()
end

local function test_every_kind_binds_and_reads_back_as_itself()
  local handle = memory()
  local statement = prepared(handle, "SELECT ?1, ?2, ?3, ?4, ?5")
  assert(statement:parameters() == 5)
  assert(statement:bind_integer(1, 9007199254740993))
  assert(statement:bind_number(2, 0.5))
  assert(statement:bind_text(3, "text"))
  assert(statement:bind_blob(4, "b\0l\0b"))
  assert(statement:bind_null(5))
  assert(statement:step() == "row")
  assert(statement:columns() == 5)
  assert(statement:kind(0) == "integer")
  assert(statement:kind(1) == "number")
  assert(statement:kind(2) == "text")
  assert(statement:kind(3) == "blob")
  assert(statement:kind(4) == "null")
  assert(statement:integer(0) == 9007199254740993, "an integer keeps every bit")
  assert(statement:number(1) == 0.5)
  assert(statement:bytes(2) == "text")
  assert(statement:bytes(3) == "b\0l\0b", "a blob keeps its zero bytes")
  assert(statement:bytes(4) == "", "a null reads as no bytes")
  assert(statement:step() == "done")
  statement:finalize()
  handle:close()
end

local function test_binding_past_the_last_parameter_fails()
  local handle = memory()
  local statement = prepared(handle, "SELECT ?1")
  failed(statement:bind_integer(2, 1))
  failed(statement:bind_null(0))
  statement:finalize()
  handle:close()
end

local function test_step_reports_a_constraint_failure()
  local handle = memory()
  assert(handle:exec("CREATE TABLE t (a UNIQUE)"))
  local statement = prepared(handle, "INSERT INTO t VALUES (?1)")
  assert(statement:bind_integer(1, 1))
  assert(statement:step() == "done")
  assert(statement:reset())
  assert(statement:bind_integer(1, 1))
  failed(statement:step())
  statement:finalize()
  handle:close()
end

local function test_reset_runs_again_and_clears_bindings()
  local handle = memory()
  local statement = prepared(handle, "SELECT ?1")
  assert(statement:bind_text(1, "first"))
  assert(statement:step() == "row")
  assert(statement:bytes(0) == "first")
  local ok, trouble = statement:reset()
  assert(ok == true, trouble)
  assert(statement:step() == "row")
  assert(statement:kind(0) == "null", "reset clears what was bound")
  statement:finalize()
  handle:close()
end

local function test_a_finalized_statement_raises_from_every_method()
  local handle = memory()
  local statement = prepared(handle, "SELECT ?1")
  assert(select("#", statement:finalize()) == 0, "finalizing returns nothing")
  assert(select("#", statement:finalize()) == 0, "finalizing twice is harmless")
  for _, method in ipairs({ "step", "columns", "reset", "parameters" }) do
    raises((statement as {string: any})[method], statement)
  end
  for _, method in ipairs({ "bind_null", "kind", "integer", "number", "bytes" }) do
    raises((statement as {string: any})[method], statement, 1)
  end
  raises(statement.bind_integer, statement, 1, 1)
  raises(statement.bind_number, statement, 1, 1.0)
  raises(statement.bind_text, statement, 1, "x")
  raises(statement.bind_blob, statement, 1, "x")
  handle:close()
end

local function test_close_refuses_while_a_statement_is_open()
  local handle = memory()
  local statement = prepared(handle, "SELECT 1")
  failed(handle:close())
  statement:finalize()
  local ok, trouble = handle:close()
  assert(ok == true, trouble)
end

local function test_a_closed_handle_raises_from_every_method()
  local handle = memory()
  assert(handle:close() == true)
  assert(handle:close() == true, "closing twice is harmless")
  raises(handle.exec, handle, "SELECT 1")
  raises(handle.prepare, handle, "SELECT 1")
  raises(handle.changes, handle)
  raises(handle.last_insert_rowid, handle)
end

local function test_open_reports_a_path_it_cannot_open(tmp: string)
  failed(Sqlite.open(tmp .. "/missing/db", true))
  -- Read-only never creates the file it was asked for.
  failed(Sqlite.open(tmp .. "/missing.db"))
end

local function test_a_nul_byte_in_a_path_or_exec_sql_is_refused(tmp: string)
  -- SQLite reads both as C strings, so the NUL used to cut them short:
  -- the path opened tmp/a.db, and exec skipped what followed
  local handle, trouble = Sqlite.open(tmp .. "/a.db\0.evil", true)
  failed(handle, trouble)
  assert(trouble:find("NUL", 1, true) ~= nil, trouble)
  local db = memory()
  assert(db:exec("CREATE TABLE t (a)"))
  local ok, why = db:exec("INSERT INTO t VALUES (1)\0; INSERT INTO t VALUES (2)")
  failed(ok, why)
  local count = prepared(db, "SELECT count(*) FROM t")
  assert(count:step() == "row" and count:integer(0) == 0)
  count:finalize()
  db:close()
end

local function test_a_file_database_persists(tmp: string)
  local path = tmp .. "/a.db"
  local handle, trouble = Sqlite.open(path, true)
  assert(handle ~= nil, trouble)
  assert(handle:exec("CREATE TABLE t (a); INSERT INTO t VALUES ('kept')"))
  assert(handle:close())
  local again = assert(Sqlite.open(path))
  local statement = prepared(again, "SELECT a FROM t")
  assert(statement:step() == "row")
  assert(statement:bytes(0) == "kept")
  failed(again:exec("INSERT INTO t VALUES ('refused')"))
  statement:finalize()
  again:close()
end

--- A column is read only from the row a statement is on: out of range,
--- before the first step, and after the last are each an argument no
--- correct program passes, not a value SQLite happens to hand back.
local function test_a_column_outside_the_current_row_raises()
  local handle = memory()
  local statement = prepared(handle, "SELECT 1, 'two'")
  for _, method in ipairs({ "kind", "integer", "number", "bytes" }) do
    raises((statement as {string: any})[method], statement, 0)
  end
  assert(statement:step() == "row")
  assert(statement:integer(0) == 1 and statement:bytes(1) == "two")
  for _, method in ipairs({ "kind", "integer", "number", "bytes" }) do
    raises((statement as {string: any})[method], statement, 2)
    raises((statement as {string: any})[method], statement, -1)
  end
  assert(statement:step() == "done")
  raises(statement.integer, statement, 0)
  statement:finalize()
  handle:close()
end

--- An index past what an int holds is refused, not truncated into one
--- that happens to exist: 2^32 + 1 is not parameter 1.
local function test_an_index_past_an_int_raises()
  local handle = memory()
  local statement = prepared(handle, "SELECT ?1")
  raises(statement.bind_integer, statement, (1 << 32) + 1, 7)
  raises(statement.bind_null, statement, (1 << 32) + 1)
  assert(statement:step() == "row")
  raises(statement.integer, statement, 1 << 32)
  statement:finalize()
  handle:close()
end

--- A borrowed handle on a store database reads, and nothing else: a
--- read-only open still leaves a connection a writable temp schema and
--- ATTACH, and a temp `modules` stands in front of the rows `require`
--- loads -- a planted row once replaced `cosmic.compress` for every
--- later require, and a temp view of that name made the next require
--- end the process. Each is refused, and require is unaffected.
local function test_a_store_database_handle_only_reads()
  local databases = Store.databases()
  assert(#databases >= 1, "the store searches the binary's own database")
  for _, db in ipairs(databases) do
    failed(db:exec("CREATE TEMP TABLE modules (path TEXT, bytecode BLOB, kind TEXT)"))
    failed(db:exec("CREATE TEMP VIEW modules AS SELECT 1 AS path"))
    failed(db:exec("CREATE TEMP TRIGGER t AFTER INSERT ON meta BEGIN SELECT 1; END"))
    failed(db:exec("ATTACH DATABASE ':memory:' AS other"))
    failed(db:exec("INSERT INTO meta (key, value) VALUES ('planted', 'x')"))
    failed(db:exec("PRAGMA query_only = 0"))
    failed(db:exec("BEGIN"))
    local statement = prepared(db, "SELECT count(*) FROM modules")
    assert(statement:step() == "row")
    statement:finalize()
  end
  local Compress = require("cosmic.compress")
  local packed = assert(Compress.deflate("unaffected"))
  assert(Compress.inflate(packed, 10) == "unaffected")
  assert(Store.bytecode("cosmic.fs"))
end
