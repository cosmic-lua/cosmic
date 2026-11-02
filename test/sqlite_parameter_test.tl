local Sqlite = require("cosmic.sqlite")

--- The first of `rows`, which the statement is known to yield.
local function first_row(rows: Sqlite.Rows): Sqlite.Row
  local found = rows[1]
  assert(found, "the statement yields a row")
  return found
end

local function test_rows_preserve_sqlite_values()
  local db = assert(Sqlite.memory())
  local rows = assert(Sqlite.rows(db,
    "SELECT NULL, '', CAST('' AS BLOB), 9007199254740993, 1.25, " ..
      "CAST(x'610062' AS TEXT), x'610062'"))
  local row = first_row(rows)
  assert(row:count() == 7)
  assert(row:kind(1) == "null")
  assert(row:kind(2) == "text" and row:text(2) == "")
  assert(row:kind(3) == "blob" and row:blob(3) == "")
  assert(row:kind(4) == "integer" and row:integer(4) == 9007199254740993)
  assert(row:kind(5) == "number" and row:number(5) == 1.25)
  assert(row:kind(6) == "text" and row:text(6) == "a\0b")
  assert(row:kind(7) == "blob" and row:blob(7) == "a\0b")
  assert(db:close())
end

--- Values that do not match the statement's placeholders are refused,
--- and nothing runs.
local function test_mismatched_parameters_do_not_execute()
  local db = assert(Sqlite.memory())
  assert(db:exec("CREATE TABLE items (a, b)"))
  local record Case
    values: {Sqlite.Value}
    says: string
  end
  local mismatched: {Case} = {
    { values = {}, says = "sqlite: parameter 1 has no value (use {} for NULL)" },
    { values = { { integer = 1 } }, says = "sqlite: parameter 2 has no value (use {} for NULL)" },
    { values = { {}, {}, {} }, says = "sqlite: values holds a parameter 3, and the statement has 2" },
  }
  for _, case in ipairs(mismatched) do
    local values = case.values
    local ok, why = Sqlite.run(db, "INSERT INTO items VALUES (?1, ?2)", values)
    assert(not ok and why == case.says, tostring(why))
    local rows, failure = Sqlite.text_rows(db, "SELECT ?1, ?2", values)
    assert(rows == nil and failure == case.says, tostring(failure))
  end
  -- A list with a gap is no literal of a list type, so it is built untyped.
  local gap: any = { [2] = {} }
  local gapped = gap as {Sqlite.Value}
  local gap_ok, gap_why = Sqlite.run(db, "INSERT INTO items VALUES (?1, ?2)", gapped)
  assert(not gap_ok and gap_why == "sqlite: parameter 1 has no value (use {} for NULL)", tostring(gap_why))
  local gap_rows, gap_failure = Sqlite.text_rows(db, "SELECT ?1, ?2", gapped)
  assert(gap_rows == nil and gap_failure == gap_why, tostring(gap_failure))
  local rows = assert(Sqlite.text_rows(db, "SELECT count(*) FROM items"))
  assert(first_row(rows):text(1) == "0")
  assert(db:close())
end

--- A Value of no valid shape, or a key that is no position, is a
--- mistake in the call, so it raises, naming the caller, and nothing runs.
local function test_malformed_values_raise_and_do_not_execute()
  local db = assert(Sqlite.memory())
  assert(db:exec("CREATE TABLE items (a, b)"))
  local record Case
    values: any
    says: string
  end
  local malformed: {Case} = {
    { values = { 1, {} }, says = "parameter 1 is no Value table" },
    { values = { { integer = 1, text = "one" }, {} }, says = "parameter 1 has more than one Value field" },
    { values = { { typo = "one" }, {} }, says = "parameter 1 has an unknown Value field: typo" },
    { values = { { null = true } }, says = "parameter 1 has an unknown Value field: null (use {} for NULL)" },
    { values = { {}, {}, typo = {} }, says = "values holds the key typo" },
    { values = { {}, {}, [0] = {} }, says = "values holds the key 0" },
    { values = { { integers = { 1, 2.5 } }, {} }, says = "element 2 of parameter 1's integers is not of its type" },
    { values = { { texts = { "a\0b" } }, {} }, says = "element 1 of parameter 1's texts holds a NUL" },
  }
  for _, case in ipairs(malformed) do
    local values = case.values as {Sqlite.Value}
    local calls: {function()} = {
      function() local _, _ = Sqlite.run(db, "INSERT INTO items VALUES (?1, ?2)", values) end,
      function() local _, _ = Sqlite.rows(db, "SELECT ?1, ?2", values) end,
      function() local _, _ = Sqlite.text_rows(db, "SELECT ?1, ?2", values) end,
      function() local _, _ = Sqlite.query(db, "SELECT ?1, ?2", values) end,
    }
    for _, call in ipairs(calls) do
      local ok, why: boolean, any = pcall(call)
      assert(not ok and tostring(why):find("sqlite: " .. case.says, 1, true) ~= nil,
        case.says .. ": " .. tostring(why))
      assert(tostring(why):find("sqlite_parameter_test", 1, true) ~= nil,
        "blames the caller: " .. tostring(why))
    end
  end
  local rows = assert(Sqlite.text_rows(db, "SELECT count(*) FROM items"))
  assert(first_row(rows):text(1) == "0")
  assert(db:close())
