local Sqlite = require("cosmic.sqlite")

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
  assert(statement:finalize())

  statement = assert(db:prepare([[
    CREATE TRIGGER copy_value AFTER INSERT ON source BEGIN
      INSERT INTO log VALUES (new.value);
      UPDATE log SET value = value + 1;
    END;
    -- trailing comment
  ]]))
  assert(statement:finalize())
  assert(db:close())
end
