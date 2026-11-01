--- build/parses_fixture.tl's dumps: two row sets that the join of a tab and a
--- newline dumped alike dump apart, and plain rows dump as they always did.

local Csv = require("cosmic.csv")
local Sqlite = require("cosmic.sqlite")
local analysis_schema = require("build.analysis_schema")
local parses_fixture = require("build.parses_fixture")

--- What [`parses_fixture.dump`] answers for a table `t` of one column per
--- entry of `columns`, holding `rows`, of a database made in `tmp`.
local function dumped(tmp: string, name: string, columns: {string}, rows: {{string}}): string
  local path = tmp .. "/" .. name .. ".db"
  local db = assert(Sqlite.open(path, { writable = true, create = true }))
  local defs: mut {string} = {}
  local marks: mut {string} = {}
  for i, column in ipairs(columns) do
    defs[i] = column .. " TEXT"
    marks[i] = "?"
  end
  assert(Sqlite.run(db, "CREATE TABLE t (" .. table.concat(defs, ", ") .. ")"))
  for _, row in ipairs(rows) do
    local params: mut {Sqlite.Value} = {}
    for i, field in ipairs(row) do params[i] = { text = field } end
    assert(Sqlite.run(db, "INSERT INTO t VALUES (" .. table.concat(marks, ", ") .. ")", params))
  end
  assert(db:close())
  return parses_fixture.dump(path, "SELECT * FROM t ORDER BY rowid")
end

local function test_a_tab_in_a_field_is_not_a_column_break(tmp: string)
  local one = dumped(tmp, "one", { "a" }, { { "a\tb" } })
  local two = dumped(tmp, "two", { "a", "b" }, { { "a", "b" } })
  assert(one ~= two, "one column holding a tab dumps as two columns do")
end

local function test_a_newline_in_a_field_is_not_a_row_break(tmp: string)
  local one = dumped(tmp, "one", { "a" }, { { "x\ny" } })
  local two = dumped(tmp, "two", { "a" }, { { "x" }, { "y" } })
  assert(one ~= two, "one field holding a newline dumps as two rows do")
end

local function test_a_dump_reads_back_as_its_rows(tmp: string)
  local rows = { { "a\tb", 'say "hi"' }, { "x\r\ny", "z" }, { "", "w" } }
  local text = dumped(tmp, "hostile", { "a", "b" }, rows)
  local back = assert(Csv.parse(text, { delimiter = "\t" }))
  assert(#back == 3)
  for i, row in ipairs(rows) do
    assert(table.concat(assert(back[i]), "|") == table.concat(row, "|"), text)
  end
end

local function test_an_empty_field_is_not_no_row(tmp: string)
  local empty = dumped(tmp, "empty", { "a" }, { { "" } })
  local none = dumped(tmp, "none", { "a" }, {})
  assert(none == "" and empty ~= none, "a row of one empty text is not no rows")
end

--- What [`parses_fixture.dump`] answers for `sql` of an empty database.
local function answer(tmp: string, name: string, sql: string): string
  local path = tmp .. "/" .. name .. ".db"
  local db = assert(Sqlite.open(path, { writable = true, create = true }))
  assert(db:close())
  return parses_fixture.dump(path, sql)
end

local function test_null_is_not_an_empty_text_in_any_column(tmp: string)
  local null = answer(tmp, "a", "SELECT NULL, 1")
  local empty = answer(tmp, "b", "SELECT '', 1")
  assert(null ~= empty, "NULL and '' dump alike in the first column")
  null = answer(tmp, "c", "SELECT 1, NULL")
  empty = answer(tmp, "d", "SELECT 1, ''")
  assert(null ~= empty, "NULL and '' dump alike in the last column")
end

local function test_one_null_is_not_no_rows(tmp: string)
  local null = answer(tmp, "null", "SELECT NULL")
  local none = answer(tmp, "none", "SELECT 1 WHERE 0")
  assert(none == "" and null ~= none, "a row of one NULL dumps as no rows do")
end

local function test_one_empty_text_is_not_no_rows(tmp: string)
  local empty = answer(tmp, "empty", "SELECT ''")
  local none = answer(tmp, "none", "SELECT 1 WHERE 0")
  assert(empty ~= none, "a row of one empty text dumps as no rows do")
end

local function test_one_null_is_not_one_empty_text(tmp: string)
  assert(answer(tmp, "null", "SELECT NULL") ~= answer(tmp, "empty", "SELECT ''"))
end

local function test_a_text_written_like_null_is_not_null(tmp: string)
  local text = answer(tmp, "text", "SELECT '\\N'")
  local null = answer(tmp, "null", "SELECT NULL")
  assert(text ~= null, "the text \\N dumps as NULL does")
  text = answer(tmp, "text2", "SELECT '\\N', 1")
  null = answer(tmp, "null2", "SELECT NULL, 1")
  assert(text ~= null, "the text \\N dumps as NULL does among other fields")
end

local function test_nulls_and_empties_dump_as_written(tmp: string)
  assert(answer(tmp, "mixed", "SELECT NULL, ''") == "\\N\t")
  assert(answer(tmp, "empty", "SELECT ''") == '""')
  assert(answer(tmp, "null", "SELECT NULL") == "\\N")
  assert(answer(tmp, "text", "SELECT '\\N'") == '"\\N"')
end

local function test_plain_rows_dump_as_they_did(tmp: string)
  local text = dumped(tmp, "plain", { "a", "b" }, { { "1", "x y" }, { "2", "z" } })
  assert(text == "1\tx y\n2\tz", text)
  assert(dumped(tmp, "single", { "a" }, { { "1" } }) == "1")
  assert(dumped(tmp, "empty", { "a" }, {}) == "")
end

local function test_the_parse_table_rows_keep_their_header_lines(tmp: string)
  local db = assert(Sqlite.open(tmp .. "/parses.db", { writable = true, create = true }))
  for _, statement in ipairs(analysis_schema.statements) do assert(Sqlite.run(db, statement)) end
  local text = parses_fixture.rows(db)
  assert(db:close())
  assert(text:find("^[%w_]+ 0\n") ~= nil, text)
end
