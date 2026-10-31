--- A parse's rows as a test compares them: every row of every table a
--- parse fills ([`build.analysis_schema`]'s `tables`), and the rows a
--- query answers of a database on disk, a line each. Test support for
--- build/shared_parses_test.tl and build/shared_parses_tool_test.tl,
--- which compare what one build or boot parsed with another's.
---
--- The rows are written with [`cosmic.csv.encode`], a tab between fields and a
--- line between rows, so a field that holds a tab, a quote or a line break is
--- quoted and no two row sets dump alike: the parse tables hold text, such as
--- a source, that has all of them, and the tests compare dumps with `==`.
--- Plain fields come out as they are.

local Csv = require("cosmic.csv")
local Sqlite = require("cosmic.sqlite")
local analysis_schema = require("build.analysis_schema")

local record parses_fixture
end

--- `records` as text, a line each, the last line without its end.
local function written(records: {{string}}): string
  local text = Csv.encode(records, { delimiter = "\t" })
  return (text:gsub("\n$", ""))
end

--- Every row `sql` answers of the database at `path`, a line each.
---
--- TODO: once [`cosmic.csv`] can write an empty field quoted (a `quote_empty`
--- option of `Csv.encode_field`), write NULL and '' apart: [`cosmic.sqlite`]'s
--- `text_rows` answers both as "", so a query that can answer NULL dumps it
--- as an empty text. The parse tables hold no NULL, so [`rows`] is unaffected.
function parses_fixture.dump(path: string, sql: string): string
  local db = assert(Sqlite.open(path))
  local rows = assert(Sqlite.text_rows(db, sql))
  assert(db:close())
  local records: mut {{string}} = {}
  for _, row in ipairs(rows) do records[#records + 1] = row:texts() end
  return written(records)
end

--- Every row of every parse table of the working database `db`.
function parses_fixture.rows(db: Sqlite.Handle): string
  local out: mut {{string}} = {}
  for _, name in ipairs(analysis_schema.tables) do
    local rows = assert(Sqlite.text_rows(db, "SELECT * FROM " .. name .. " ORDER BY 1, 2"))
    out[#out + 1] = { name .. " " .. tostring(#rows) }
    for _, row in ipairs(rows) do out[#out + 1] = row:texts() end
  end
  return written(out)
end

return parses_fixture
