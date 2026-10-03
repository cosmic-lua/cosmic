--- SQLite at the Lua boundary, as core/sqlite.c keeps it: a value keeps
--- its type across it, a parameter is bound by an explicit call, and a
--- handle or statement that has been closed raises from every method
--- rather than failing quietly.
---
--- Each test drives a raw handle and statement directly, not the typed
--- helpers [`cosmic.sqlite`] builds over them, so every C method is held
--- to its own promise.

local Fs = require("cosmic.fs")
local Sqlite = require("cosmic.sqlite")
local sys = require("cosmic.sys")

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

--- Asserts calling `fn` with `...` raises, and the message holds `says`.
local function raises_saying(says: string, fn: any, ...: any)
  local ok, why = pcall(fn as function(any...): (any...), ...)
  assert(not ok, "the call must raise")
  assert(tostring(why):find(says, 1, true) ~= nil, tostring(why))
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
    raises_saying("sqlite: the statement is closed", (statement as {string: any})[method], statement)
  end
  for _, method in ipairs({ "bind_null", "name", "kind", "integer", "number", "bytes" }) do
    raises_saying("sqlite: the statement is closed", (statement as {string: any})[method], statement, 1)
  end
  raises_saying("sqlite: the statement is closed", statement.bind_integer, statement, 1, 1)
  raises_saying("sqlite: the statement is closed", statement.bind_number, statement, 1, 1.0)
  raises_saying("sqlite: the statement is closed", statement.bind_text, statement, 1, "x")
  raises_saying("sqlite: the statement is closed", statement.bind_blob, statement, 1, "x")
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
  raises_saying("sqlite: the database handle is closed", handle.exec, handle, "SELECT 1")
  raises_saying("sqlite: the database handle is closed", handle.prepare, handle, "SELECT 1")
  raises_saying("sqlite: the database handle is closed", handle.changes, handle)
  raises_saying("sqlite: the database handle is closed", handle.last_insert_rowid, handle)
end

local function test_open_reports_a_path_it_cannot_open(tmp: string)
  failed(Sqlite.open(tmp .. "/missing/db", { writable = true }))
  -- Read-only never creates the file it was asked for.
  failed(Sqlite.open(tmp .. "/missing.db"))
end

--- Maintenance must not recreate a cache that disappeared after discovery.
local function test_existing_only_open_never_creates_a_missing_database(tmp: string)
  for _, path in ipairs({ tmp .. "/missing.db", tmp .. "/missing/db" }) do
    failed(Sqlite.open(path, { writable = true, create = false }))
    assert(not Fs.exists(path))
  end
  assert(not Fs.exists(tmp .. "/missing"))
  local path = tmp .. "/removed.db"
  local made = assert(Sqlite.open(path, { writable = true }))
  assert(made:exec("CREATE TABLE t (a)"))
  assert(made:close())
  assert(Fs.remove(path))
  failed(Sqlite.open(path, { writable = true, create = false }))
  assert(not Fs.exists(path))
end

