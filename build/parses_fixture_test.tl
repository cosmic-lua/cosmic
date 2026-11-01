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
