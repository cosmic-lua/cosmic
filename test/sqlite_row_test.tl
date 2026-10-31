local Sqlite = require("cosmic.sqlite")

--- The first of `rows`, which the statement is known to yield.
local function first_row(rows: Sqlite.Rows): Sqlite.Row
  local found = rows[1]
  assert(found, "the statement yields a row")
  return found
end

--- The `i`th of the values `bound`, which the loop above filled.
local function bound_at(bound: {Sqlite.Value}, i: integer): Sqlite.Value
  local found = bound[i]
  assert(found, "the loop bound column " .. tostring(i))
  return found
end

--- One typed row with a column of every kind: an integer, a number, text,
--- a blob that holds a NUL, and NULL.
local function typed(): Sqlite.Row
  local db = assert(Sqlite.memory())
  local rows = assert(Sqlite.rows(db, "SELECT 7, 1.5, 'seven', x'6100ff', NULL"))
  assert(db:close())
  assert(#rows == 1)
  return first_row(rows)
end

--- The message `work` raises with.
local function raises(work: function(): any): string
  local ok, err = xpcall(work, function(e: any): any return e end)
  assert(not ok, "it did not raise")
  return tostring(err)
end

local function test_each_accessor_reads_the_type_it_names()
  local row = typed()
  assert(row:count() == 5)
  assert(row:integer(1) == 7 and math.type(row:integer(1)) == "integer")
  assert(row:number(2) == 1.5)
  assert(row:text(3) == "seven")
  assert(row:blob(4) == "a\0\255")
  assert(row:is_null(5) and not row:is_null(1) and not row:is_null(3))
  assert(row:kind(1) == "integer" and row:kind(2) == "number" and row:kind(3) == "text")
  assert(row:kind(4) == "blob" and row:kind(5) == "null")
end

local function test_number_reads_an_integer_cell_as_a_float()
  local row = typed()
  assert(row:number(1) == 7 and math.type(row:number(1)) == "float")
end

local function test_bytes_reads_text_and_blobs_alike()
  local row = typed()
  assert(row:bytes(3) == "seven" and row:bytes(4) == "a\0\255")
end

local function test_a_cell_of_another_type_raises_naming_both()
  local row = typed()
  local seen = raises(function(): any return row:text(1) end)
  assert(seen:find("row:text(1)", 1, true) and seen:find("column 1 is an integer, not text", 1, true), seen)
  seen = raises(function(): any return row:integer(2) end)
  assert(seen:find("column 2 is a number, not an integer", 1, true), seen)
  seen = raises(function(): any return row:number(3) end)
  assert(seen:find("column 3 is text, not a number or an integer", 1, true), seen)
  seen = raises(function(): any return row:blob(3) end)
  assert(seen:find("column 3 is text, not a blob", 1, true), seen)
  seen = raises(function(): any return row:text(4) end)
  assert(seen:find("column 4 is a blob, not text", 1, true), seen)
  seen = raises(function(): any return row:bytes(1) end)
  assert(seen:find("column 1 is an integer, not text or a blob", 1, true), seen)
end

local function test_null_raises_from_every_typed_accessor()
  local row = typed()
  for _, read in ipairs({
      function(): any return row:integer(5) end,
      function(): any return row:number(5) end,
      function(): any return row:text(5) end,
      function(): any return row:blob(5) end,
      function(): any return row:bytes(5) end,
  }) do
    local seen = raises(read)
    assert(seen:find("column 5 is NULL", 1, true), seen)
  end
end

local function test_a_column_the_row_lacks_raises_with_its_width()
  local row = typed()
  for _, at in ipairs({ 0, 6, -1 }) do
    local seen = raises(function(): any return row:text(at) end)
    assert(seen:find("the row has 5 columns", 1, true), seen)
  end
  local one = first_row((assert(Sqlite.rows(assert(Sqlite.memory()), "SELECT 1"))))
  assert(raises(function(): any return one:integer(2) end):find("the row has 1 column", 1, true))
  assert(raises(function(): any return row:kind(6) end):find("row:kind(6)", 1, true))
  assert(raises(function(): any return row:is_null(0) end):find("row:is_null(0)", 1, true))
end

local function test_number_keeps_the_sign_of_a_negative_zero()
  local db = assert(Sqlite.memory())
  local row = first_row((assert(Sqlite.rows(db, "SELECT -0.0, 9007199254740993"))))
  assert(row:number(1) == 0 and 1 / row:number(1) < 0)
  assert(row:number(2) == 9007199254740992.0)
  assert(db:close())
end

--- The failure names the line that read the row, not the module.
local function test_a_raise_blames_the_caller()
  local row = typed()
  -- Not a tail call: its caller would no longer be on the stack to blame.
  local seen = raises(function(): any
    local held = row:text(1)
    return held
  end)
  assert(seen:find("sqlite_row_test", 1, true), seen)
  seen = raises(function(): any
    local held = row:text(9)
    return held
  end)
  assert(seen:find("sqlite_row_test", 1, true), seen)
end

local function test_value_binds_a_column_back_as_it_was_read()
  local db = assert(Sqlite.memory())
  assert(db:exec("CREATE TABLE copy (a, b, c, d, e)"))
  local row = typed()
  local bound: mut {Sqlite.Value} = {}
  for index = 1, row:count() do bound[index] = row:value(index) end
  assert(bound_at(bound, 1).integer == 7 and bound_at(bound, 2).number == 1.5 and bound_at(bound, 3).text == "seven")
  assert(bound_at(bound, 4).blob == "a\0\255" and bound_at(bound, 5).integer == nil and bound_at(bound, 5).text == nil and bound_at(bound, 5).blob == nil)
  assert(Sqlite.run(db, "INSERT INTO copy VALUES (?1, ?2, ?3, ?4, ?5)", bound))
  local back = first_row((assert(Sqlite.rows(db, "SELECT * FROM copy"))))
  for index = 1, 5 do assert(back:kind(index) == row:kind(index)) end
  assert(back:blob(4) == "a\0\255" and back:text(3) == "seven")
  assert(db:close())
end

local function test_texts_lists_the_columns_of_a_row_of_text()
  local db = assert(Sqlite.memory())
  local texts = first_row((assert(Sqlite.text_rows(db, "SELECT 'a', 'b'")))):texts()
  assert(#texts == 2 and texts[1] == "a" and texts[2] == "b")
  local row = typed()
  assert(raises(function(): any return row:texts() end):find("column 1 is an integer, not text", 1, true))
  assert(db:close())
end

--- `text_rows` keeps SQLite's byte representation: its rows answer `text`
--- for every column, NULL as "" and numbers as SQLite spells them.
local function test_text_rows_answer_text_for_every_column()
  local db = assert(Sqlite.memory())
  local row = first_row((assert(Sqlite.text_rows(db, "SELECT 7, 1.5, 'seven', x'6100ff', NULL, ''"))))
  assert(row:count() == 6)
  assert(row:text(1) == "7" and row:text(2) == "1.5" and row:text(3) == "seven")
  assert(row:text(4) == "a\0\255" and row:text(5) == "" and row:text(6) == "")
  assert(row:bytes(4) == "a\0\255" and row:bytes(5) == "")
  for index = 1, 6 do
    assert(row:kind(index) == "text" and not row:is_null(index))
    assert(row:value(index).text == row:text(index))
  end
  assert(raises(function(): any return row:integer(1) end):find("column 1 is text, not an integer", 1, true))
  assert(raises(function(): any return row:number(2) end):find("column 2 is text", 1, true))
  assert(raises(function(): any return row:blob(4) end):find("column 4 is text, not a blob", 1, true))
  assert(raises(function(): any return row:text(7) end):find("the row has 6 columns", 1, true))
  assert(db:close())
end

local function test_a_zero_column_row_has_no_columns()
  local db = assert(Sqlite.memory())
  assert(db:exec("CREATE TABLE t (a)"))
  local rows = assert(Sqlite.rows(db, "SELECT 1 WHERE 0"))
  assert(#rows == 0)
  assert(raises(function(): any return typed():text(0) end):find("the row has 5 columns", 1, true))
  assert(db:close())
end

local record Entry
  name: string
  n: integer
  note?: string
end

local function test_map_builds_a_record_per_row()
  local db = assert(Sqlite.memory())
  assert(db:exec("CREATE TABLE t (name TEXT, n INTEGER, note TEXT); " ..
      "INSERT INTO t VALUES ('a', 1, NULL), ('b', 2, 'two'), ('c', 3, 'three')"))
  local found = assert(Sqlite.map(db, "SELECT name, n, note FROM t WHERE n > ?1 ORDER BY n",
    { { integer = 1 } }, function(r: Sqlite.Row): Entry
      return { name = r:text(1), n = r:integer(2), note = not r:is_null(3) and r:text(3) or nil }
    end))
  assert(#found == 2)
  assert(found[1].name == "b" and found[1].n == 2 and found[1].note == "two")
  assert(found[2].name == "c" and found[2].n == 3)
  assert(db:close())
end

local function test_map_without_values_and_with_nil_values()
  local db = assert(Sqlite.memory())
  local ones = assert(Sqlite.map(db, "SELECT 1 UNION ALL SELECT 2", nil, function(r: Sqlite.Row): integer
    return r:integer(1)
  end))
  assert(#ones == 2 and ones[1] == 1 and ones[2] == 2)
  assert(db:close())
end

local function test_map_answers_an_empty_list_for_no_rows()
  local db = assert(Sqlite.memory())
  assert(db:exec("CREATE TABLE t (n INTEGER)"))
  local found, trouble = Sqlite.map(db, "SELECT n FROM t", nil, function(r: Sqlite.Row): integer
    return r:integer(1)
  end)
  assert(found ~= nil and #found == 0 and trouble == "")
  assert(db:close())
end

local function test_map_answers_nil_and_why_when_the_statement_fails()
  local db = assert(Sqlite.memory())
  local called = { value = 0 }
  local function project(r: Sqlite.Row): integer
    called.value = called.value + 1
    return r:integer(1)
  end
  local found, trouble = Sqlite.map(db, "SELECT * FROM missing", nil, project)
  assert(found == nil and trouble:find("missing", 1, true) ~= nil, trouble)
  -- A step that fails after a row was read gives no rows at all.
  found, trouble = Sqlite.map(db, "SELECT abs(n) FROM (SELECT 1 AS n UNION ALL " ..
      "SELECT -9223372036854775807 - 1)", nil, project)
  assert(found == nil and trouble ~= "", trouble)
  assert(called.value == 1)
  found, trouble = Sqlite.map(db, "SELECT ?1", { { integer = 1 }, { integer = 2 } }, project)
  assert(found == nil and trouble ~= "")
  assert(db:close(), "a failed map leaves no statement open")
end

local function test_map_finalizes_the_statement_when_the_projection_raises()
  local db = assert(Sqlite.memory())
  local seen = raises(function(): any
    return (Sqlite.map(db, "SELECT 'text'", nil, function(r: Sqlite.Row): integer
      return r:integer(1)
    end))
  end)
  assert(seen:find("column 1 is text, not an integer", 1, true), seen)
  assert(db:close(), "a raising projection leaves no statement open")
end

local function test_map_refuses_a_projection_that_answers_nothing()
  local db = assert(Sqlite.memory())
  local seen = raises(function(): any
    local nothing = function(_: Sqlite.Row): integer?
      return nil
    end
    local project = nothing as function(Sqlite.Row): integer -- cast: a projection that breaks its contract
    return (Sqlite.map(db, "SELECT 1", nil, project))
  end)
  assert(seen:find("project answered nil", 1, true), seen)
  assert(db:close())
end

local function test_a_query_and_its_each_give_rows_the_same_accessors()
  local db = assert(Sqlite.memory())
  local q <close> = assert(Sqlite.query(db, "SELECT 5, 'x', NULL"))
  local row = assert(q:read())
  assert(row:integer(1) == 5 and row:text(2) == "x" and row:is_null(3) and row:count() == 3)
  local nothing, why = q:read()
  assert(nothing == nil and why == "")
end