--- Existing-only is writable, including WAL; it is not immutable mode.
local function test_existing_only_open_can_commit_to_an_existing_database(tmp: string)
  local path = tmp .. "/existing.db"
  local made = assert(Sqlite.open(path, { writable = true }))
  assert(made:exec("PRAGMA journal_mode=WAL; CREATE TABLE t (a)"))
  assert(made:close())
  local writer = assert(Sqlite.open(path, { writable = true, create = false }))
  assert(writer:exec("BEGIN; INSERT INTO t VALUES (42); COMMIT"))
  local reader = assert(Sqlite.open(path, { create = true }))
  local rows = assert(Sqlite.rows(reader, "SELECT a FROM t"))
  assert(#rows == 1 and rows[1][1].integer == 42)
  failed(reader:exec("INSERT INTO t VALUES (43)"))
  assert(reader:close())
  assert(writer:close())
end

--- Disabling named-file creation preserves SQLite's temporary databases.
local function test_existing_only_open_keeps_sqlites_temporary_paths()
  for _, path in ipairs({ "", ":memory:" }) do
    local db = assert(Sqlite.open(path, { writable = true, create = false }))
    assert(db:exec("CREATE TABLE t (a); INSERT INTO t VALUES (42)"))
    local rows = assert(Sqlite.rows(db, "SELECT a FROM t"))
    assert(rows[1][1].integer == 42)
    assert(db:close())
  end
end

--- Creation defaults stay compatible and never make a read-only open writable.
local function test_create_is_only_an_option_of_writable_open(tmp: string)
  for i, options in ipairs({ { writable = true }, { writable = true, create = true } }) do
    local db = assert(Sqlite.open(tmp .. "/created-" .. tostring(i), options))
    assert(db:exec("CREATE TABLE t (a)"))
    assert(db:close())
  end
  for _, create in ipairs({ false, true }) do
    local path = tmp .. "/readonly.db"
    failed(Sqlite.open(path, { create = create }))
    failed(Sqlite.open(path, { create = create, immutable = true }))
    assert(not Fs.exists(path))
    raises(Sqlite.open, path, { writable = true, immutable = true, create = create })
  end
end

--- The options are a table. A boolean would read as truthy through the
--- raw binding, so a Lua caller passing `true` is refused rather than
--- made writable.
local function test_open_refuses_options_that_are_not_a_table(tmp: string)
  local open: any = Sqlite.open
  for _, given in ipairs({ true, false, "writable", 1 } as {any}) do
    local ok, why = pcall(open as function(string, any): (any, any), tmp .. "/never.db", given)
    assert(not ok and tostring(why):find("sqlite: open: options is a table", 1, true) ~= nil, tostring(why))
  end
  assert(Fs.exists(tmp .. "/never.db") == false)
  -- An explicit false is the same as leaving the option out.
  failed(Sqlite.open(tmp .. "/never.db", { writable = false }))
  assert(Fs.exists(tmp .. "/never.db") == false)
end

local function test_a_nul_byte_in_a_path_or_exec_sql_is_refused(tmp: string)
  -- SQLite reads both as C strings, so the NUL used to cut them short:
  -- the path opened tmp/a.db, and exec skipped what followed
  local handle, trouble = Sqlite.open(tmp .. "/a.db\0.evil", { writable = true })
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
  local handle, trouble = Sqlite.open(path, { writable = true })
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

--- A column's name is its alias, or what SQLite calls it without one,
--- known before a row is stepped and after the last; an index outside
--- the statement's columns raises.
local function test_a_column_is_named_before_any_row()
  local handle = memory()
  local statement = prepared(handle, "SELECT 1 AS one, 'two', 3 + 4")
  assert(statement:name(0) == "one", statement:name(0))
  assert(statement:name(1) == "'two'", statement:name(1))
  assert(statement:name(2) == "3 + 4", statement:name(2))
  raises(statement.name, statement, 3)
  raises(statement.name, statement, -1)
  raises(statement.name, statement, (1 << 32) + 1)
  assert(statement:step() == "row")
  assert(statement:step() == "done")
  assert(statement:name(0) == "one")
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

--- A connection that meets another's lock waits it out, sleeping
--- through its VFS, until its busy timeout: then it says the database
--- is locked rather than waiting on.
local function test_a_locked_database_is_waited_on_then_refused(tmp: string)
  local path = tmp .. "/locked.db"
  local holder = assert(Sqlite.open(path, { writable = true }))
  assert(holder:exec("CREATE TABLE t (v INTEGER); BEGIN EXCLUSIVE; INSERT INTO t VALUES (1)"))
  local waiter = assert(Sqlite.open(path, { writable = true }))
  assert(waiter:exec("PRAGMA busy_timeout = 20"))
  local ok, trouble = waiter:exec("INSERT INTO t VALUES (2)")
  assert(not ok and trouble:find("locked", 1, true) ~= nil, trouble)
  assert(waiter:close())
  assert(holder:exec("COMMIT"))
  assert(holder:close())
end

--- A reader that finds a rollback journal beside the database asks
--- through its VFS whether a writer holds the reserved lock: one does, so
--- the journal is the writer's own, not one to roll back, and the reader
--- reads the last commit. The one place SQLite checks that lock, entered
--- here in one process rather than left to a second build's timing.
local function test_a_reader_beside_an_open_write_reads_the_last_commit(tmp: string)
  local path = tmp .. "/reserved.db"
  local writer = assert(Sqlite.open(path, { writable = true }))
  assert(writer:exec("PRAGMA journal_mode = DELETE; CREATE TABLE t (v TEXT); " ..
      "INSERT INTO t VALUES ('committed'); BEGIN; INSERT INTO t VALUES ('pending')"))
  local reader = assert(Sqlite.open(path))
  local rows = assert(Sqlite.text_rows(reader, "SELECT v FROM t"))
  assert(#rows == 1 and rows[1][1] == "committed", "the reader must see only the last commit")
  assert(reader:close())
  assert(writer:exec("COMMIT"))
  assert(writer:close())
end

local function test_an_immutable_open_makes_no_wal_or_shm_and_takes_no_lock(tmp: string)
  local path = tmp .. "/immutable.db"
  local writer = assert(Sqlite.open(path, { writable = true }))
  assert(writer:exec("PRAGMA journal_mode = WAL; CREATE TABLE t (v); INSERT INTO t VALUES (1)"))
  assert(writer:close())
  assert(Fs.exists(path .. "-wal") == false)
  local reader = assert(Sqlite.open(path, { immutable = true }))
  local rows = assert(Sqlite.text_rows(reader, "SELECT v FROM t"))
  assert(#rows == 1 and rows[1][1] == "1")
  assert(Fs.exists(path .. "-wal") == false, "an immutable open made a -wal")
  assert(Fs.exists(path .. "-shm") == false, "an immutable open made a -shm")
  failed(reader:exec("INSERT INTO t VALUES (2)"))
  assert(reader:close())
  -- A path with URI syntax in it is a filename still.
  local odd = tmp .. "/we?ird#100%.db"
  local made = assert(Sqlite.open(odd, { writable = true }))
  assert(made:exec("CREATE TABLE t (v)"))
  assert(made:close())
  local again = assert(Sqlite.open(odd, { immutable = true }))
  assert(#assert(Sqlite.text_rows(again, "SELECT v FROM t")) == 0)
  assert(again:close())
  failed(Sqlite.open(tmp .. "/absent.db", { immutable = true }))
  assert(Fs.exists(tmp .. "/absent.db") == false)
  raises(Sqlite.open, path, { writable = true, immutable = true })
end

--- The URI is built for every kind of name, relative or not, and a path
--- is never read as URI syntax or as a Windows drive.
local function test_an_immutable_open_names_the_path_it_was_given(tmp: string)
  local names = { "rel.db", "a:b.db", "\\back.db", "file:x.db", "sp ace.db",
    "caf\xc3\xa9.db", "q?vfs=memdb.db", "h#.db" }
  for _, name in ipairs(names) do
    local path = tmp .. "/" .. name
    local made = assert(Sqlite.open(path, { writable = true }))
    assert(made:exec("CREATE TABLE t (v); INSERT INTO t VALUES ('" .. name:gsub("'", "") .. "')"))
    assert(made:close())
    local read = assert(Sqlite.open(path, { immutable = true }), name)
    local rows = assert(Sqlite.text_rows(read, "SELECT v FROM t"))
    assert(rows[1][1] == name, name)
    assert(read:close())
  end
  -- The same names as relative paths, from the working directory, and one
  -- through "..".
  local here = assert(sys.getcwd())
  assert(sys.chdir(tmp))
  local trouble: string | nil
  for _, name in ipairs(names) do
    local read, why = Sqlite.open(name, { immutable = true })
    if read == nil then
      trouble = name .. ": " .. why
      break
    end
    local rows = Sqlite.text_rows(read, "SELECT v FROM t")
    if rows == nil or rows[1][1] ~= name then
      trouble = name .. " read another file"
    end
    read:close()
  end
  local dotted = Sqlite.open("../" .. (tmp:match("[^/]*$")) .. "/rel.db", { immutable = true })
  assert(sys.chdir(here))
  assert(trouble == nil, trouble)
  assert(dotted ~= nil and #assert(Sqlite.text_rows(dotted, "SELECT v FROM t")) == 1)
  assert(dotted:close())
  local embedded, why = Sqlite.open("a\0b.db", { immutable = true })
  failed(embedded, why)
end

local function test_limit_sets_a_named_limit_and_answers_the_old_one()
  local handle = memory()
  local before = handle:limit("attached", -1)
  assert(before > 0)
  assert(handle:limit("attached", 0) == before)
  assert(handle:limit("attached", -1) == 0)
  local ok, why = handle:exec("ATTACH ':memory:' AS m")
  failed(ok, why)
  assert(why:find("too many attached", 1, true) ~= nil, why)
  raises_saying("sqlite: no such limit: nonesuch", handle.limit, handle, "nonesuch", 0)
  raises(handle.limit, handle, "attached", 2 ^ 40)
  for _, name in ipairs({ "length", "sql_length", "column", "expr_depth", "compound_select",
      "vdbe_op", "function_arg", "like_pattern_length", "variable_number",
      "trigger_depth", "worker_threads" }) do
    assert(handle:limit(name, -1) >= 0, name)
  end
  handle:close()
  raises(handle.limit, handle, "attached", 0)
end

local function test_exec_result_captures_codes_and_reason_before_later_operations()
  local handle = memory()
  assert(handle:exec("CREATE TABLE t (x UNIQUE); INSERT INTO t VALUES (1)"))
  local result = handle:exec_result("INSERT INTO t VALUES (1)")
  assert(result.code == 19 and result.extended_code == 2067, "UNIQUE keeps its extended constraint code")
  local reason = result.reason
  assert(reason:find("UNIQUE constraint failed", 1, true))
  local success = handle:exec_result("PRAGMA busy_timeout = 0")
  assert(success.code == Sqlite.OK and success.extended_code == Sqlite.OK and success.reason == "")
  assert(handle:close())
  assert(result.code == 19 and result.extended_code == 2067 and result.reason == reason)
end

local function test_exec_result_distinguishes_a_same_connection_lock()
  local handle = memory()
  assert(handle:exec("CREATE TABLE t (x); INSERT INTO t VALUES (1), (2)"))
  local statement = prepared(handle, "SELECT * FROM t")
  assert(statement:step() == "row")
  local locked = handle:exec_result("DROP TABLE t")
  assert(locked.cancelled == false)
  assert(locked.code == 6 and locked.extended_code == 6, "SQLITE_LOCKED is not SQLITE_BUSY")
  assert(locked.code ~= Sqlite.BUSY and locked.reason ~= "")
  statement:finalize()
  assert(handle:exec_result("DROP TABLE t").code == Sqlite.OK)
  assert(locked.code == 6 and locked.reason ~= "", "finalizing changed the snapshot")
  assert(handle:close())
end

local function test_exec_result_does_not_retry_or_rollback_a_partial_batch()
  local handle = memory()
  assert(handle:exec("CREATE TABLE t (x)"))
  local result = handle:exec_result("INSERT INTO t VALUES (1); SELECT * FROM missing; INSERT INTO t VALUES (2)")
  assert(result.code == 1 and result.reason:find("missing", 1, true))
  local rows = assert(Sqlite.text_rows(handle, "SELECT x FROM t"))
  assert(#rows == 1 and rows[1][1] == "1")
  local ok, reason = handle:exec("SELECT * FROM missing")
  assert(not ok and reason == result.reason, "legacy failure wording changed")
  assert(handle:close())
end

local function test_exec_result_refuses_nul_and_a_closed_handle()
  local handle = memory()
  local ok, reason = handle:exec("SELECT 1\0; SELECT 2")
  assert(not ok and reason == "SQL contains an embedded NUL byte")
  raises_saying("sqlite: SQL contains an embedded NUL byte", handle.exec_result, handle, "SELECT 1\0; SELECT 2")
  assert(handle:close())
  raises_saying("sqlite: the database handle is closed", handle.exec_result, handle, "SELECT 1")
end

local function test_exec_result_reports_readonly_and_malformed_databases(tmp: string)
  local path = tmp .. "/db"
  local created = assert(Sqlite.open(path, { writable = true }))
  assert(created:exec("CREATE TABLE t (x)"))
  assert(created:close())
  local readonly = assert(Sqlite.open(path))
  local denied = readonly:exec_result("INSERT INTO t VALUES (1)")
  assert(denied.code == 8 and denied.reason ~= "", "SQLITE_READONLY was not retained")
  assert(readonly:close())
  assert(Fs.write(tmp .. "/bad", string.rep("not a database", 32)))
  local bad = assert(Sqlite.open(tmp .. "/bad"))
  local malformed = bad:exec_result("SELECT * FROM sqlite_schema")
  assert(malformed.code == 26 and malformed.reason ~= "", "SQLITE_NOTADB was not retained")
  assert(bad:close())
end

local function test_busy_timeout_checks_its_duration_and_handle()
  local handle = memory()
  raises_saying("must be nonnegative", handle.busy_timeout, handle, -1)
  raises(handle.busy_timeout, handle, 0.5)
  raises(handle.busy_timeout, handle, math.huge)
  handle:busy_timeout(math.maxinteger)
  local result = handle:exec_result("SELECT 1")
  assert(result.code == Sqlite.OK and result.cancelled == false)
  handle:busy_timeout(0)
  assert(handle:close())
  raises_saying("database handle is closed", handle.busy_timeout, handle, 0)
end
