--- Generated inputs and analysis rows, including their shared encoding.
---
--- Every operation that determines a parse's contents lives in this
--- closure. The importer chooses when to reuse or run it, and owns the
--- cache; changing that transport cannot change the analyzer's identity.

local Sqlite = require("cosmic.sqlite")
local analysis_schema = require("build.analysis_schema")
local analyzer = require("build.analyzer")
local ast = require("build.ast")
local doctest = require("build.doctest")
local gen_syscalls = require("build.gen_syscalls")
local link_text = require("build.link_text")
local Template = require("cosmic.template")
local bind = require("build.bind")
local type compiler = require("build.compiler")

local record derivation
  record Parses
    parsed: integer
    shared: integer
  end
  record Source
    source_hash: string
    mapped: boolean
  end
  record Parse
    --- What it requires, in order: its `requires` rows.
    requires: {string}
    --- Its rows in every other analysis table ([`packed_parses`]).
    rows: string
  end
end

local type Source = derivation.Source
local text = bind.text
local analysis_tables = analysis_schema.tables

--- Puts the compiler in (the Lua that the vendored `tl.tl`, patched, was
--- compiled to: core/bridge.lua's `bootstrap`) as the one input with no
--- file behind it, for every later build to carry. It replaces any
--- compiler row already there, under whatever file it named: there is
--- only ever one.
function derivation.put_compiler(db: Sqlite.Handle, source: string): boolean, string
  local cleared, trouble = db:exec("DELETE FROM derived WHERE origin = 'vendor'")
  if not cleared then
    return false, trouble
  end
  return Sqlite.run(db,
    "INSERT OR REPLACE INTO derived (file, path, kind, origin, from_hash, " ..
      "source, source_hash) VALUES ('o/vendor/tl/tl.tl', 'vendor.tl', " ..
      "'vendor', 'vendor', lower(hex(sha256(?1))), ?1, lower(hex(sha256(?1))))",
    { text(source) })
end

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
    local file, doc_source, from_hash = row[1], row[2], row[3]
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
--- `forget_stale_analysis`): [`cosmic.template`] is in its closure.
local function derive_templates(db: Sqlite.Handle): boolean, string
  local templates, trouble = Sqlite.text_rows(db,
    "SELECT path, CAST(data AS TEXT), sha256 FROM files " ..
      "WHERE path GLOB '*.tmpl' AND path NOT GLOB 'testdata/*' " ..
      "AND path NOT GLOB '*/testdata/*' " ..
      "AND path NOT IN (SELECT file FROM derived) ORDER BY path")
  if templates == nil then
    return false, trouble
  end
  for _, row in ipairs(templates) do
    local file, template_source, from_hash = row[1], row[2], row[3]
    local source, compile_trouble = Template.compile(template_source, file)
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
      local header, from_hash = headers[1][1], headers[1][2]
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
    return false, doubled[1][2] .. " both compile to import path '" ..
      doubled[1][1] .. "'; rename one"
  end
  return true, ""
end

--- Where a generated source's declarations sit in the file it was
--- generated from, by symbol: its `-- line <symbol> <line>` comments,
--- which [`build.gen_syscalls`] writes. Its own lines say nothing about
--- that file, so a symbol it does not name has no line: 0. `nil` when
--- the source names none -- a source written by hand, or generated with
--- no such map -- whose own lines stand.
local function origin_lines(source: string): {string: integer} | nil
  local lines: {string: integer} = {}
  local any = false
  for each in source:gmatch("[^\n]+") do
    local symbol, line = each:match("^%-%- line ([%w_.]+) (%d+)$")
    if symbol ~= nil then
      lines[symbol] = math.tointeger(tonumber(line)) or 0
      any = true
    end
  end
  if not any then
    return nil
  end
  return lines
end

