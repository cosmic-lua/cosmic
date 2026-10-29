--- Generated inputs and analysis rows, including their shared encoding.
---
--- Every operation that determines a parse's contents lives in this
--- closure. The importer chooses when to reuse or run it, and owns the
--- cache; changing that transport cannot change the analyzer's identity.

local Sqlite = require("cosmic.sqlite")
local analysis_schema = require("build.analysis_schema")
local doctest = require("build.doctest")
local gen_syscalls = require("build.gen_syscalls")
local Template = require("cosmic.template")
local bind = require("build.bind")

local record derivation
  record Parses
    mut parsed: integer
    shared: integer
  end
  record Source
    source_hash: string
    mapped: boolean
  end
  --- A source to parse: what [`derivation.fresh`] finds of it. `file` is
  --- the least file with that content, and `mapped` is whether any file
  --- with it was derived rather than staged.
  record Fresh
    source_hash: string
    file: string
    source: string
    mapped: boolean
  end
  record Parse
    --- What it requires, in order: its `requires` rows.
    requires: {string}
    --- Its rows in every other analysis table ([`packed_parses`]).
    rows: string
  end
  --- A source [`build.pipeline`]'s `derive` could not parse, and why: the
  --- message a parse that stops on it answers.
  record Broken
    source_hash: string
    file: string
    message: string
  end
end

local type Source = derivation.Source
local text = bind.text
local analysis_tables = analysis_schema.tables

--- A doc guide's import path, the same dotted-name convention every
--- `.tl` file gets: [`doc/guides/quickstart.md`] compiles as
--- [`doc.guides.quickstart`].
local function import_path_of_doc(file: string): string
  return (file:gsub("%.md$", ""):gsub("/", "."))
end

local insert_derived =
  "INSERT INTO derived (file, path, kind, origin, from_hash, source, " ..
  "source_hash) VALUES (?1, ?2, ?3, ?4, ?5, ?6, lower(hex(sha256(?6))))"

--- The doc guides with no current `derived` row, each extracted into
--- the test module it is.
local function derive_doc_guides(db: Sqlite.Handle): boolean, string
  local guides, trouble = Sqlite.text_rows(db,
    "SELECT path, data, sha256 FROM files " ..
      "WHERE path GLOB 'doc/guides/*.md' AND path NOT GLOB 'doc/guides/*/*' " ..
      "AND path NOT IN (SELECT file FROM derived) ORDER BY path")
  if guides == nil then
    return false, trouble
  end
  for _, row in ipairs(guides) do
    local file, doc_source, from_hash = row:text(1), row:text(2), row:text(3)
    local source, extract_trouble = doctest.extract(doc_source, file)
    if source == nil then
      return false, file .. ": " .. extract_trouble
    end
    local ok, insert_trouble = Sqlite.run(db, insert_derived,
      { text(file), text(import_path_of_doc(file)), text("test"),
        text("doctest"), text(from_hash), text(source) })
    if not ok then
      return false, file .. ": " .. insert_trouble
    end
  end
  return true, ""
end

--- A template's import path, the convention a `.tl` file gets with its
--- extension swapped: `pages/home.tmpl` is `pages.home`, and a
--- directory's own `init.tmpl` is the directory, `pages`.
local function import_path_of_template(file: string): string
  local stem = file:gsub("%.tmpl$", "")
  if stem:sub(-5) == "/init" then
    stem = stem:sub(1, -6)
  end
  return (stem:gsub("/", "."))
end

