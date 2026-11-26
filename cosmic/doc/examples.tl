--- The examples a page shows: those a database holds for a symbol, ranked, and their shown source of [`cosmic.doc`]. Use [`cosmic.doc`]; apart from it only to keep that module smaller.

local Sqlite = require("cosmic.sqlite")
local String = require("cosmic.string")
local symbols = require("cosmic.internal.symbols")
local Types = require("cosmic.doc.types")
local type Example = Types.Example
local type Entry = Types.Entry

--- A top-level piece of an example's head as [`pieces_of`] reads it: the
--- lines so far, and its first line that is not a comment.
local record Piece
  mut lines: mut {string}
  mut code: string
end

--- A top-level piece of an example's head: its `text`, and its first line
--- of code.
local record HeadPiece
  text: string
  code: string
end

local record Examples
  type Entry = Entry
  type Example = Example
  type Piece = Piece
  type HeadPiece = HeadPiece
  columns: string
  EXAMPLES_SHOWN: integer
end

--- `value` as a statement's text parameter.
function Examples.text(value: string): Sqlite.Value
  return { text = value }
end
local text = Examples.text

--- A symbol as an `examples_fts` phrase: [`Fs.read`] and `Fs:read` alike
--- become `"Fs read"`, which matches those adjacent tokens in that order
--- in an example's text or source. Looser than an exact join on purpose:
--- one example covers every symbol its code mentions, not only the
--- one whose name it shares.
---
--- On its own this over-matches: FTS5's tokenizer splits on `_`, so
--- `Hash.hex` and [`Hash.hex_sha256`] share the same first two tokens, and
--- `"Hash hex"` matches an example that only ever calls the second one.
--- [`example_boundary`] is the other half of every query this builds --
--- a phrase match narrows to candidates cheaply, the boundary check
--- on those few rows says whether the symbol is really there, whole.
local function example_phrase(symbol: string): string
  return '"' .. symbol:gsub("[%.:]", " ") .. '"'
end

--- A GLOB pattern matching `symbol` followed by a character that could
--- not continue the same identifier -- so `Hash.hex` matches `Hash.hex(`
--- but not [`Hash.hex_sha256`]. Checked against an example's own text and
--- source, space-joined so a match flush against the end of either
--- still has a boundary to land on.
local function example_boundary(symbol: string): string
  return "*" .. symbol .. "[^A-Za-z0-9_]*"
end

local EXAMPLE_BOUNDARY_SQL =
  "(e.text || ' ' || e.source || ' ') GLOB " ..
  "('*' || d.source_symbol || '[^A-Za-z0-9_]*')"

-- The row's use count is never read as queried: [`cosmic.doc.usage.effective_counts`]
-- overwrites it on every path that renders `entry.uses` -- see
-- [`entries_of`] -- so this column is a placeholder, not a correlated
-- `uses` subquery run for every row of every listing or search.
local columns: string =
  "d.module, d.symbol, d.source_symbol, d.exported, d.kind, d.signature, " ..
  "d.text, d.file, d.line, " ..
  "0, " ..
  "CASE WHEN d.symbol = '' THEN 0 ELSE (SELECT count(*) FROM examples_fts " ..
  "JOIN examples e ON e.id = examples_fts.rowid " ..
  "WHERE e.module = d.module AND examples_fts MATCH " ..
  "('\"' || replace(replace(d.source_symbol, '.', ' '), ':', ' ') || '\"') " ..
  "AND " .. EXAMPLE_BOUNDARY_SQL .. ") END"
Examples.columns = columns

function Examples.entries_of(rows: Sqlite.Rows): mut {Entry}
  local out: mut {Entry} = {}
  for _, row in ipairs(rows) do
    out[#out + 1] = {
      module = row:text(1), symbol = row:text(2), source_symbol = row:text(3),
      exported = row:integer(4) == 1, kind = row:text(5), signature = row:text(6),
      text = row:text(7), file = row:text(8), line = row:integer(9),
      uses = row:integer(10), links = 0,
      examples = row:integer(11),
      related = {},
    }
  end
  return out
end

--- Every worked example whose own text or source matches `symbol`, in
--- `module`, in the order its file declares them -- see
--- [`example_phrase`]. Several can match one symbol, and each is as
--- relevant as any other, so source order serves better than a
--- ranking. `""` finds nothing, since a module's own row has no code of
--- its own to match.
function Examples.examples_for(db: Sqlite.Handle, public: boolean, module: string,
                               symbol: string): {Example}?, string
  if symbol == "" then
    return {}, ""
  end
  local rows, trouble = db:rows(
    "SELECT e.name, e.text, e.file, e.line, e.source FROM examples_fts " ..
      "JOIN examples e ON e.id = examples_fts.rowid " ..
      "WHERE e.module = ?1 AND examples_fts MATCH ?2 " ..
      "AND (e.text || ' ' || e.source || ' ') GLOB ?3 " ..
      "AND " .. symbols.public_only("e.module", public) .. " " ..
      "ORDER BY e.file, e.line",
    { text(module), text(example_phrase(symbol)), text(example_boundary(symbol)) })
  if rows == nil then
    return nil, tostring(trouble)
  end
  local out: mut {Example} = {}
  for _, row in ipairs(rows) do
    out[#out + 1] = { name = row:text(1), text = row:text(2), file = row:text(3),
      line = row:integer(4), source = row:text(5) }
  end
  return out, ""