--- The rows `test_inputs` keeps of one parse (see [`build.work`]): its
--- `policy` declaration ([`cosmic.test`]), as the `needs` it stands for,
--- field by field.
local function insert_test_inputs(db: Sqlite.Handle, source_hash: string,
                                  found: analyzer.Analysis): boolean, string
  local rows: {{string}} = {}
  local function each(field: string, list: {string})
    for _, value in ipairs(list) do rows[#rows + 1] = { field, value } end
  end
  local declared = found.inputs
  if declared ~= nil then
    rows[#rows + 1] = { "line", tostring(declared.line) }
    each("reads", declared.reads)
    each("host", declared.host)
    each("env", declared.env)
    each("network", declared.network)
    if declared.tool then rows[#rows + 1] = { "tool", "true" } end
    if declared.lua then rows[#rows + 1] = { "lua", "true" } end
    if declared.nests then rows[#rows + 1] = { "nests", "true" } end
    if declared.noexec then rows[#rows + 1] = { "noexec", "true" } end
    if declared.store then rows[#rows + 1] = { "store", "true" } end
    if declared.system then rows[#rows + 1] = { "system", "true" } end
    each("caches", declared.caches)
    each("parent", declared.parent or {})
    each("requires", declared.requires or {})
  end
  for ordinal, row in ipairs(rows) do
    local ok, why = Sqlite.run(db,
      "INSERT INTO test_inputs (source_hash, ordinal, field, value) VALUES (?1, ?2, ?3, ?4)",
      { text(source_hash), { integer = ordinal }, text(row[1]), text(row[2]) })
    if not ok then return false, why end
  end
  return true, ""
end

--- One parse of every source no parse has seen, each counted in
--- `tally` and listed in `made`: what it requires, in order, the tests
--- it defines, and whether it returns its own value.
--- Structural, over the real AST, never a regex over text: a
--- `require("cosmic.foo")` inside a string literal or a comment is not
--- an import. Type-only requires and conditional reassignments are real
--- dependencies the build order must see.
function derivation.parse_new(db: Sqlite.Handle, built: compiler, tally: derivation.Parses,
                              made: {Source}): boolean, string
  local fresh, trouble = Sqlite.text_rows(db,
    "SELECT source_hash, min(file), source, max(origin <> 'tree') FROM inputs " ..
      "WHERE kind <> 'vendor' " ..
      "AND source_hash NOT IN (SELECT source_hash FROM parsed) " ..
      "GROUP BY source_hash ORDER BY source_hash")
  if fresh == nil then
    return false, trouble
  end
  for _, row in ipairs(fresh) do
    local source_hash, file, source = row[1], row[2], row[3]
    local mapped = row[4] == "1" and origin_lines(source) or nil
    local parsed, parse_trouble = ast.parse(built, source, file)
    if parsed == nil then
      return false, file .. ": " .. parse_trouble
    end
    local requires, requires_trouble = ast.all_requires(built, parsed)
    if requires == nil then
      return false, file .. ": " .. requires_trouble
    end
    local found, analysis_trouble = analyzer.analysis_of(built, parsed, source)
    if found == nil then
      return false, file .. ": " .. analysis_trouble
    end
    tally.parsed = tally.parsed + 1
    made[#made + 1] = { source_hash = source_hash, mapped = row[4] == "1" }
    local ok, why = Sqlite.run(db,
      "INSERT INTO parsed (source_hash, has_return, export) VALUES (?1, ?2, ?3)",
      { text(source_hash), { integer = found.has_top_level_return and 1 or 0 },
        text(found.export) })
    if not ok then
      return false, file .. ": " .. why
    end
    for ordinal, name in ipairs(requires) do
      ok, why = Sqlite.run(db,
        "INSERT INTO requires (source_hash, ordinal, name) VALUES (?1, ?2, ?3)",
        { text(source_hash), { integer = ordinal }, text(name) })
      if not ok then
        return false, file .. ": " .. why
      end
    end
    for ordinal, name in ipairs(found.tests) do
      ok, why = Sqlite.run(db,
        "INSERT INTO tests (source_hash, ordinal, name) VALUES (?1, ?2, ?3)",
        { text(source_hash), { integer = ordinal }, text(name) })
      if not ok then
        return false, file .. ": " .. why
      end
    end
    ok, why = insert_test_inputs(db, source_hash, found)
    if not ok then
      return false, file .. ": " .. why
    end
    for ordinal, entry in ipairs(found.catalog) do
      ok, why = Sqlite.run(db,
        "INSERT INTO catalog (source_hash, ordinal, symbol, message, line) " ..
          "VALUES (?1, ?2, ?3, ?4, ?5)",
        { text(source_hash), { integer = ordinal }, text(entry.symbol),
          text(entry.message), { integer = entry.line } })
      if not ok then
        return false, file .. ": " .. why
      end
    end
    for ordinal, entry in ipairs(found.docs) do
      local line = entry.line
      if mapped ~= nil then
        line = mapped[entry.symbol] or 0
      end
      ok, why = Sqlite.run(db,
        "INSERT INTO docs (source_hash, ordinal, symbol, source_symbol, " ..
          "exported, kind, signature, text, line) " ..
          "VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9)",
        { text(source_hash), { integer = ordinal }, text(entry.symbol),
          text(entry.source_symbol), { integer = entry.exported and 1 or 0 },
          text(entry.kind), text(entry.signature), text(entry.text),
          { integer = line } })
      if not ok then
        return false, file .. ": " .. why
      end
    end
    for ordinal, entry in ipairs(found.references) do
      ok, why = Sqlite.run(db,
        "INSERT INTO refs (source_hash, ordinal, module, member, line) " ..
          "VALUES (?1, ?2, ?3, ?4, ?5)",
        { text(source_hash), { integer = ordinal }, text(entry.module),
          text(entry.member), { integer = entry.line } })
      if not ok then
        return false, file .. ": " .. why
      end
    end
    for ordinal, entry in ipairs(found.bound) do
      ok, why = Sqlite.run(db,
        "INSERT INTO bound (source_hash, ordinal, name, module) VALUES (?1, ?2, ?3, ?4)",
        { text(source_hash), { integer = ordinal }, text(entry.name), text(entry.module) })
      if not ok then
        return false, file .. ": " .. why
      end
    end
    -- A source from outside the tree (a doc guide's test module) is
    -- read at lines of its own, not its file's, so its links are not
    -- kept: they would name lines the file does not have. The guide's
    -- links are its Markdown's, which the stage reads ([`build.work`]'s
    -- `linked`).
    local found_links: {link_text.Found} = {}
    if row[4] ~= "1" then
      found_links = link_text.found(built, parsed.node, source, file)
    end
    for ordinal, entry in ipairs(found_links) do
      local link = entry.link
      ok, why = Sqlite.run(db,
        "INSERT INTO links (source_hash, ordinal, line, column, form, doc, text, " ..
          "target, own, alias) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10)",
        { text(source_hash), { integer = ordinal }, { integer = link.line },
          { integer = link.column }, text(link.form), { integer = entry.doc and 1 or 0 },
          text(link.text), text(link.target), { integer = entry.own and 1 or 0 },
          text(entry.alias) })
      if not ok then
        return false, file .. ": " .. why
      end
    end
    for ordinal, entry in ipairs(found.examples) do
      ok, why = Sqlite.run(db,
        "INSERT INTO examples (source_hash, ordinal, name, text, source, " ..
          "line) VALUES (?1, ?2, ?3, ?4, ?5, ?6)",
        { text(source_hash), { integer = ordinal }, text(entry.name),
          text(entry.text), text(entry.source), { integer = entry.line } })
      if not ok then
        return false, file .. ": " .. why
      end
    end
  end
  return true, ""
end

--- The tables a shared parse packs its rows of ([`packed_parses`]): every
--- analysis table but `requires`, which it holds apart.
local packed_tables: {string} = {}
for _, name in ipairs(analysis_tables) do
  if name ~= "requires" then packed_tables[#packed_tables + 1] = name end
end

--- A list of hashes, as SQLite's `json_each` reads it: each is hex.
local function json_list(hashes: {string}): string
  return '["' .. table.concat(hashes, '","') .. '"]'
end

--- How many cells a row of each of `packed_tables` has after its
--- source hash.
function derivation.table_widths(db: Sqlite.Handle): {string:integer} | nil, string
  local widths: {string:integer} = {}
  for _, name in ipairs(packed_tables) do
    local rows, trouble = Sqlite.text_rows(db,
      "SELECT count(*) FROM pragma_table_info(?1)", { text(name) })
    if rows == nil then return nil, trouble end
    widths[name] = (math.tointeger(tonumber(rows[1][1])) or 1) - 1
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
                                  sources: {Source}): {string:derivation.Parse} | nil, string
  local widths, widths_trouble = derivation.table_widths(db)
  if widths == nil then return nil, widths_trouble end
  local hashes: {string} = {}
  for _, source in ipairs(sources) do hashes[#hashes + 1] = source.source_hash end
  local list = { text(json_list(hashes)) }
  local chosen = "WHERE source_hash IN (SELECT value FROM json_each(?1)) " ..
    "AND source_hash IN (SELECT source_hash FROM parsed)"
  local requires: {string:{string}} = {}
  local pieces: {string:{string}} = {}
  local unpackable: {string:boolean} = {}
  local names, trouble = Sqlite.text_rows(db,
    "SELECT source_hash, name FROM requires " .. chosen .. " ORDER BY source_hash, ordinal", list)
  if names == nil then return nil, trouble end
  for _, row in ipairs(names) do
    local of = requires[row[1]] or {}
    requires[row[1]] = of
    of[#of + 1] = row[2]
  end
  for _, name in ipairs(packed_tables) do
    local rows, rows_trouble = Sqlite.rows(db,
      "SELECT * FROM " .. name .. " " .. chosen .. " ORDER BY 1, 2", list)
    if rows == nil then return nil, rows_trouble end
    local by_hash: {string:{string}} = {}
    local counts: {string:integer} = {}
    for _, row in ipairs(rows) do
      local hash = row[1].text or ""
      local out = by_hash[hash] or {}
      by_hash[hash] = out
      counts[hash] = (counts[hash] or 0) + 1
      for index = 2, #row do
        local cell = row[index]
        if cell.kind == "integer" then
          out[#out + 1] = "i" .. tostring(cell.integer) .. ";"
        elseif cell.kind == "text" then
          local value = cell.text or ""
          out[#out + 1] = "t" .. #value .. ":" .. value
        elseif cell.kind == "null" then
          out[#out + 1] = "n"
        else
          unpackable[hash] = true
        end
      end
    end
    for _, hash in ipairs(hashes) do
      local of = pieces[hash] or {}
      pieces[hash] = of
      of[#of + 1] = name .. " " .. widths[name] .. " " .. (counts[hash] or 0) .. "\n"
      of[#of + 1] = table.concat(by_hash[hash] or {})
    end
  end
  local present, present_trouble = Sqlite.text_rows(db,
    "SELECT source_hash FROM parsed WHERE source_hash IN (SELECT value FROM json_each(?1))", list)
  if present == nil then return nil, present_trouble end
  local out: {string:derivation.Parse} = {}
  for _, row in ipairs(present) do
    local hash = row[1]
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
                                   widths: {string:integer}): {string:{{Sqlite.Value}}} | nil
  local out: {string:{{Sqlite.Value}}} = {}
  local at = 1
  for _, name in ipairs(packed_tables) do
    local header, width_text, count_text, after = rows:match("^([%w_]+) (%d+) (%d+)\n()", at)
    local width = math.tointeger(tonumber(width_text))
    local count = math.tointeger(tonumber(count_text))
    if header ~= name or width ~= widths[name] or count == nil or after == nil then return nil end
    at = math.tointeger(after) or 0
    local table_rows: {{Sqlite.Value}} = {}
    for _ = 1, count do
      local cells: {Sqlite.Value} = {}
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
        local marks: {string} = { "?1" }
        local values: {Sqlite.Value} = { text(hash) }
        for index, cell in ipairs(cells) do
          marks[#marks + 1] = "?" .. (index + 1)
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
function derivation.unparsed(db: Sqlite.Handle): {Source} | nil, string
  local rows, trouble = Sqlite.text_rows(db,
    "SELECT source_hash, max(origin <> 'tree') FROM inputs WHERE kind <> 'vendor' " ..
      "AND source_hash NOT IN (SELECT source_hash FROM parsed) " ..
      "GROUP BY source_hash ORDER BY source_hash")
  if rows == nil then return nil, trouble end
  local out: {Source} = {}
  for _, row in ipairs(rows) do
    out[#out + 1] = { source_hash = row[1], mapped = row[2] == "1" }
  end
  return out, ""
end

--- Produces generated inputs and rejects ambiguous import paths before
--- any cached parse or compile can stand for them.
function derivation.inputs(db: Sqlite.Handle): boolean, string
  for _, step in ipairs({ derive_doc_guides, derive_syscalls, derive_templates, duplicate_import_paths }) do
    local ok, trouble = step(db)
    if not ok then return false, trouble end
  end
  return true, ""
end

return derivation
