local Sqlite = require("cosmic.sqlite")

local function test_native_fallible_calls_return_result_pairs()
  local missing, open_why = Sqlite.open("/cosmic-missing/result-pairs.db")
  assert(missing == nil and open_why ~= "")

  local db, memory_why = Sqlite.memory()
  assert(db ~= nil and memory_why == "")
  local executed, exec_why = db:exec("CREATE TABLE items (value)")
  assert(executed and exec_why == "")
  local not_executed, bad_exec_why = db:exec("not SQL")
  assert(not not_executed and bad_exec_why ~= "")

  local statement, prepare_why = db:prepare("SELECT ?1")
  assert(statement ~= nil and prepare_why == "")
  local bound, bind_why = statement:bind_integer(1, 7)
  assert(bound and bind_why == "")
  local not_bound, bad_bind_why = statement:bind_null(2)
  assert(not not_bound and bad_bind_why ~= "")
  local state, step_why = statement:step()
  assert(state == "row" and step_why == "")
  state, step_why = statement:step()
  assert(state == "done" and step_why == "")
  local reset, reset_why = statement:reset()
  assert(reset and reset_why == "")

  local not_closed, busy_why = db:close()
  assert(not not_closed and busy_why ~= "")
  statement:finalize()
  local closed, close_why = db:close()
  assert(closed and close_why == "")
  closed, close_why = db:close()
  assert(closed and close_why == "")

  local failing_db = assert(Sqlite.memory())
  local failing_statement = assert(failing_db:prepare(
    "SELECT abs(-9223372036854775808)"))
  local failed_state, failed_step_why = failing_statement:step()
  assert(failed_state == nil and failed_step_why ~= "")
  local failed_reset, failed_reset_why = failing_statement:reset()
  assert(not failed_reset and failed_reset_why ~= "")
  failing_statement:finalize()
  assert(failing_db:close())
end

local function test_prepare_rejects_sql_without_a_statement()
  local db = assert(Sqlite.memory())
  for _, sql in ipairs({ "", " \t\r\n", "-- only a comment\n", "/* only a comment */" }) do
    local statement, why = db:prepare(sql)
    assert(statement == nil)
    assert(why == "SQL contains no statement")
  end
  assert(db:close())
end

local function test_one_statement_helpers_reject_additional_sql()
  local db = assert(Sqlite.memory())
  local statement, prepare_why = db:prepare("SELECT 1; SELECT 2")
  assert(statement == nil and prepare_why:find("more than one statement", 1, true))

  local ran, run_why = Sqlite.run(db, "SELECT 1; SELECT 2")
  assert(not ran and run_why:find("more than one statement", 1, true))
  local rows, rows_why = Sqlite.text_rows(db, "SELECT 1; SELECT 2")
  assert(rows == nil and rows_why:find("more than one statement", 1, true))

  local nul_statement, nul_why = db:prepare("SELECT 1\0; SELECT 2")
  assert(nul_statement == nil and nul_why:find("NUL", 1, true))
  assert(db:close())
end

local function test_sqlite_parses_the_statement_tail()
  local db = assert(Sqlite.memory())
  assert(db:exec("CREATE TABLE source (value); CREATE TABLE log (value)"))

  local statement = assert(db:prepare("SELECT ';' /* ; */; -- trailing ;\n /* comment */"))
  statement:finalize()

  statement = assert(db:prepare([[
    CREATE TRIGGER copy_value AFTER INSERT ON source BEGIN
      INSERT INTO log VALUES (new.value);
      UPDATE log SET value = value + 1;
    END;
    -- trailing comment
  ]]))
  statement:finalize()
  assert(db:close())
end