end

--- How many worked examples a symbol's page shows in full; the rest are
--- named in one line after them.
local EXAMPLES_SHOWN <const> = 2
Examples.EXAMPLES_SHOWN = EXAMPLES_SHOWN

--- Whether `at` in `code` starts a name: nothing before it continues an
--- identifier, so `MyFs.read` is no [`Fs.read`].
local function starts_name(code: string, at: integer): boolean
  return at == 1 or code:sub(at - 1, at - 1):match("[%w_]") == nil
end

--- How many times `code` calls `symbol`, and where the first call is.
--- A call is spelled with `.` or `:` before the last name; a method
--- (a symbol two records deep, [`Sqlite.Handle.exec`], or one written
--- with `:`) is also called through any value, `db:exec(`.
function Examples.calls_of(code: string, symbol: string): integer, integer
  local spellings = { symbol }
  local colon = symbol:gsub("%.([%w_]+)$", ":%1")
  if colon ~= symbol then spellings[#spellings + 1] = colon end
  local last = symbol:match("([%w_]+)$")
  local _, dots = symbol:gsub("%.", "")
  if last ~= nil and (symbol:find(":", 1, true) ~= nil or dots >= 2) then
    spellings[#spellings + 1] = ":" .. last
  end
  local count, first = 0, math.maxinteger
  for _, spelled in ipairs(spellings) do
    local from = 1
    while true do
      local at, to = code:find(spelled, from, true)
      if at == nil or to == nil then break end
      local after = code:sub(to + 1, to + 1)
      if after:match("[%w_]") == nil and (spelled:sub(1, 1) == ":" or starts_name(code, at)) then
        count = count + 1
        first = math.min(first, at)
      end
      from = to + 1
    end
  end
  return count, first
end
local calls_of = Examples.calls_of

--- The function of an example's source, without the `require` lines and
--- top-level calls the analyzer put above it.
function Examples.example_body(source: string): string
  return source:match("function Example%..*$") or source
end
local example_body = Examples.example_body

--- Whether `line` closes the statement above it rather than begins one.
local function closes(line: string): boolean
  return line:match("^[})%]]") ~= nil or line:match("^end%f[^%w_]") ~= nil
end

--- What the analyzer put above an example's function, cut into its
--- top-level pieces: a `require`, a helper (any other `local`) or a
--- call (`Test.policy{...}`), each with the comment lines above it. The
--- text is in the layout `cosmic fix` writes, so a piece begins at a
--- line in column one that does not close the one before. `code` is a
--- piece's first line that is not a comment.
local function pieces_of(head: string): {HeadPiece}
  local out: mut {HeadPiece} = {}
  -- The piece being read: its lines so far and its first line of code.
  local current: Piece = { lines = {}, code = "" }
  local function finish()
    local lines = current.lines
    local last = #lines
    while last > 0 and lines[last] == "" do last = last - 1 end
    if last > 0 then
      table.insert(out, { text = table.concat(lines, "\n", 1, last), code = current.code })
    end
    current.lines = {}
    current.code = ""
  end
  for line in String.lines(head) do
    local comment = line:match("^%-%-") ~= nil
    if line ~= "" and line:match("^%s") == nil and not closes(line) then
      local lines = current.lines
      if current.code ~= "" or (comment and #lines > 0 and lines[#lines] == "") then
        finish()
      end
      if not comment then current.code = line end
    end
    local lines = current.lines
    lines[#lines + 1] = line
  end
  finish()
  return out
end

--- An example's source as its page for `symbol` shows it. The analyzer
--- puts above the function the `require` lines it needs, the short
--- helpers it uses (`local function`, `local record`, ...) and, for a
--- file's first example, the file's top-level calls (`Test.policy{...}`).
--- Those calls are shown only on the page of a symbol they call; any
--- other page gets the function, the helpers and the `require` lines
--- its body and helpers name.
function Examples.shown_source(source: string, symbol: string): string
  local body = example_body(source)
  local head = source:sub(1, #source - #body)
  local requires: mut {string} = {}
  local helpers: mut {string} = {}
  local calls: mut {string} = {}
  for _, piece in ipairs(pieces_of(head)) do
    if piece.code:match("^local [%w_]+ = require%(") ~= nil then
      requires[#requires + 1] = piece.text
    elseif piece.code:match("^local ") ~= nil then
      helpers[#helpers + 1] = piece.text
    else
      calls[#calls + 1] = piece.text
    end
  end
  if #calls == 0 then
    return source
  end
  local call_text = table.concat(calls, "\n")
  if calls_of(call_text, symbol) > 0 then
    return source
  end
  local wanted = body .. "\n" .. table.concat(helpers, "\n")
  local kept: mut {string} = {}
  for _, line in ipairs(requires) do
    local name = line:match("^local ([%w_]+)")
    local found = false
    local from = 1
    while name ~= nil and not found do
      local at, to = wanted:find(name, from, true)
      if at == nil or to == nil then break end
      found = starts_name(wanted, at) and wanted:sub(to + 1, to + 1):match("[%w_]") == nil
      from = to + 1
    end
    if found then kept[#kept + 1] = line end
  end
  local out = ""
  if #kept > 0 then out = table.concat(kept, "\n") .. "\n\n" end
  if #helpers > 0 then out = out .. table.concat(helpers, "\n\n") .. "\n\n" end
  return out .. body
end

return Examples