--- The templates with no current `derived` row, each compiled to the
--- module it is ([`cosmic.template`]). One it refuses fails the build
--- with its own `file:line:col` reason. What the compiler last did to a
--- template stands while the analyzer does ([`build.importer`]'s
--- `forget_stale_analysis`): [`cosmic.template`] is in its closure. The module is written in the new checker's grammar
--- ([`cosmic.template`]'s `Options`).
local function derive_templates(db: Sqlite.Handle): boolean, string
  local templates, trouble = Sqlite.text_rows(db,
    "SELECT path, CAST(data AS TEXT), sha256 FROM files " ..
      "WHERE path GLOB '*.tmpl' " .. analysis_schema.outside_apart("path") .. " " ..
      "AND path NOT IN (SELECT file FROM derived) ORDER BY path")
  if templates == nil then
    return false, trouble
  end
  for _, row in ipairs(templates) do
    local file, template_source, from_hash = row:text(1), row:text(2), row:text(3)
    local source, compile_trouble = Template.compile(template_source, file, { dialects = nil })
    if source == nil then
      return false, compile_trouble
    end
    local ok, insert_trouble = Sqlite.run(db, insert_derived,
      { text(file), text(import_path_of_template(file)), text("module"),
        text("template"), text(from_hash), text(source) })
    if not ok then
      return false, file .. ": " .. insert_trouble
    end
  end
  return true, ""
end

--- The syscall table's declaration and the raw process table's, each
--- generated from its header when the header has no current `derived`
--- row. Only cosmic's own tree has the headers; a project gets the
--- declarations from the binary.
local function derive_syscalls(db: Sqlite.Handle): boolean, string
  for _, target in ipairs(gen_syscalls.targets) do
    local file = target.target.header
    local headers, trouble = Sqlite.text_rows(db,
      "SELECT data, sha256 FROM files WHERE path = ? " ..
        "AND path NOT IN (SELECT file FROM derived)", { text(file) })
    if headers == nil then
      return false, trouble
    end
    if #headers > 0 then
      local header, from_hash = headers[1]:text(1), headers[1]:text(2)
      local source, generate_trouble = gen_syscalls.declaration(header, target.target)
      if source == nil then
        return false, file .. ": " .. generate_trouble
      end
      local ok, insert_trouble = Sqlite.run(db, insert_derived,
        { text(file), text(target.path), text("decl"),
          text("syscalls"), text(from_hash), text(source) })
      if not ok then
        return false, insert_trouble
      end
    end
  end
  return true, ""
end

--- Two files that would answer to one import path. The build refuses
--- rather than letting one shadow the other.
local function duplicate_import_paths(db: Sqlite.Handle): boolean, string
  local doubled, trouble = Sqlite.text_rows(db,
    "SELECT path, group_concat(file, ' and ') FROM inputs " ..
      "WHERE kind <> 'decl' GROUP BY path HAVING count(*) > 1 ORDER BY path")
  if doubled == nil then
    return false, trouble
  end
  if #doubled > 0 then
    return false, doubled[1]:text(2) .. " both compile to import path '" ..
      doubled[1]:text(1) .. "'; rename one"
  end
  return true, ""
end

--- Every source no parse has seen, in hash order: the one parse each
--- needs ([`build.pipeline`]'s `derive`).
function derivation.fresh(db: Sqlite.Handle): {derivation.Fresh}?, string
  local rows, trouble = Sqlite.text_rows(db,
    "SELECT source_hash, min(file), source, max(origin <> 'tree') FROM inputs " ..
      "WHERE kind <> 'vendor' " ..
      "AND source_hash NOT IN (SELECT source_hash FROM parsed) " ..
      "GROUP BY source_hash ORDER BY source_hash")
  if rows == nil then
    return nil, trouble
  end
  local out: mut {derivation.Fresh} = {}
  for _, row in ipairs(rows) do
    out[#out + 1] = { source_hash = row:text(1), file = row:text(2), source = row:text(3), mapped = row:text(4) == "1" }
  end
  return out, ""
end

--- The tables a shared parse packs its rows of ([`packed_parses`]): every
--- analysis table but `requires`, which it holds apart.
local packed_tables: mut {string} = {}
for _, name in ipairs(analysis_tables) do
  if name ~= "requires" then packed_tables[#packed_tables + 1] = name end
end

--- A list of hashes, as SQLite's `json_each` reads it: each is hex.
local function json_list(hashes: {string}): string
  return '["' .. table.concat(hashes, '","') .. '"]'
end

--- How many cells a row of each of `packed_tables` has after its
--- source hash.
function derivation.table_widths(db: Sqlite.Handle): {string:integer}?, string
  local widths: mut {string:integer} = {}
  for _, name in ipairs(packed_tables) do
    local rows, trouble = Sqlite.text_rows(db,
      "SELECT count(*) FROM pragma_table_info(?1)", { text(name) })
    if rows == nil then return nil, trouble end
    widths[name] = (math.tointeger(tonumber(rows[1]:text(1))) or 1) - 1
  end
  return widths, ""
end

--- The parse each of `sources` has in the tables, as a shared parse
--- holds it ([`derivation.Parse`]), by hash: its `requires` names, and
--- its rows in each of `packed_tables`, in that order, each table as its
--- name, how many cells a row has after the source hash, and how many
--- rows, on a line, then each row's cells -- `i` and an integer ended by
--- `;`, `t` and a text's length, `:` and the text, or `n` for null. A
--- source with no `parsed` row, or a cell of another kind, has none.
function derivation.packed_parses(db: Sqlite.Handle,
                                  sources: {Source}): {string:derivation.Parse}?, string
  local widths, widths_trouble = derivation.table_widths(db)
  if widths == nil then return nil, widths_trouble end
  local hashes: mut {string} = {}
  for _, source in ipairs(sources) do hashes[#hashes + 1] = source.source_hash end
  local list = { text(json_list(hashes)) }
  local chosen = "WHERE source_hash IN (SELECT value FROM json_each(?1)) " ..
    "AND source_hash IN (SELECT source_hash FROM parsed)"
  local requires: mut {string:mut {string}} = {}
  local pieces: mut {string:mut {string}} = {}
  local unpackable: mut {string:boolean} = {}
  local names, trouble = Sqlite.text_rows(db,
    "SELECT source_hash, name FROM requires " .. chosen .. " ORDER BY source_hash, ordinal", list)
  if names == nil then return nil, trouble end
  for _, row in ipairs(names) do
    local of = requires[row:text(1)] or {}
    requires[row:text(1)] = of
    table.insert(of, row:text(2))
  end
  for _, name in ipairs(packed_tables) do
    local rows, rows_trouble = Sqlite.rows(db,
      "SELECT * FROM " .. name .. " " .. chosen .. " ORDER BY 1, 2", list)
    if rows == nil then return nil, rows_trouble end
    local by_hash: mut {string:mut {string}} = {}
    local counts: mut {string:integer} = {}
    for _, row in ipairs(rows) do
      local hash = row:kind(1) == "text" and row:text(1) or ""
      local out = by_hash[hash] or {}
      by_hash[hash] = out
      counts[hash] = (counts[hash] or 0) + 1
      for index = 2, row:count() do
        local kind = row:kind(index)
        if kind == "integer" then
          table.insert(out, "i" .. tostring(row:integer(index)) .. ";")
        elseif kind == "text" then
          local value = row:text(index)
          table.insert(out, "t" .. tostring(#value) .. ":" .. value)
        elseif kind == "null" then
          out[#out + 1] = "n"
        else
          unpackable[hash] = true
        end
      end
    end
    for _, hash in ipairs(hashes) do
      local of = pieces[hash] or {}
      pieces[hash] = of
      table.insert(of, name .. " " .. widths[name] .. " " .. tostring((counts[hash] or 0)) .. "\n")
      table.insert(of, table.concat(by_hash[hash] or {}))
    end
  end
  local present, present_trouble = Sqlite.text_rows(db,
    "SELECT source_hash FROM parsed WHERE source_hash IN (SELECT value FROM json_each(?1))", list)
  if present == nil then return nil, present_trouble end
  local out: mut {string:derivation.Parse} = {}
  for _, row in ipairs(present) do
    local hash = row:text(1)
    if not unpackable[hash] then
      out[hash] = { requires = requires[hash] or {}, rows = table.concat(pieces[hash]) }
    end
  end
  return out, ""
end

--- [`packed_parses`]' rows undone, by table, each row its cells after the
--- source hash, for tables `widths` cells wide: nil for what it never
--- writes, or for rows of another width than the tables here have.
function derivation.unpacked_parse(rows: string,
                                   widths: {string:integer}): {string:{{Sqlite.Value}}}?
  local out: mut {string:{{Sqlite.Value}}} = {}
  local at = 1
  for _, name in ipairs(packed_tables) do
    local header, width_text, count_text, after = rows:match("^([%w_]+) (%d+) (%d+)\n()", at)
    local width = math.tointeger(tonumber(width_text))
    local count = math.tointeger(tonumber(count_text))
    if header ~= name or width ~= widths[name] or count == nil or after == nil then return nil end
    at = math.tointeger(after) or 0
    local table_rows: mut {{Sqlite.Value}} = {}
    for _ = 1, count do
      local cells: mut {Sqlite.Value} = {}
      for _ = 1, width do
        local kind = rows:sub(at, at)
        if kind == "i" then
          local digits, next_at = rows:match("^i(%-?%d+);()", at)
          local value = math.tointeger(tonumber(digits))
          if value == nil or next_at == nil then return nil end
          cells[#cells + 1] = { integer = value }
          at = math.tointeger(next_at) or 0
        elseif kind == "t" then
          local length_text, start = rows:match("^t(%d+):()", at)
          local length = math.tointeger(tonumber(length_text))
          local from = math.tointeger(start)
          if length == nil or from == nil or from + length - 1 > #rows then return nil end
          cells[#cells + 1] = { text = rows:sub(from, from + length - 1) }
          at = from + length
        elseif kind == "n" then
          cells[#cells + 1] = {}
          at = at + 1
        else
          return nil
        end
      end
      table_rows[#table_rows + 1] = cells
    end
    out[name] = table_rows
  end
  if at ~= #rows + 1 then return nil end
  return out
end

--- Writes one shared parse of the source `hash` into the tables, as the
--- parse would have: false where it cannot, having written none of it.
function derivation.put_parse(db: Sqlite.Handle, hash: string, requires: {string},
                              rows: {string:{{Sqlite.Value}}}): boolean, string
  local begun, begin_trouble = db:exec("SAVEPOINT shared_parse")
  if not begun then return false, begin_trouble end
  local function steps(): boolean, string
    for ordinal, name in ipairs(requires) do
      local ok, why = Sqlite.run(db,
        "INSERT INTO requires (source_hash, ordinal, name) VALUES (?1, ?2, ?3)",
        { text(hash), { integer = ordinal }, text(name) })
      if not ok then return false, why end
    end
    for _, name in ipairs(packed_tables) do
      for _, cells in ipairs(rows[name]) do
        local marks: mut {string} = { "?1" }
        local values: mut {Sqlite.Value} = { text(hash) }
        for index, cell in ipairs(cells) do
          marks[#marks + 1] = "?" .. tostring((index + 1))
          values[#values + 1] = cell
        end
        local ok, why = Sqlite.run(db, "INSERT INTO " .. name .. " VALUES (" ..
            table.concat(marks, ", ") .. ")", values)
        if not ok then return false, why end
      end
    end
    return true, ""
  end
  local ok, trouble = steps()
  if not ok then
    local _, _ = db:exec("ROLLBACK TO shared_parse")
    local _, _ = db:exec("RELEASE shared_parse")
    return false, trouble
  end
  return db:exec("RELEASE shared_parse")
end

--- Every source the tables hold no parse of, in hash order.
function derivation.unparsed(db: Sqlite.Handle): {Source}?, string
  local rows, trouble = Sqlite.text_rows(db,
    "SELECT source_hash, max(origin <> 'tree') FROM inputs WHERE kind <> 'vendor' " ..
      "AND source_hash NOT IN (SELECT source_hash FROM parsed) " ..
      "GROUP BY source_hash ORDER BY source_hash")
  if rows == nil then return nil, trouble end
  local out: mut {Source} = {}
  for _, row in ipairs(rows) do
    out[#out + 1] = { source_hash = row:text(1), mapped = row:text(2) == "1" }
  end
  return out, ""
end

--- Produces generated inputs and rejects ambiguous import paths before
--- any cached parse or compile can stand for them. The templates are written in the new checker's grammar
--- ([`derive_templates`]).
function derivation.inputs(db: Sqlite.Handle): boolean, string
  for _, step in ipairs({ derive_doc_guides, derive_syscalls }) do
    local ok, trouble = step(db)
    if not ok then return false, trouble end
  end
  local made, made_trouble = derive_templates(db)
  if not made then return false, made_trouble end
  return duplicate_import_paths(db)
end

return derivation
