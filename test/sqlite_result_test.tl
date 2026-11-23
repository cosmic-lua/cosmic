--- SQLite's codes stay on a failure, after the statement and the handle are gone.
local Fs = require("cosmic.fs")
local Sqlite = require("cosmic.sqlite")
local Test = require("cosmic.test")

--- The first of `rows`, which the statement is known to yield.
local function first_row(rows: Sqlite.Rows): Sqlite.Row
  local found = rows[1]
  assert(found, "the statement yields a row")
  return found
end

local function test_open_and_prepare_outcomes_outlive_cleanup(tmp: string)
  local absent, missing = Sqlite.open(tmp .. "/absent", { writable = true, create = false })
  assert(absent == nil and missing.code == 14 and missing.extended_code == 14)
  assert(missing.message ~= "" and missing.cancelled ~= true and not assert(Fs.status(tmp .. "/absent")).exists)
  local db = assert(Sqlite.open(":memory:", { writable = true }))
  local failed = db:prepare_result("SELECT 1; SELECT * FROM missing")
  assert(failed.statement == nil and failed.code == 1 and failed.reason ~= "") -- checked: compare_disjoint
  local reason = failed.reason
  local prepared = db:prepare_result("SELECT 2")
  assert(prepared.code == Sqlite.OK and prepared.reason == "")
  prepared.statement:finalize()
  assert(db:close(), "tail failure retained the first statement")
  assert(failed.code == 1 and failed.reason == reason and missing.code == 14)
end

local function test_bound_values_keep_kinds_and_invalid_lists_release_the_statement()
  local db = assert(Sqlite.memory())
  local rows = assert(Sqlite.rows(db, "SELECT ?1, ?2, ?3, ?4, ?5", {
    { integer = 42 }, { number = 1.5 }, { text = "a\0b" }, { blob = "a\0b" }, {},
  }))
  local row = first_row(rows)
  assert(row:integer(1) == 42 and row:number(2) == 1.5 and row:text(3) == "a\0b")
  assert(row:blob(4) == "a\0b" and row:kind(5) == "null")
  -- A position with no value, and one past the statement's, are refused
  -- as SQLite's RANGE; a value of two fields raises.
  local unbound: {{Sqlite.Value}} = { {}, { {}, {} } }
  for _, values in ipairs(unbound) do
    local none, why = Sqlite.rows(db, "SELECT ?1", values)
    assert(none == nil and why.code == Sqlite.RANGE, tostring(why))
  end
  Test.raises(function()
    local _, _ = Sqlite.rows(db, "SELECT ?1", { { text = "a", blob = "b" } })
  end)
  local texts = assert(Sqlite.text_rows(db, "SELECT ?1", { { integer = 42 } }))
  assert(first_row(texts):text(1) == "42")
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
  local cells, cells_why = Sqlite.rows(db, sql)
  assert(cells == nil and cells_why.code == 1 and cells_why.message ~= "")
  local texts, texts_why = Sqlite.text_rows(db, sql)
  assert(texts == nil and texts_why.code == 1 and texts_why.message ~= "")
  assert(Sqlite.run(db, "CREATE TABLE t (n)"))
  assert(Sqlite.run(db, "INSERT INTO t VALUES (?1)", { { integer = 3 } }))
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
  local schema, corrupt = Sqlite.rows(db, "SELECT * FROM sqlite_schema")
  assert(schema == nil and corrupt.code == Sqlite.CORRUPT, tostring(corrupt))
  assert(db:close())
  assert(Fs.write(path, "not a database"))
  db = assert(Sqlite.open(path))
  local read, foreign = Sqlite.text_rows(db, "SELECT * FROM sqlite_schema")
  assert(read == nil and foreign.code == Sqlite.NOTADB, tostring(foreign))
  assert(db:close())
end

local function test_busy_and_locked_are_distinct_and_no_operation_is_retried(tmp: string)
  local path = tmp .. "/db"
  local first = assert(Sqlite.open(path, { writable = true }))
  assert(first:exec("CREATE TABLE t (n); INSERT INTO t VALUES (1); BEGIN IMMEDIATE"))
  local second = assert(Sqlite.open(path, { writable = true }))
  second:busy_timeout(0)
  local inserted, busy = Sqlite.run(second, "INSERT INTO t VALUES (2)")
  assert(not inserted and busy.code == Sqlite.BUSY and busy.cancelled ~= true)
  assert(first:exec("ROLLBACK"))
  local rows = assert(Sqlite.rows(first, "SELECT count(*) FROM t"))
  assert(first_row(rows):integer(1) == 1)
  local reader = assert(first:prepare("SELECT * FROM t"))
  assert(reader:step_result() == "row")
  local dropped, locked = Sqlite.run(first, "DROP TABLE t")
  assert(not dropped and locked.code == Sqlite.LOCKED and locked.cancelled ~= true)
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
  assert(opened == nil and why.code == Sqlite.MISUSE and why.message:find("NUL", 1, true) ~= nil, tostring(why))
  local db = assert(Sqlite.memory())
  for _, sql in ipairs({ "", "SELECT 1; SELECT 2", "SELECT 1\0" }) do
    local none, refused = Sqlite.rows(db, sql)
    assert(none == nil and refused.code == Sqlite.MISUSE and refused.message ~= "", sql)
  end
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
