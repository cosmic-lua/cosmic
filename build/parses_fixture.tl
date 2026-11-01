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
--- No two result sets dump alike. A field is written as
--- [`Csv.encode_field`] writes it with a tab delimiter, except that NULL is
--- the bare `\N` (as `cosmic sql` writes it), and a text that is exactly `\N`
--- is quoted, `"\N"`. An empty text is quoted, `""`, when it is the only field
--- of a row, so a row of one empty text is not no rows, and a row of one NULL
--- is neither. Non-text cells are written as [`Sqlite.text_rows`] answers them.
function parses_fixture.dump(path: string, sql: string): string
  local db = assert(Sqlite.open(path))
  local texts = assert(Sqlite.text_rows(db, sql))
  local kinds = assert(Sqlite.rows(db, sql))
  assert(db:close())
  assert(#texts == #kinds, "the query answered a different number of rows twice")
  local lines: mut {string} = {}
  for i, row in ipairs(texts) do
    local typed = assert(kinds[i])
    local cells = row:texts()
    local record: mut {string} = {}
    for j, cell in ipairs(cells) do
      local field: string? = nil
      if not typed:is_null(j) then field = cell end
      record[j] = dumped_field(field, #cells == 1)
    end
    lines[i] = table.concat(record, "\t")
  end
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
