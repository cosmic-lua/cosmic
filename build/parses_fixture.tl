--- A parse's rows as a test compares them: every row of every table a
--- parse fills (`build.analysis_schema`'s `tables`), and the rows a
--- query answers of a database on disk, a line each. Test support for
--- build/shared_parses_test.tl and build/shared_parses_tool_test.tl,
--- which compare what one build or boot parsed with another's.

local Sqlite = require("cosmic.sqlite")
local analysis_schema = require("build.analysis_schema")

local record parses_fixture
end

--- Every row `sql` answers of the database at `path`, a line each.
function parses_fixture.dump(path: string, sql: string): string
  local db = assert(Sqlite.open(path, false))
  local rows = assert(Sqlite.text_rows(db, sql))
  assert(db:close())
  local lines: {string} = {}
  for _, row in ipairs(rows) do lines[#lines + 1] = table.concat(row, "\t") end
  return table.concat(lines, "\n")
end

--- Every row of every parse table of the working database `db`.
function parses_fixture.rows(db: Sqlite.Handle): string
  local out: {string} = {}
  for _, name in ipairs(analysis_schema.tables) do
    local rows = assert(Sqlite.text_rows(db, "SELECT * FROM " .. name .. " ORDER BY 1, 2"))
    out[#out + 1] = name .. " " .. #rows
    for _, row in ipairs(rows) do out[#out + 1] = table.concat(row, "\t") end
  end
  return table.concat(out, "\n")
end

return parses_fixture