end

local function test_complete_parameters_and_explicit_null()
  local db = assert(Sqlite.memory())
  assert(db:exec("CREATE TABLE items (a, b)"))
  assert(Sqlite.run(db, "INSERT INTO items VALUES (?, ?)", { { integer = 7 }, {} }))
  local rows = assert(Sqlite.text_rows(db, "SELECT a, b IS NULL FROM items"))
  assert(first_row(rows):text(1) == "7" and first_row(rows):text(2) == "1")
  rows = assert(Sqlite.text_rows(db, "SELECT :value, :value, ?3", { { text = "twice" }, {}, { blob = "bytes" } }))
  assert(first_row(rows):text(1) == "twice" and first_row(rows):text(2) == "twice" and first_row(rows):text(3) == "bytes")
  rows = assert(Sqlite.text_rows(db, "SELECT :value, :value", { { number = 1.5 } }))
  assert(first_row(rows):text(1) == "1.5" and first_row(rows):text(2) == "1.5")
  assert(Sqlite.text_rows(db, "SELECT ?3", { { integer = 3 } }) == nil)
  assert(Sqlite.text_rows(db, "SELECT 1", { {} }) == nil)
  assert(db:close())
end

--- A list binds as an array that carray() reads as a table of its
--- elements, and that reads as NULL anywhere else.
local function test_lists_bind_as_arrays_for_carray()
  local db = assert(Sqlite.memory())
  local record Case
    value: Sqlite.Value
    text: string
  end
  local cases: {Case} = {
    { value = { integers = { 1, -2, 9007199254740993 } }, text = "1 -2 9007199254740993" },
    { value = { numbers = { 1.5, 2 } }, text = "1.5 2.0" },
    { value = { texts = { "a", "ü", "" } }, text = "a ü " },
    { value = { blobs = { "a\0b", "" } }, text = "a\0b " },
    { value = { integers = {} }, text = "" },
  }
  for _, case in ipairs(cases) do
    local rows = assert(Sqlite.text_rows(db, "SELECT value FROM carray(?1)", { case.value }))
    local got: mut {string} = {}
    for _, row in ipairs(rows) do got[#got + 1] = row:text(1) end
    assert(table.concat(got, " ") == case.text, table.concat(got, " "))
  end
  local rows = assert(Sqlite.text_rows(db, "SELECT 2 IN carray(?1), 5 IN carray(?1), quote(?1)",
    { { integers = { 1, 2, 3 } } }))
  assert(table.concat(first_row(rows):texts(), " ") == "1 0 NULL", table.concat(first_row(rows):texts(), " "))
  local result = Sqlite.text_rows_result(db, "SELECT value FROM carray(?1)", { { texts = { "x", "y" } } })
  local result_rows = result.rows
  assert(result.code == Sqlite.OK and result_rows ~= nil and #result_rows == 2, result.reason)
  local ok, why: boolean, any = pcall(Sqlite.text_rows_result, db, "SELECT value FROM carray(?1)",
    { { texts = { "x\0" } } })
  assert(not ok and tostring(why):find("holds a NUL", 1, true) ~= nil, tostring(why))
  assert(db:close())
end

--- carray() reads no array but one a Value binds: a pointer that SQL
--- names, with a count and a type, reads as no rows.
local function test_carray_reads_no_array_sql_names()
  local db = assert(Sqlite.memory())
  local values: {Sqlite.Value} = { { integer = 4096 }, { integers = { 1 } } }
  for _, value in ipairs(values) do
    local rows = assert(Sqlite.text_rows(db, "SELECT count(*) FROM carray(?1, 3, 'int64')", { value }))
    assert(first_row(rows):text(1) == "0", first_row(rows):text(1))
  end
  assert(db:close())
end
