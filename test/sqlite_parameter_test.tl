local Sqlite = require("cosmic.sqlite")

local function test_rows_preserve_sqlite_values()
  local db = assert(Sqlite.memory())
  local rows = assert(Sqlite.rows(db,
    "SELECT NULL, '', CAST('' AS BLOB), 9007199254740993, 1.25, " ..
    "CAST(x'610062' AS TEXT), x'610062'"))
  local row = rows[1]
  assert(#row == 7)
  assert(row[1].kind == "null")
  assert(row[2].kind == "text" and row[2].text == "")
  assert(row[3].kind == "blob" and row[3].blob == "")
  assert(row[4].kind == "integer" and row[4].integer == 9007199254740993)
  assert(row[5].kind == "number" and row[5].number == 1.25)
  assert(row[6].kind == "text" and row[6].text == "a\0b")
  assert(row[7].kind == "blob" and row[7].blob == "a\0b")
  assert(db:close())
end

local function test_invalid_parameters_do_not_execute()
  local db = assert(Sqlite.memory())
  assert(db:exec("CREATE TABLE items (a, b)"))
  local invalid: {any} = {
    {},
    { { integer = 1 } },
    { {}, {}, {} },
    { [2] = {} },
    { [1] = {}, [2] = {}, typo = {} },
    { { integer = 1, text = "one" }, {} },
    { { typo = "one" }, {} },
  }
  for _, values in ipairs(invalid) do
    local ok, why = Sqlite.run(db, "INSERT INTO items VALUES (?1, ?2)", values as {Sqlite.Value})
    assert(not ok and why:find("parameter", 1, true) ~= nil)
    local rows, failure = Sqlite.text_rows(db, "SELECT ?1, ?2", values as {Sqlite.Value})
    assert(rows == nil and failure:find("parameter", 1, true) ~= nil)
  end
  local rows = assert(Sqlite.text_rows(db, "SELECT count(*) FROM items"))
  assert(rows[1][1] == "0")
  assert(db:close())
end

local function test_complete_parameters_and_explicit_null()
  local db = assert(Sqlite.memory())
  assert(db:exec("CREATE TABLE items (a, b)"))
  assert(Sqlite.run(db, "INSERT INTO items VALUES (?, ?)", { { integer = 7 }, {} }))
  local rows = assert(Sqlite.text_rows(db, "SELECT a, b IS NULL FROM items"))
  assert(rows[1][1] == "7" and rows[1][2] == "1")
  rows = assert(Sqlite.text_rows(db, "SELECT :value, :value, ?3", { { text = "twice" }, {}, { blob = "bytes" } }))
  assert(rows[1][1] == "twice" and rows[1][2] == "twice" and rows[1][3] == "bytes")
  rows = assert(Sqlite.text_rows(db, "SELECT :value, :value", { { number = 1.5 } }))
  assert(rows[1][1] == "1.5" and rows[1][2] == "1.5")
  assert(Sqlite.text_rows(db, "SELECT ?3", { { integer = 3 } }) == nil)
  assert(Sqlite.text_rows(db, "SELECT 1", { {} }) == nil)
  assert(db:close())
end
