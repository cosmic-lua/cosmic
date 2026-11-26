local Sqlite = require("cosmic.sqlite")

--- The first of `rows`, which the statement is known to yield.
local function first_row(rows: Sqlite.Rows): Sqlite.Row
  local found = rows[1]
  assert(found, "the statement yields a row")
  return found
end

local function test_rows_preserve_sqlite_values()
  local db = assert(Sqlite.memory())
  local rows = assert(db:rows(
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
    { values = {}, says = "sqlite: parameter 1 has no value (Sqlite.NULL binds NULL)" },
    { values = { { integer = 1 } }, says = "sqlite: parameter 2 has no value (Sqlite.NULL binds NULL)" },
    { values = { {}, {}, {} }, says = "sqlite: values holds a parameter 3, and the statement has 2" },
  }
  for _, case in ipairs(mismatched) do
    local values = case.values
    local ok, why = db:run("INSERT INTO items VALUES (?1, ?2)", values)
    assert(not ok and why.message == case.says and why.code == Sqlite.RANGE, tostring(why))
    local rows, failure = db:rows("SELECT ?1, ?2", values)
    assert(rows == nil and failure.message == case.says and failure.code == Sqlite.RANGE, tostring(failure))
  end
  local rows = assert(db:rows("SELECT count(*) FROM items"))
  assert(first_row(rows):integer(1) == 0)
  assert(db:close())
end

--- A Value of more than one field, or a text that holds a NUL, is a
--- mistake in the call, so it raises, naming the caller, and nothing runs.
local function test_malformed_values_raise_and_do_not_execute()
  local db = assert(Sqlite.memory())
  assert(db:exec("CREATE TABLE items (a, b)"))
  local record Case
    values: {Sqlite.Value}
    says: string
  end
  local malformed: {Case} = {
    { values = { { integer = 1, text = "one" }, {} }, says = "parameter 1: a Value has at most one named field" },
    { values = { { texts = { "a\0b" } }, {} }, says = "parameter 1: element 1 of a texts Value holds a NUL" },
  }
  for _, case in ipairs(malformed) do
    local values = case.values
    local calls: {function()} = {
      function() local _, _ = db:run("INSERT INTO items VALUES (?1, ?2)", values) end,
      function() local _, _ = db:rows("SELECT ?1, ?2", values) end,
      function() local _, _ = db:rows("SELECT ?1, ?2", values) end,
      function() local _, _ = db:query("SELECT ?1, ?2", values) end,
    }
    for _, call in ipairs(calls) do
      local ok, why: boolean, any = pcall(call)
      assert(not ok and tostring(why):find("sqlite: " .. case.says, 1, true) ~= nil,
        case.says .. ": " .. tostring(why))
      assert(tostring(why):find("sqlite_parameter_test", 1, true) ~= nil,
        "blames the caller: " .. tostring(why))
    end
  end
  local rows = assert(db:rows("SELECT count(*) FROM items"))
  assert(first_row(rows):integer(1) == 0)
  assert(db:close())
end

local function test_complete_parameters_and_explicit_null()
  local db = assert(Sqlite.memory())
  assert(db:exec("CREATE TABLE items (a, b)"))
  assert(db:run("INSERT INTO items VALUES (?, ?)", { { integer = 7 }, {} }))
  local rows = assert(db:rows("SELECT a, b IS NULL FROM items"))
  assert(first_row(rows):integer(1) == 7 and first_row(rows):integer(2) == 1)
  rows = assert(db:rows("SELECT :value, :value, ?3", { { text = "twice" }, {}, { blob = "bytes" } }))
  assert(first_row(rows):text(1) == "twice" and first_row(rows):text(2) == "twice" and first_row(rows):blob(3) == "bytes")
  rows = assert(db:rows("SELECT :value, :value", { { number = 1.5 } }))
  assert(first_row(rows):number(1) == 1.5 and first_row(rows):number(2) == 1.5)
  local past, _ = db:rows("SELECT ?3", { { integer = 3 } })
  assert(past == nil)
  local extra, _ = db:rows("SELECT 1", { {} })
  assert(extra == nil)
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
    local rows = assert(db:rows("SELECT value FROM carray(?1)", { case.value }))
    local got: mut {string} = {}
    for _, row in ipairs(rows) do got[#got + 1] = (row:as_text(1) or "") end
    assert(table.concat(got, " ") == case.text, table.concat(got, " "))
  end
  local rows = assert(db:rows("SELECT 2 IN carray(?1), 5 IN carray(?1), quote(?1)",
    { { integers = { 1, 2, 3 } } }))
  assert(table.concat(first_row(rows):as_texts(), " ") == "1 0 NULL", table.concat(first_row(rows):as_texts(), " "))
  local listed = assert(db:rows("SELECT value FROM carray(?1)", { { texts = { "x", "y" } } }))
  assert(#listed == 2)
  local ok, why: boolean, any = pcall(function()
    local _, _ = db:rows("SELECT value FROM carray(?1)", { { texts = { "x\0" } } })
  end)
  assert(not ok and tostring(why):find("holds a NUL", 1, true) ~= nil, tostring(why))
  assert(db:close())
end

--- carray() reads no array but one a Value binds: a pointer that SQL
--- names, with a count and a type, reads as no rows.
local function test_carray_reads_no_array_sql_names()
  local db = assert(Sqlite.memory())
  local values: {Sqlite.Value} = { { integer = 4096 }, { integers = { 1 } } }
  for _, value in ipairs(values) do
    local rows = assert(db:rows("SELECT count(*) FROM carray(?1, 3, 'int64')", { value }))
    assert(first_row(rows):integer(1) == 0, tostring(first_row(rows):integer(1)))
  end
  assert(db:close())
end

--- A plain value binds by its own type: an integer as an integer, a
--- float as a real, a string as text and a boolean as 1 or 0.
--- [`Sqlite.blob`] binds bytes as a blob and [`Sqlite.NULL`] binds NULL.
local function test_plain_values_bind_by_their_type()
  local db = assert(Sqlite.memory())
  local rows = assert(db:rows(
    "SELECT typeof(?1), ?1, typeof(?2), ?2, typeof(?3), ?3, typeof(?4), ?4, ?5, typeof(?6), ?6, ?7 IS NULL",
    { 9007199254740993, 1.25, "a\0b", true, false, Sqlite.blob("a\0b"), Sqlite.NULL }))
  local row = first_row(rows)
  assert(row:text(1) == "integer" and row:integer(2) == 9007199254740993)
  assert(row:text(3) == "real" and row:number(4) == 1.25)
  assert(row:text(5) == "text" and row:text(6) == "a\0b")
  assert(row:text(7) == "integer" and row:integer(8) == 1 and row:integer(9) == 0)
  assert(row:text(10) == "blob" and row:blob(11) == "a\0b")
  assert(row:integer(12) == 1)
  -- A plain string and a tagged one bind alike; a blob of the same bytes differs.
  rows = assert(db:rows("SELECT ?1 = ?2, ?1 = ?3", { "x", { text = "x" }, Sqlite.blob("x") }))
  assert(first_row(rows):integer(1) == 1 and first_row(rows):integer(2) == 0)
  assert(db:close())
end

--- With a gap in the list, or a position past the last parameter, the
--- call fails and says why (RANGE); a value of no shape a parameter
--- takes, or a key that is no position, raises at the caller. Either
--- way the statement is released, so the handle still closes and the
--- same SQL runs again.
local function test_plain_values_refused_release_the_statement()
  local db = assert(Sqlite.memory())
  local sql = "SELECT ?1, ?2"
  local rows, why = db:rows(sql, { 1, 2, 3 })
  assert(rows == nil and why.code == Sqlite.RANGE, tostring(why))
  -- Made in a chunk of its own, since no type the checker accepts holds
  -- these values; each call there is a line of the chunk "probe".
  local probe = assert(load([[
    local db, sql = ...
    local gap_rows, gap_why = db:rows(sql, { 1, nil, 3 })
    local called, raised = pcall(function() local r = db:rows(sql, { 1, print }); return r end)
    local keyed, named = pcall(function() local r = db:rows(sql, { 1, 2, name = "x" }); return r end)
    return gap_rows == nil and gap_why.code, called, tostring(raised), keyed, tostring(named)
  ]], "=probe"))
  local gap_code, called, raised, keyed, named = probe(db, sql)
  assert(gap_code == Sqlite.RANGE, tostring(gap_code))
  assert(called == false and tostring(raised):find("^probe:3: sqlite: parameter 2 is a function") ~= nil, tostring(raised))
  assert(keyed == false and tostring(named):find("^probe:4: sqlite: values holds a key") ~= nil, tostring(named))
  rows = assert(db:rows(sql, { 1, 2 }))
  assert(first_row(rows):integer(2) == 2)
  assert(db:close())
end

--- A cached statement whose binding failed part way is released with its
--- bindings cleared, so the same SQL runs again with what it is given.
local function test_a_statement_refused_part_way_runs_again_clean()
  local db = assert(Sqlite.memory())
  local sql = "SELECT ?1, ?2 IS NULL"
  local gap: {Sqlite.Param} = { 7 }
  local rows, why = db:rows(sql, gap)
  assert(rows == nil and why.code == Sqlite.RANGE, tostring(why))
  rows = assert(db:rows(sql, { 8, Sqlite.NULL }))
  assert(first_row(rows):integer(1) == 8 and first_row(rows):integer(2) == 1)
  assert(db:close())
end

--- A list binds through `run` as an array that carray() reads, and a
--- float that holds a whole number binds as a real.
local function test_lists_and_whole_floats_bind_as_given()
  local db = assert(Sqlite.memory())
  assert(db:exec("CREATE TABLE t (n)"))
  assert(db:run("INSERT INTO t SELECT value FROM carray(?1)", { { integers = { 1, 2, 3 } } }))
  local rows = assert(db:rows("SELECT count(*), typeof(?1) FROM t", { 2.0 }))
  assert(first_row(rows):integer(1) == 3 and first_row(rows):text(2) == "real")
  assert(db:close())
end

--- A key that is no position raises whatever else the list holds, and
--- the highest position past the last parameter is the one named.
local function test_extra_keys_are_named_whatever_their_order()
  local db = assert(Sqlite.memory())
  local probe = assert(load([[
    local db = ...
    local named, why = pcall(function() local r = db:rows("SELECT ?1, ?2", { 1, 2, 3, name = "x" }); return r end)
    local rows, past = db:rows("SELECT ?1, ?2", { 1, 2, [7] = 3, [100] = 1 })
    return named, tostring(why), rows == nil and past.message
  ]], "=probe"))
  local named, why, past = probe(db)
  assert(named == false and tostring(why):find("^probe:2: sqlite: values holds a key") ~= nil, tostring(why))
  assert(past == "sqlite: values holds a parameter 100, and the statement has 2", tostring(past))
  assert(db:close())
end

--- Sqlite.NULL is read-only, and a Value whose fields come through a
--- metatable raises rather than binding NULL.
local function test_null_is_read_only_and_a_value_has_no_metatable()
  local db = assert(Sqlite.memory())
  local probe = assert(load([[
    local db, null = ...
    local wrote, written = pcall(function() null.integer = 1 end)
    local inherited = setmetatable({}, { __index = { integer = 5 } })
    local bound, why = pcall(function() local r = db:rows("SELECT ?1", { inherited }); return r end)
    return wrote, tostring(written), bound, tostring(why)
  ]], "=probe"))
  local wrote, written, bound, why = probe(db, Sqlite.NULL)
  assert(wrote == false and tostring(written):find("Sqlite.NULL is read-only", 1, true) ~= nil, tostring(written))
  assert(bound == false and tostring(why):find("^probe:4: sqlite: parameter 1 is a table with a metatable") ~= nil,
    tostring(why))
  local rows = assert(db:rows("SELECT ?1 IS NULL", { Sqlite.NULL }))
  assert(first_row(rows):integer(1) == 1)
  assert(db:close())
end
