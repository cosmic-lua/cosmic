--- Captured outcomes remain about their operation, even after cleanup.
local Fs = require("cosmic.fs")
local Sqlite = require("cosmic.sqlite")

local function test_open_and_prepare_outcomes_outlive_cleanup(tmp: string)
  local missing = Sqlite.open_result(tmp .. "/absent", { writable = true, create = false })
  assert(missing.handle == nil and missing.code == 14 and missing.extended_code == 14)
  assert(missing.reason ~= "" and not missing.cancelled and Fs.stat(tmp .. "/absent") == nil)
  local opened = Sqlite.open_result(":memory:", { writable = true })
  assert(opened.code == Sqlite.OK and opened.reason == "" and not opened.cancelled)
  local db = assert(opened.handle)
  local failed = db:prepare_result("SELECT 1; SELECT * FROM missing")
  assert(failed.statement == nil and failed.code == 1 and failed.reason ~= "")
  local reason = failed.reason
  local prepared = db:prepare_result("SELECT 2")
  assert(prepared.code == Sqlite.OK and prepared.reason == "")
  prepared.statement:finalize()
  assert(db:close(), "tail failure retained the first statement")
  assert(failed.code == 1 and failed.reason == reason and missing.code == 14)
end

local function test_bound_values_keep_kinds_and_invalid_lists_release_the_statement()
  local db = assert(Sqlite.memory())
  local result = Sqlite.rows_result(db, "SELECT ?1, ?2, ?3, ?4, ?5", {
    { integer = 42 }, { number = 1.5 }, { text = "a\0b" }, { blob = "a\0b" }, {},
  })
  assert(result.code == Sqlite.OK and result.extended_code == Sqlite.OK and result.reason == "")
  local row = result.rows[1]
  assert(row[1].integer == 42 and row[2].number == 1.5 and row[3].text == "a\0b")
  assert(row[4].blob == "a\0b" and row[5].kind == "null")
  local invalid: {any} = {
    false, 42, {}, { {}, {} }, { [0] = {} }, { { text = "a", blob = "b" } },
    { { ["text\0junk"] = "bad" } }, { { integer = 1.5 } }, { { text = false } },
  }
  for _, values in ipairs(invalid) do
    local ok, _ = pcall(Sqlite.rows_result, db, "SELECT ?1", values as {Sqlite.Value})
    assert(not ok, "invalid bound values were accepted")
  end
  local texts = Sqlite.text_rows_result(db, "SELECT ?1", { { integer = 42 } })
  assert(texts.code == Sqlite.OK and texts.rows[1][1] == "42")
  assert(db:close(), "invalid parameters retained a prepared statement")
end

local function test_steps_capture_extended_codes_across_reset_and_reuse()
  local db = assert(Sqlite.memory())
  assert(db:exec("CREATE TABLE t (n UNIQUE); INSERT INTO t VALUES (1)"))
  local statement = assert(db:prepare("INSERT INTO t VALUES (?1)"))
  assert(statement:bind_values_result({ { integer = 1 } }).code == Sqlite.OK)
  local failed = statement:step_result()
  assert(failed is Sqlite.ExecResult)
  assert(failed.code == 19 and failed.extended_code == 2067 and failed.reason ~= "")
  local reason = failed.reason
  local _, _ = statement:reset()
  assert(statement:bind_values_result({ { integer = 2 } }).code == Sqlite.OK)
  assert(statement:step_result() == "done")
  assert(statement:reset())
  assert(statement:bind_values_result({ { integer = 2 } }).code == Sqlite.OK)
  local again = statement:step_result()
  assert(again is Sqlite.ExecResult and again.code == 19 and again.extended_code == 2067)
  statement:finalize()
  assert(db:close())
  assert(failed.code == 19 and failed.extended_code == 2067 and failed.reason == reason)
end

