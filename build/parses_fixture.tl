--- A parse's rows as a test compares them: every row of every table a
--- parse fills ([`build.analysis_schema`]'s `tables`), and the rows a
--- query answers of a database on disk, a line each. Test support for
--- build/shared_parses_test.tl and build/shared_parses_tool_test.tl,
--- which compare what one build or boot parsed with another's.
---
--- The rows are written with [`cosmic.csv.encode`], a tab between fields
--- and a line between rows, so a field that holds a tab, a quote or a line
--- break is quoted, and no two row sets dump alike (see [`dump`]): the parse
--- tables hold text, such as a source, that has all of them, and the tests
--- compare dumps with `==`. Plain fields come out as they are.

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

--- `field` as a dump writes it. NULL is the bare `\N`, and a text that is
--- exactly `\N` is quoted so it is no NULL. An empty text is quoted when
--- `alone`, the only field of its record: unquoted, the record would be a
--- blank line, no record.
local function dumped_field(field: string?, alone: boolean): string
  if field == nil then return "\\N" end
  if field == "\\N" then return '"\\N"' end
  return Csv.encode_field(field, { delimiter = "\t", quote_empty = alone })
end

--- Every row `sql` answers of the database at `path`, a line each: fields
--- joined by a tab, lines by a line feed, the last without its end.
---
--- NULL, an empty text and no rows dump apart. A field is written as
--- [`Csv.encode_field`] writes it with a tab delimiter, except that NULL is
--- the bare `\N` (as `cosmic sql` writes it), and a text that is exactly `\N`
--- is quoted, `"\N"`. An empty text is quoted, `""`, when it is the only field
--- of a row, so a row of one empty text is not no rows, and a row of one NULL
--- is neither. Every other cell is written as its text, as
--- [`Sqlite.text_rows`] answers it, with no mark of its type: the integer 1
--- and the text '1' dump alike, as a blob and the text of the same bytes do.
---
--- The rows are read in one pass, so a query with no ORDER BY that answers in
--- another order on each run still dumps each NULL on its own row.
function parses_fixture.dump(path: string, sql: string): string
  local db = assert(Sqlite.open(path))
  local statement = assert(db:prepare(sql))
  local width = statement:columns()
  local lines: mut {string} = {}
  while true do
    local state = assert(statement:step())
    if state == "done" then break end
    local record: mut {string} = {}
    for i = 0, width - 1 do
      local field: string? = nil
      if statement:kind(i) ~= "null" then field = statement:bytes(i) end
      record[#record + 1] = dumped_field(field, width == 1)
    end
    lines[#lines + 1] = table.concat(record, "\t")
  end
  statement:finalize()
  assert(db:close())
  return table.concat(lines, "\n")
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
