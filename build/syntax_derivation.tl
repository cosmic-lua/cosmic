--- The rows of one parse that the syntax tree gives, written where [`build.derivation`] writes a parse's rows: what the
--- source requires, whether it returns a value and under what name, the tests it defines and the policy it declares,
--- the failure messages it catalogs, the symbols it documents, the members of other modules it refers to, the names it
--- binds to a module, its worked examples, the links of its comments, where it declares a global, where it declares a
--- type or a member of one, and its stub. It is the port of [`build.derivation`]'s `parse_fresh` for a source already
--- parsed ([`build.syntax_analyzer`] and [`build.syntax_link_text`] read it), which [`build.pipeline`]'s `derive` calls
--- in the mode `COSMIC_GRAMMAR=new` chooses.
local Analyzer = require("build.syntax_analyzer")
local Ast = require("lang.ast")
local Globals = require("build.syntax_globals")
local LinkText = require("build.link_text")
local Node = require("build.syntax_node")
local Places = require("build.syntax_places")
local Sqlite = require("cosmic.sqlite")
local Stub = require("build.syntax_stub")
local SyntaxLinkText = require("build.syntax_link_text")
local bind = require("build.bind")

local record Derivation
  --- What the tree gives of a source.
  record Rows
    requires: {string}
    globals: {Globals.Place}
    --- Where it declares the types and members that other modules name. A source that is generated from another
    --- (`mapped`) keeps those its `-- line` map names, at the line the map gives and column 1, length 0: its own lines are
    --- not the file's, and the name's column in that file is not known here ([`build.lsp.source`] finds it).
    places: {Places.Found}
    --- The stub of a source that returns a value, nil for one that returns nothing (a test, as a rule): it is no module
    --- a checker reads in place of anything.
    stub: Stub.Made?
    --- The tests, the policy, the catalog, the docs, the examples, the references and the bound names.
    analysis: Analyzer.Analysis
    --- The links of its comments. A source that is generated from another (`mapped`) keeps none: they would name
    --- lines the file does not have.
    links: {LinkText.Found}
  end

  --- The rows of `chunk`, the tree of `source` named `file`; nil and why where the source declares a policy the build
  --- cannot read. `mapped` says the source was derived rather than staged ([`build.derivation`]'s `Fresh`), so that
  --- its symbols stand at the lines of the file it was generated from where the source says them
  --- (`-- line <symbol> <line>`).
  rows_of: function(chunk: Ast.Chunk, source: string, file: string, mapped: boolean): Rows?, string

  --- Writes the rows of the source `source_hash`, the tree of which is `chunk`, as [`build.derivation`] writes them.
  --- `file` names the source in a failure. With `stub` a source that returns a value has that stub, and not the one the tree
  --- gives.
  insert: function(db: Sqlite.Handle, source_hash: string, file: string, source: string, chunk: Ast.Chunk,
                   mapped: boolean, stub?: Stub.Made): boolean, string
end

local text = bind.text

--- Where a generated source's declarations sit in the file it was generated from, by symbol: its `-- line <symbol>
--- <line>` comments, which [`build.gen_syscalls`] writes. Its own lines say nothing about that file, so a symbol it
--- does not name has no line: 0. nil when the source names none -- a source written by hand, or generated with no such
--- map -- whose own lines stand.
local function origin_lines(source: string): {string: integer}?
  local lines: mut {string: integer} = {}
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

function Derivation.rows_of(chunk: Ast.Chunk, source: string, file: string, mapped: boolean): Derivation.Rows?, string
  local scoped = Node.scope(chunk, file)
  local found, why = Analyzer.analysis_of(chunk, scoped, source, file)
  if found == nil then
    return nil, why
  end
  local lines: {string: integer}? = nil
  if mapped then
    lines = origin_lines(source)
  end
  local analysis = found
  if lines ~= nil then
    local docs: mut {Analyzer.DocEntry} = {}
    for _, entry in ipairs(found.docs) do
      docs[#docs + 1] = { symbol = entry.symbol, source_symbol = entry.source_symbol, exported = entry.exported,
        kind = entry.kind, signature = entry.signature, text = entry.text, line = lines[entry.symbol] or 0 }
    end
    analysis = { tests = found.tests, inputs = found.inputs, has_top_level_return = found.has_top_level_return,
      export = found.export, catalog = found.catalog, docs = docs, examples = found.examples,
      references = found.references, bound = found.bound }
  end
  local stub: Stub.Made? = nil
  if found.has_top_level_return then
    stub = Stub.made(chunk)
  end
  local links: {LinkText.Found} = {}
  if not mapped then
    links = SyntaxLinkText.found(chunk, scoped, source)
  end
  local places: {Places.Found} = {}
  if not mapped then
    places = Places.found(chunk)
  elseif lines ~= nil then
    -- A symbol is the dotted path from the module's record ([`sys.Stat.size`]), the map's key the path below it.
    local kept: mut {Places.Found} = {}
    local prefix = found.export .. "."
    for _, place in ipairs(Places.found(chunk)) do
      local key = place.symbol:sub(#prefix + 1)
      local line = lines[key]
      if found.export ~= "" and place.symbol:sub(1, #prefix) == prefix and line ~= nil then
        kept[#kept + 1] = { symbol = place.symbol, kind = place.kind, token = place.token, line = line,
          column = 1, length = 0 }
      end
    end
    places = kept
  end
  return { requires = Node.requires(chunk), globals = Globals.found(chunk), places = places, stub = stub,
    analysis = analysis, links = links }, ""
end

--- A row of `test_inputs`: a `field` of the declaration and its `value`.
local record InputRow
  field: string
  value: string
end

--- The rows `test_inputs` keeps of one parse (see [`build.work`]): its `policy` declaration, as the `needs` it stands
--- for, field by field.
local function insert_test_inputs(db: Sqlite.Handle, source_hash: string, declared: Analyzer.Declared?): boolean, string
  local rows: mut {InputRow} = {}
  local function each(field: string, list: {string})
    for _, value in ipairs(list) do
      rows[#rows + 1] = { field = field, value = value }
    end
  end
  if declared ~= nil then
    table.insert(rows, { field = "line", value = tostring(declared.line) })
    each("reads", declared.reads)
    each("host", declared.host)
    each("env", declared.env)
    each("network", declared.network)
    for _, flag in ipairs({ "tool", "lua", "nests", "noexec", "store", "system" }) do
      local set: {string: boolean} = { tool = declared.tool, lua = declared.lua, nests = declared.nests,
        noexec = declared.noexec, store = declared.store, system = declared.system }
      if set[flag] == true then
        rows[#rows + 1] = { field = flag, value = "true" }
      end
    end
    each("caches", declared.caches)
    each("parent", declared.parent or {})
    each("requires", declared.requires)
  end
  for ordinal, row in ipairs(rows) do
    local ok, why = Sqlite.run(db,
      "INSERT INTO test_inputs (source_hash, ordinal, field, value) VALUES (?1, ?2, ?3, ?4)",
      { text(source_hash), { integer = ordinal }, text(row.field), text(row.value) })
    if not ok then
      return false, why
    end
  end
  return true, ""
end

function Derivation.insert(db: Sqlite.Handle, source_hash: string, file: string, source: string, chunk: Ast.Chunk,
                           mapped: boolean, given?: Stub.Made): boolean, string
  local made, trouble = Derivation.rows_of(chunk, source, file, mapped)
  if made == nil then
    return false, file .. ": " .. trouble
  end
  local rows: Derivation.Rows = made
  local found = rows.analysis
  local hash = text(source_hash)
  --- Writes one row, naming the file in a failure.
  local function put(statement: string, cells: {Sqlite.Value}): boolean, string
    local ok, why = Sqlite.run(db, statement, cells)
    if not ok then
      return false, file .. ": " .. why
    end
    return true, ""
  end
  local ok, why = put("INSERT INTO parsed (source_hash, has_return, export) VALUES (?1, ?2, ?3)",
    { hash, { integer = if found.has_top_level_return then 1 else 0 end }, text(found.export) })
  if not ok then
    return false, why
  end
  for ordinal, name in ipairs(rows.requires) do
    ok, why = put("INSERT INTO requires (source_hash, ordinal, name) VALUES (?1, ?2, ?3)",
      { hash, { integer = ordinal }, text(name) })
    if not ok then
      return false, why
    end
  end
  for ordinal, name in ipairs(found.tests) do
    ok, why = put("INSERT INTO tests (source_hash, ordinal, name) VALUES (?1, ?2, ?3)",
      { hash, { integer = ordinal }, text(name) })
    if not ok then
      return false, why
    end
  end
  ok, why = insert_test_inputs(db, source_hash, found.inputs)
  if not ok then
    return false, file .. ": " .. why
  end
  for ordinal, entry in ipairs(found.catalog) do
    ok, why = put("INSERT INTO catalog (source_hash, ordinal, symbol, message, line) VALUES (?1, ?2, ?3, ?4, ?5)",
      { hash, { integer = ordinal }, text(entry.symbol), text(entry.message), { integer = entry.line } })
    if not ok then
      return false, why
    end
  end
  for ordinal, entry in ipairs(found.docs) do
    ok, why = put("INSERT INTO docs (source_hash, ordinal, symbol, source_symbol, exported, kind, signature, text, " ..
        "line) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9)",
      { hash, { integer = ordinal }, text(entry.symbol), text(entry.source_symbol),
        { integer = if entry.exported then 1 else 0 end }, text(entry.kind), text(entry.signature), text(entry.text),
        { integer = entry.line } })
    if not ok then
      return false, why
    end
  end
  for ordinal, entry in ipairs(found.references) do
    ok, why = put("INSERT INTO refs (source_hash, ordinal, module, member, line) VALUES (?1, ?2, ?3, ?4, ?5)",
      { hash, { integer = ordinal }, text(entry.module), text(entry.member), { integer = entry.line } })
    if not ok then
      return false, why
    end
  end
  for ordinal, entry in ipairs(found.bound) do
    ok, why = put("INSERT INTO bound (source_hash, ordinal, name, module) VALUES (?1, ?2, ?3, ?4)",
      { hash, { integer = ordinal }, text(entry.name), text(entry.module) })
    if not ok then
      return false, why
    end
  end
  for ordinal, entry in ipairs(rows.links) do
    local link = entry.link
    ok, why = put("INSERT INTO links (source_hash, ordinal, line, column, form, doc, text, target, own, alias) " ..
        "VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10)",
      { hash, { integer = ordinal }, { integer = link.line }, { integer = link.column }, text(link.form),
        { integer = if entry.doc then 1 else 0 end }, text(link.text), text(link.target), { integer = if entry.own then 1 else 0 end },
        text(entry.alias) })
    if not ok then
      return false, why
    end
  end
  for ordinal, entry in ipairs(found.examples) do
    ok, why = put("INSERT INTO examples (source_hash, ordinal, name, text, source, line) " ..
        "VALUES (?1, ?2, ?3, ?4, ?5, ?6)",
      { hash, { integer = ordinal }, text(entry.name), text(entry.text), text(entry.source),
        { integer = entry.line } })
    if not ok then
      return false, why
    end
  end
  -- TODO: keep a guide example's global at its Markdown line, once build.doctest's generated source carries a line map
  -- for every line of an example (it names only the line each example's block opens on, `-- line NAME N`): it is
  -- kept at the generated module's own.
  for ordinal, place in ipairs(rows.globals) do
    ok, why = put("INSERT INTO globals (source_hash, ordinal, line, column) VALUES (?1, ?2, ?3, ?4)",
      { hash, { integer = ordinal }, { integer = place.line }, { integer = place.column } })
    if not ok then
      return false, why
    end
  end
  for ordinal, place in ipairs(rows.places) do
    ok, why = put("INSERT INTO places (source_hash, ordinal, symbol, kind, line, column, length) " ..
        "VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)",
      { hash, { integer = ordinal }, text(place.symbol), text(place.kind), { integer = place.line },
        { integer = place.column }, { integer = place.length } })
    if not ok then
      return false, why
    end
  end
  local stub = rows.stub
  if stub ~= nil and given ~= nil then
    stub = given
  end
  if stub ~= nil then
    return put("INSERT INTO stubs (source_hash, text, pruned) VALUES (?1, ?2, ?3)",
      { hash, text(stub.text), { integer = if stub.pruned then 1 else 0 end } })
  end
  return true, ""
end

return Derivation