local function test_failed_rows_discard_partial_data_without_misclassifying_json()
  local db = assert(Sqlite.memory())
  local sql = "WITH RECURSIVE c(n) AS (SELECT 1 UNION ALL SELECT n+1 FROM c WHERE n<3) " ..
    "SELECT CASE WHEN n<3 THEN n ELSE json('not json') END FROM c"
  local cells, texts = Sqlite.rows_result(db, sql), Sqlite.text_rows_result(db, sql)
  assert(cells.rows == nil and cells.code == 1 and cells.reason ~= "")
  assert(texts.rows == nil and texts.code == 1 and texts.reason ~= "")
  assert(Sqlite.run_result(db, "CREATE TABLE t (n)").code == Sqlite.OK)
  assert(Sqlite.run_result(db, "INSERT INTO t VALUES (?1)", { { integer = 3 } }).code == Sqlite.OK)
  assert(db:close())
end

local function test_corrupt_and_not_database_have_codes_independent_of_text(tmp: string)
  local path = tmp .. "/cache.db"
  local db = assert(Sqlite.open(path, { writable = true }))
  assert(db:exec("CREATE TABLE t (n)"))
  assert(db:close())
  local bytes = assert(Fs.read(path))
  assert(Fs.write(path, bytes:sub(1, 100) .. "\0" .. bytes:sub(102)))
  db = assert(Sqlite.open(path))
  local corrupt = Sqlite.rows_result(db, "SELECT * FROM sqlite_schema")
  assert(corrupt.rows == nil and corrupt.code == Sqlite.CORRUPT, corrupt.reason)
  assert(db:close())
  assert(Fs.write(path, "not a database"))
  db = assert(Sqlite.open(path))
  local foreign = Sqlite.text_rows_result(db, "SELECT * FROM sqlite_schema")
  assert(foreign.rows == nil and foreign.code == Sqlite.NOTADB, foreign.reason)
  assert(db:close())
end

local function test_busy_and_locked_are_distinct_and_no_operation_is_retried(tmp: string)
  local path = tmp .. "/db"
  local first = assert(Sqlite.open(path, { writable = true }))
  assert(first:exec("CREATE TABLE t (n); INSERT INTO t VALUES (1); BEGIN IMMEDIATE"))
  local second = assert(Sqlite.open(path, { writable = true }))
  second:busy_timeout(0)
  local busy = Sqlite.run_result(second, "INSERT INTO t VALUES (2)")
  assert(busy.code == Sqlite.BUSY and not busy.cancelled)
  assert(first:exec("ROLLBACK"))
  local rows = Sqlite.rows_result(first, "SELECT count(*) FROM t")
  assert(rows.rows[1][1].integer == 1)
  local reader = assert(first:prepare("SELECT * FROM t"))
  assert(reader:step_result() == "row")
  local locked = Sqlite.run_result(first, "DROP TABLE t")
  assert(locked.code == Sqlite.LOCKED and not locked.cancelled)
  reader:finalize()
  assert(first:close() and second:close())
end

local function test_binding_failure_captures_its_code_before_finalize()
  local db = assert(Sqlite.memory())
  local statement = assert(db:prepare("SELECT ?1"))
  local old = db:limit("length", 50)
  local result = statement:bind_values_result({ { text = string.rep("z", 100) } })
  assert(result.code == 18 and result.extended_code == 18 and result.reason ~= "")
  statement:finalize()
  db:limit("length", old)
  assert(db:exec("SELECT 1"))
  assert(result.code == 18 and result.reason ~= "")
  assert(db:close())
end

local function test_typed_sql_validation_keeps_existing_shapes_unchanged(tmp: string)
  local opened, why = Sqlite.open(tmp .. "/bad\0name", { writable = true })
  assert(opened == nil and why ~= "")
  local ok, _ = pcall(Sqlite.open_result, tmp .. "/bad\0name", { writable = true })
  assert(not ok)
  local db = assert(Sqlite.memory())
  for _, sql in ipairs({ "", "SELECT 1; SELECT 2", "SELECT 1\0" }) do
    local accepted, _ = pcall(db.prepare_result, db, sql)
    assert(not accepted)
  end
  local statement = assert(db:prepare("SELECT 1"))
  statement:finalize()
  local stepped, _ = pcall(statement.step_result, statement)
  local bound, _ = pcall(statement.bind_values_result, statement, {})
  assert(not stepped and not bound)
  assert(db:close())
  local prepared, _ = pcall(db.prepare_result, db, "SELECT 1")
  assert(not prepared)
end
