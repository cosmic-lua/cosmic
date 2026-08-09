--- Markdown tables of a committed document, read as rows.
---
--- The ratchets in this directory all ask one question of a document --
--- what does this table teach, and where -- and each used to answer it
--- with its own inline scan. Three copies of a markdown parser is three
--- chances to write one that passes a table it never actually read: the
--- scan in `guides_test.tl` fell back to *no rows* if a heading was
--- renamed, and only an `assert(#out > 0)` bolted on afterwards caught
--- it.
---
--- So the scan lives here, once, with `ratchet_test.tl` behind it. A
--- ratchet is only as good as the reader under it, and a reader nobody
--- tests is the weakest link in a chain built to be trusted.
---
--- The rest of a ratchet -- what each row must say, and against which
--- value -- stays in the test. That part is the judgement; this part is
--- just bytes.

local fs = require("cosmic.fs")

--- One row of a markdown table.
local record Row
  --- The first cell, trimmed. This is the row's subject: the marker,
  --- the verb, the name the row is about.
  cell: string
  --- The whole line, for a check that reads the other cells.
  line: string
  --- `path:line`, so a failure names where to go.
  where: string
end

--- A markdown table's rows, optionally only those under one heading.
---
--- A `|`-led line is a row unless it is the separator (`|---|---|`) or
--- the header itself, which callers name so it is skipped by content
--- rather than by counting: a table that grows a column still reads,
--- and a table whose header moved does not silently shift by one.
--- @param path string The document to read
--- @param heading string|nil A `## ` heading to confine the scan to
--- @param header string|nil The first cell of the header row, skipped
--- @return {Row}|nil The rows, in file order
--- @return string An error naming the document
local function rows(path: string, heading?: string,
    header?: string): {Row} | nil, string
  local text, err = fs.read(path)
  if not text then
    return nil, path .. ": " .. (err or "cannot be read")
  end
  local out: {Row} = {}
  local scanning = heading == nil
  local n = 0
  -- `string.gmatch` rather than `text:gmatch`: method syntax does not
  -- see through the narrowing the guard above just did.
  for line in string.gmatch(text, "([^\n]*)\n?") do
    n = n + 1
    -- A heading only turns the scan off for a caller that asked for
    -- one. Without that guard the unfiltered scan -- every table in the
    -- file -- stops dead at the document's first `## `, and reads like
    -- a document with nothing in it.
    if heading ~= nil and line:sub(1, 3) == "## " then
      scanning = line == "## " .. heading
    elseif scanning and line:sub(1, 1) == "|" then
      local cell = line:match("^|%s*(.-)%s*|")
      -- A separator cell is dashes and colons; an empty first cell is a
      -- continuation, and neither is a row with a subject.
      if cell and cell ~= "" and cell ~= header
      and not cell:match("^[-: ]*$") then
        out[#out + 1] = {cell = cell, line = line, where = path .. ":" .. n}
      end
    end
  end
  return out
end

--- The backticked names in a cell, in order.
---
--- A row's subject is not always one name: `` `reproducible` `offline` ``
--- is one cell naming two verbs, and reading the cell whole would look
--- for a verb spelled that way and never find either.
--- @param cell string The cell text
--- @return {string} The names, without their backticks
local function names(cell: string): {string}
  local out: {string} = {}
  for name in cell:gmatch("`([^`]+)`") do
    out[#out + 1] = name
  end
  return out
end

--- Does some row's first cell contain this text?
--- @param list {Row} The rows to search
--- @param marker string The text looked for, as a substring
--- @return Row|nil The first row that carries it
local function bearing(list: {Row}, marker: string): Row | nil
  for _, row in ipairs(list) do
    if row.cell:find(marker, 1, true) then
      return row
    end
  end
  return nil
end

local record RatchetModule
  type Row = Row
  rows: function(path: string, heading?: string,
  header?: string): {Row} | nil, string
  names: function(cell: string): {string}
  bearing: function(list: {Row}, marker: string): Row | nil
end

local M: RatchetModule = {
  rows = rows,
  names = names,
  bearing = bearing,
}

return M
