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

--- Values that do not match the statement's placeholders are refused,
--- and nothing runs.
local function test_mismatched_parameters_do_not_execute()
  local db = assert(Sqlite.memory())
  assert(db:exec("CREATE TABLE items (a, b)"))
  local mismatched: {{any, string}} = {
    { {}, "sqlite: parameter 1 has no value (use {} for NULL)" },
    { { { integer = 1 } }, "sqlite: parameter 2 has no value (use {} for NULL)" },
    { { {}, {}, {} }, "sqlite: values holds a parameter 3, and the statement has 2" },
    { { [2] = {} }, "sqlite: parameter 1 has no value (use {} for NULL)" },
  }
  for _, case in ipairs(mismatched) do
    local values = case[1] as {Sqlite.Value}
    local ok, why = Sqlite.run(db, "INSERT INTO items VALUES (?1, ?2)", values)
    assert(not ok and why == case[2], tostring(why))
    local rows, failure = Sqlite.text_rows(db, "SELECT ?1, ?2", values)
    assert(rows == nil and failure == case[2], tostring(failure))
  end
  local rows = assert(Sqlite.text_rows(db, "SELECT count(*) FROM items"))
  assert(rows[1][1] == "0")
  assert(db:close())
end

--- A Value of no valid shape, or a key that is no position, is a
--- mistake in the call, so it raises, naming the caller, and nothing runs.
local function test_malformed_values_raise_and_do_not_execute()
  local db = assert(Sqlite.memory())
  assert(db:exec("CREATE TABLE items (a, b)"))
  local malformed: {{any, string}} = {
    { { 1, {} }, "parameter 1 is no Value table" },
    { { { integer = 1, text = "one" }, {} }, "parameter 1 has more than one Value field" },
    { { { typo = "one" }, {} }, "parameter 1 has an unknown Value field: typo" },
    { { {}, {}, typo = {} }, "values holds the key typo" },
    { { {}, {}, [0] = {} }, "values holds the key 0" },
  }
  for _, case in ipairs(malformed) do
    local values = case[1] as {Sqlite.Value}
    local calls: {function()} = {
      function() local _, _ = Sqlite.run(db, "INSERT INTO items VALUES (?1, ?2)", values) end,
      function() local _, _ = Sqlite.rows(db, "SELECT ?1, ?2", values) end,
      function() local _, _ = Sqlite.text_rows(db, "SELECT ?1, ?2", values) end,
      function() local _, _ = Sqlite.query(db, "SELECT ?1, ?2", values) end,
    }
    for _, call in ipairs(calls) do
      local ok, why: boolean, any = pcall(call)
      assert(not ok and tostring(why):find("sqlite: " .. case[2], 1, true) ~= nil,
        case[2] .. ": " .. tostring(why))
      assert(tostring(why):find("sqlite_parameter_test", 1, true) ~= nil,
        "blames the caller: " .. tostring(why))
    end
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
