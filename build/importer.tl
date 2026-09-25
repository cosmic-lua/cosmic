--- The staged tree, read by position into modules.
---
--- A source's path relative to the root is its import path, so nothing
--- lists what a module is: `cosmic/fs.tl` is `cosmic.fs`. A `*.d.tl`
--- declares a module the core provides and holds no code, so it is read
--- for its type and never stored.
---
--- Nothing here reads a path: `build.work` has already staged every
--- input into the working database, and the tree is the rows of its
--- `files` table, which its `inputs` view reads by position. What a
--- build derives beyond that -- the test module a doc guide extracts
--- to, the declaration the syscall header generates to, and what one
--- parse of each source finds -- is written back as rows too, each
--- keyed so it is redone only when what it came from changed, and the
--- modules to compile are a query over them.
---
--- A module's key is its kind, the content hash of its source, the
--- keys of everything it imports, and the identity of the compiler
--- that compiled it -- see `build.work`'s `Identities`. An unchanged
--- key is a stat; a changed one recompiles what depended on it.

local Fs = require("cosmic.fs")
local Hash = require("cosmic.hash")
local Sqlite = require("cosmic.sqlite")
local Store = require("cosmic.store")
local analyzer = require("build.analyzer")
local ast = require("build.ast")
local doctest = require("build.doctest")
local gen_syscalls = require("build.gen_syscalls")
local positions = require("build.positions")
local receivers = require("build.receivers")
local contracts = require("build.contracts")
local symbols = require("build.symbols")
local teal = require("build.teal")
local tree = require("build.tree")
local work = require("build.work")
local type compiler = require("build.compiler")
local bind = require("build.bind")

local type Module = positions.Module

local record importer
  Module: Module

  record Result
    modules: {Module}
    --- The compiler identity every key in `modules` carries.
    tool: string
    main: string | nil
    -- One message per `kind = "test"` module refused compilation
    -- because it both defines its own tests and returns its own value;
    -- every module NOT in this list compiled and is in `modules`.
    refused: {string}
    -- How many modules were compiled this run, and how many came back
    -- from `compiled` under a key that stood.
    compiled: integer
    cached: integer
  end

end

--- The extractors, generators and parser the importer's own derive and
--- parse call: with the importer itself, the roots of
--- `importer.analyzer_modules`. "The analyzer" in these names is that
--- whole set, of which the source analyzer `build.analyzer` is one.
local analyzer_roots: {string} = {
  "build.analyzer", "build.ast", "build.bind", "build.compiler",
  "build.doctest", "build.gen_syscalls",
}

--- The modules whose code decides what the analysis tables record: the
--- importer's own derive and parse, and every module that the
--- extractors, generators and parser it calls reach through `require`,
--- as the running binary's own `imports` table records it. What a
--- source parses to is a function of these and of the compiler, and of
--- nothing else in the tool. The importer's own requires are not
--- followed: it is here for its derive and parse, not for the rest of
--- the build it also runs.
function importer.analyzer_modules(): {string} | nil, string
  local databases = Store.databases()
  local own = databases[#databases]
  if own == nil then return nil, "the binary carries no module database" end
  local seeds: {string} = {}
  local values: {Sqlite.Value} = {}
  for i, name in ipairs(analyzer_roots) do
    seeds[#seeds + 1] = "(?" .. i .. ")"
    values[#values + 1] = { text = name }
  end
  local rows, trouble = Sqlite.text_rows(own,
    "WITH RECURSIVE reached(path) AS (VALUES " .. table.concat(seeds, ", ") ..
    " UNION SELECT i.requires FROM imports i JOIN reached r ON i.path = r.path) " ..
    "SELECT path FROM reached WHERE path IN " ..
    "(SELECT path FROM modules UNION SELECT path FROM decls) " ..
    "AND path <> 'build.importer' ORDER BY path", values)
  if rows == nil then return nil, trouble end
  local names: {string} = { "build.importer" }
  for _, row in ipairs(rows) do names[#names + 1] = row[1] end
  return names, ""
end

--- The bytecode header every target must agree on. One column of
--- bytecode serves all three because they are all little-endian and
--- 64-bit; this is what says so out loud, so a target whose sizes or
--- byte order differ fails the build rather than a launch.
---
--- The bytes are the signature, the version and format, the data check,
--- and the size and value of an int, an instruction, an integer and a
--- number.
local bytecode_header =
  "\27LuaU\0\25\147\13\10\26\10" ..
  "\4\136\169\255\255" ..
  "\4\120\86\52\18" ..
  "\8\136\169\255\255\255\255\255\255" ..
  "\8\0\0\0\0\0\40\119\192"

local text = bind.text

--- A doc guide's import path, the same dotted-name convention every
--- `.tl` file gets: `doc/guides/quickstart.md` compiles as
--- `doc.guides.quickstart`.
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

--- The syscall table's declaration and the raw process table's, each
--- generated from its header when the header has no current `derived`
--- row. Only cosmic's own tree has the headers; a project gets the
--- declarations from the binary.
local function derive_syscalls(db: Sqlite.Handle): boolean, string
  for _, derivation in ipairs(gen_syscalls.targets) do
    local file = derivation.target.header
    local headers, trouble = Sqlite.text_rows(db,
      "SELECT data, sha256 FROM files WHERE path = ? " ..
      "AND path NOT IN (SELECT file FROM derived)", { text(file) })
    if headers == nil then
      return false, trouble
    end
    if #headers > 0 then
      local header, from_hash = headers[1][1], headers[1][2]
      local source, generate_trouble = gen_syscalls.declaration(header, derivation.target)
      if source == nil then
        return false, file .. ": " .. generate_trouble
      end
      local ok, insert_trouble = Sqlite.run(db, insert_derived,
        { text(file), text(derivation.path), text("decl"),
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
--- which `build.gen_syscalls` writes. Its own lines say nothing about
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

--- One parse of every source no parse has seen: what it requires, in
--- order, the tests it defines, and whether it returns its own value.
--- Structural, over the real AST, never a regex over text: a
--- `require("cosmic.foo")` inside a string literal or a comment is not
--- an import. Type-only requires and conditional reassignments are real
--- dependencies the build order must see.
local function parse_new(db: Sqlite.Handle, built: compiler): boolean, string
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

--- The tables a parse or a generator fills, keyed by the source they
--- came from: rows in them are only ever as right as the code that
--- derived them.
local analysis_tables: {string} = {
  "parsed", "requires", "tests", "catalog", "docs", "refs", "examples",
}

--- The identity of the analyzer that is running: the compiler, and the
--- source of every one of `importer.analyzer_modules` as the running
--- binary carries it -- the code actually deriving, which in a stale
--- tool rebuilding itself is older than the tree's. A binary that
--- carries no source for one of them, or no record of what they import,
--- can only be named whole.
local function analyzer_identity(): string
  local parts: {string} = { Store.meta("compiler") or "" }
  local modules, _ = importer.analyzer_modules()
  if modules == nil then
    return "binary " .. (Store.meta("boot_hash") or "")
  end
  for _, name in ipairs(modules) do
    local source, _ = Store.source(name)
    if source == nil then
      return "binary " .. (Store.meta("boot_hash") or "")
    end
    parts[#parts + 1] = name .. "\n" .. source
  end
  return Hash.hex_sha256(table.concat(parts, "\n\0\n"))
end

--- Forgets every derived row when the code that derives them has
--- changed since they were made. A row keyed by its source's hash is
--- found again for as long as that source stands, which is right only
--- while the analyzer stands too: an extractor that learns to see
--- something new, or a generator that emits differently, must see
--- every source again. The analyzer is named by the code that is
--- running it (`analyzer_identity`), not by the tree: a stale tool
--- rebuilding itself derives and parses with its own, older code before
--- the new tool re-enters, and must not leave rows the new tool takes
--- for its own. Only a change to that code reparses everything; an edit
--- anywhere else in the tool reparses just what it edited.
local function forget_stale_analysis(db: Sqlite.Handle): boolean, string
  local identity = analyzer_identity()
  local last, last_trouble = Sqlite.text_rows(db,
    "SELECT value FROM meta WHERE key = 'analyzer'")
  if last == nil then
    return false, last_trouble
  end
  if #last > 0 and last[1][1] == identity then
    return true, ""
  end
  for _, table_name in ipairs(analysis_tables) do
    local ok, trouble = db:exec("DELETE FROM " .. table_name)
    if not ok then
      return false, trouble
    end
  end
  local swept, sweep_trouble = db:exec("DELETE FROM derived WHERE origin <> 'vendor'")
  if not swept then
    return false, sweep_trouble
  end
  return Sqlite.run(db,
    "INSERT OR REPLACE INTO meta (key, value) VALUES ('analyzer', ?1)",
    { text(identity) })
end

--- The identity of the code that finds `typed_refs` and checks the
--- error-slot discipline beside the compiler: `build.receivers` and
--- `build.contracts` as the running binary carries them, or the binary whole when it
--- carries none. Named apart from `analyzer_identity` because its rows
--- ride on compiles, which only a change to this code must redo.
local function receivers_identity(): string
  local parts: {string} = {}
  for _, name in ipairs({ "build.receivers", "build.contracts" }) do
    local source, _ = Store.source(name)
    if source == nil then
      return "binary " .. (Store.meta("boot_hash") or "")
    end
    parts[#parts + 1] = source
  end
  return Hash.hex_sha256(table.concat(parts, "\n\0\n"))
end

--- Forgets every compile, and the record-field uses found with it,
--- when the code that finds those uses has changed since: a compile
--- whose key stands is never checked again, so a `typed_refs` row is
--- only as right as the `build.receivers` that ran beside the checker.
local function forget_stale_receivers(db: Sqlite.Handle): boolean, string
  local identity = receivers_identity()
  local last, last_trouble = Sqlite.text_rows(db,
    "SELECT value FROM meta WHERE key = 'receivers'")
  if last == nil then
    return false, last_trouble
  end
  if #last > 0 and last[1][1] == identity then
    return true, ""
  end
  for _, statement in ipairs({ "DELETE FROM compiled", "DELETE FROM typed_refs" }) do
    local ok, trouble = db:exec(statement)
    if not ok then
      return false, trouble
    end
  end
  return Sqlite.run(db,
    "INSERT OR REPLACE INTO meta (key, value) VALUES ('receivers', ?1)",
    { text(identity) })
end

--- Brings `derived` and the parse tables up to the staged tree, inside
--- the run's transaction: a derived row whose file changed or vanished goes, and
--- only what is new is extracted, generated, or parsed. The compiler's
--- row has no file and is Lua, so it is neither dropped nor parsed
--- here; the plan carries it. What no input refers to any more is dropped, so the tables
--- describe this tree and nothing older. `compile` does this itself;
--- a caller that reads the tree's identities before compiling calls it
--- first, since `work.identities` closes over `requires`, and a fresh
--- working database has none until the tree is parsed.
--- @param self_tree whether the tree is cosmic's own, where the
---   `cosmic.` namespace is not reserved against the tree itself
--- @param built the compiler, loaded and ready
function importer.derive(handle: work.Handle, self_tree: boolean,
                         built: compiler): boolean, string
  local db = handle.db
  if not self_tree then
    local reserved, reserved_trouble = Fs.is_dir(handle.root .. "/cosmic")
    if reserved == nil then
      return false, reserved_trouble
    end
    if reserved then
      return false, "cosmic: the 'cosmic' directory is reserved to cosmic's own tree"
    end
    local claimed, trouble = Sqlite.text_rows(db,
      "SELECT path FROM files WHERE path GLOB 'cosmic/*' ORDER BY path LIMIT 1")
    if claimed == nil then
      return false, trouble
    end
    if #claimed > 0 then
      return false, claimed[1][1] .. ": the 'cosmic' directory is reserved to " ..
        "cosmic's own tree"
    end
  end

  local forgotten, forget_trouble = forget_stale_analysis(db)
  if not forgotten then
    return false, forget_trouble
  end

  local swept, sweep_trouble = db:exec(
    "DELETE FROM derived WHERE origin <> 'vendor' AND NOT EXISTS " ..
    "(SELECT 1 FROM files f WHERE f.path = derived.file " ..
    "AND f.sha256 = derived.from_hash)")
  if not swept then
    return false, sweep_trouble
  end
  local steps = { derive_doc_guides, derive_syscalls, duplicate_import_paths }
  for _, step in ipairs(steps) do
    local ok, trouble = step(db)
    if not ok then
      return false, trouble
    end
  end
  local parsed, parse_trouble = parse_new(db, built)
  if not parsed then
    return false, parse_trouble
  end
  for _, table_name in ipairs(analysis_tables) do
    local ok, trouble = db:exec("DELETE FROM " .. table_name ..
      " WHERE source_hash NOT IN (SELECT source_hash FROM inputs)")
    if not ok then
      return false, trouble
    end
  end
  return true, ""
end

--- Every name a table keyed by source hash lists, in order, by hash.
local function names_by_hash(db: Sqlite.Handle,
                             table_name: string): {string:{string}} | nil, string
  local rows, trouble = Sqlite.text_rows(db,
    "SELECT source_hash, name FROM " .. table_name ..
    " ORDER BY source_hash, ordinal")
  if rows == nil then
    return nil, trouble
  end
  local out: {string:{string}} = {}
  for _, row in ipairs(rows) do
    local list = out[row[1]]
    if list == nil then
      list = {}
      out[row[1]] = list
    end
    list[#list + 1] = row[2]
  end
  return out
end

local record Dependency
  kind: string
  source_hash: string
  requires: {string}
end

--- The identity of every source the checker can load from this tree.
--- A declaration wins over a source of the same name, just as
--- `build.teal`'s module search does. Embedded standard-library sources
--- are content-addressed when a project imports them.
local function dependency_keys(db: Sqlite.Handle, modules: {Module},
                               built: compiler,
                               tool: string): {string:string} | nil, string
  local requires, requires_trouble = names_by_hash(db, "requires")
  if requires == nil then
    return nil, requires_trouble
  end
  local dependencies: {string:Dependency} = {}
  local rows, rows_trouble = Sqlite.text_rows(db,
    "SELECT path, kind, source_hash FROM inputs WHERE kind <> 'vendor' " ..
    "ORDER BY path, kind = 'decl' DESC")
  if rows == nil then
    return nil, rows_trouble
  end
  for _, row in ipairs(rows) do
    if dependencies[row[1]] == nil then
      dependencies[row[1]] = {
        kind = row[2], source_hash = row[3],
        requires = requires[row[3]] or {},
      }
    end
  end
  -- A module's own compile is keyed from its implementation. Imports of
  -- that same path still resolve through `dependencies`, and therefore
  -- through its declaration when it has one.
  for _, m in ipairs(modules) do
    dependencies["\0" .. m.path] = {
      kind = m.kind, source_hash = m.source_hash, requires = m.requires,
    }
  end

  local resolve = function(slot: string, name: string): Dependency | nil, string
    local dependency = dependencies[slot]
    if dependency == nil then
      if name:sub(1, 7) ~= "cosmic." then
        return nil, ""
      end
      local source, source_trouble = Store.source(name)
      if source == nil then
        return nil, source_trouble
      end
      local parsed, parse_trouble = ast.parse(built, source, name)
      if parsed == nil then
        return nil, parse_trouble
      end
      local embedded_requires, embedded_requires_trouble =
        ast.all_requires(built, parsed)
      if embedded_requires == nil then
        return nil, embedded_requires_trouble
      end
      dependency = {
        kind = "embedded", source_hash = Hash.hex_sha256(source),
        requires = embedded_requires,
      }
      dependencies[slot] = dependency
    end
    return dependency, ""
  end

  -- Hash the reachable graph as a sorted set rather than recursively
  -- hashing one node into another. Declarations can legally refer to each
  -- other, and a set closes over those cycles without making traversal
  -- order part of the key. When a declaration shadows an implementation,
  -- both matter: the checker reads the declaration, while the generated
  -- `require` loads the implementation at runtime.
  local identify = function(name: string): string | nil, string
    local seen: {string:boolean} = {}
    local graph: {string} = {}
    local visit: function(string, string): boolean, string
    visit = function(slot: string, display: string): boolean, string
      if seen[slot] then
        return true, ""
      end
      local dependency, resolve_trouble = resolve(slot, display)
      if dependency == nil then
        if resolve_trouble ~= "" then return false, resolve_trouble end
        return true, ""
      end
      seen[slot] = true
      graph[#graph + 1] = slot .. "\n" .. dependency.kind .. "\n" ..
        dependency.source_hash
      for _, required in ipairs(dependency.requires) do
        local child, child_trouble = resolve(required, required)
        if child == nil and child_trouble ~= "" then
          return false, child_trouble
        end
        if child ~= nil then
          graph[#graph + 1] = slot .. "\nrequires\n" .. required
          local ok, trouble = visit(required, required)
          if not ok then
            return false, trouble
          end
          if child.kind == "decl" and dependencies["\0" .. required] ~= nil then
            graph[#graph + 1] = slot .. "\nloads\n" .. required
            ok, trouble = visit("\0" .. required, required)
            if not ok then
              return false, trouble
            end
          end
        end
      end
      return true, ""
    end
    local ok, trouble = visit("\0" .. name, name)
    if not ok then
      return nil, trouble
    end
    table.sort(graph)
    return Hash.hex_sha256(table.concat(graph, "\n\0\n") .. "\n" .. tool), ""
  end

  local out: {string:string} = {}
  for _, m in ipairs(modules) do
    local key, trouble = identify(m.path)
    if key == nil then
      return nil, trouble
    end
    out[m.path] = key
  end
  return out, ""
end

--- Every module the derived tree holds, with what its parse found.
local function collect(handle: work.Handle, self_tree: boolean,
                       built: compiler): {Module} | nil, string
  local derived, derive_trouble = importer.derive(handle, self_tree, built)
  if not derived then
    return nil, derive_trouble
  end
  local db = handle.db
  local rows, trouble = Sqlite.text_rows(db,
    "SELECT i.path, i.file, i.kind, i.origin, i.source, i.source_hash, " ..
    "p.has_return FROM inputs i JOIN parsed p ON p.source_hash = i.source_hash " ..
    "WHERE i.kind NOT IN ('decl', 'vendor') ORDER BY i.path")
  if rows == nil then
    return nil, trouble
  end
  local requires, requires_trouble = names_by_hash(db, "requires")
  if requires == nil then
    return nil, requires_trouble
  end
  local tests, tests_trouble = names_by_hash(db, "tests")
  if tests == nil then
    return nil, tests_trouble
  end
  local examples, examples_trouble = names_by_hash(db, "examples")
  if examples == nil then
    return nil, examples_trouble
  end
  local out: {Module} = {}
  for _, row in ipairs(rows) do
    local path, file, kind, origin = row[1], row[2], row[3], row[4]
    local source, source_hash, has_return = row[5], row[6], row[7]
    out[#out + 1] = {
      path = path,
      file = file,
      kind = kind,
      source = source,
      source_hash = source_hash,
      requires = requires[source_hash] or {},
      tests = kind == "test" and (tests[source_hash] or {})
        or kind == "example" and (examples[source_hash] or {})
        or {},
      has_top_level_return = has_return == "1",
      generated = origin == "doctest",
      key = "",
      lua = "",
    }
  end
  return out
end

--- The modules in an order where nothing is compiled before what it
--- imports. A cycle is reported rather than looped on.
local function ordered(modules: {Module}): {Module} | nil, string
  local by_path: {string:Module} = {}
  for _, m in ipairs(modules) do
    by_path[m.path] = m
  end

  local out: {Module} = {}
  local state: {string:string} = {}

  local visit: function(Module): boolean, string
  visit = function(m: Module): boolean, string
    if state[m.path] == "done" then
      return true, ""
    end
    if state[m.path] == "visiting" then
      return false, "a cycle of imports reaches " .. m.path
    end
    state[m.path] = "visiting"
    for _, name in ipairs(m.requires) do
      local other = by_path[name]
      if other ~= nil then
        local ok, trouble = visit(other)
        if not ok then
          return false, trouble
        end
      end
    end
    state[m.path] = "done"
    out[#out + 1] = m
    return true, ""
  end

  for _, m in ipairs(modules) do
    local ok, trouble = visit(m)
    if not ok then
      return nil, trouble
    end
  end
  return out
end

--- Appends a generated `return` to compiled Lua for a test module, so a
--- `local function test_*` -- otherwise unreachable from outside the
--- file it is declared in -- comes back on the table `require` gives
--- the runner. The Teal source the test's author wrote is never
--- touched; only the compiled Lua this module already owns is.
local function with_test_tail(code: string, tests: {string}): string
  if #tests == 0 then
    return code
  end
  local fields: {string} = {}
  for _, name in ipairs(tests) do
    fields[#fields + 1] = name .. " = " .. name
  end
  return code .. "\nreturn { " .. table.concat(fields, ", ") .. " }\n"
end

--- A `local function test_*` at a test module's top level is only ever
--- called by the runner, from outside the file, so the checker's
--- "unused function" warning about it is a false positive: it is
--- narrow enough to name the exact function discovery already found,
--- rather than turning the warning off for the whole file.
local function discount_test_warnings(result: compiler.Result,
                                      tests: {string}): compiler.Result
  local names: {string:boolean} = {}
  for _, name in ipairs(tests) do
    names[name] = true
  end
  local kept: {compiler.Error} = {}
  for _, w in ipairs(result.warnings) do
    local unused = w.msg:match("^unused function ([%w_]+):")
    if unused == nil or not names[unused] then
      kept[#kept + 1] = w
    end
  end
  result.warnings = kept
  return result
end

--- The one warning tl's checker always raises over a `build.doctest`
--- generated module: a generated example that declares an `output`
--- block shadows the global `print` with a local of the same name, on
--- purpose, so a doc's own verbatim `print(...)` calls run against the
--- capturing one instead -- print is declared `<const>` in tl's own
--- prelude, so reassigning the global outright is a hard type error,
--- and a local is the only way left to intercept a call the doc's own
--- source spells as a bare, unqualified `print`. This is narrower than
--- `discount_test_warnings` above in what it drops, but wider in who it
--- applies to: any module `m.generated` marks, not only the specific
--- function names a scan of `m` already found.
local function discount_doctest_shadow_warnings(result: compiler.Result): compiler.Result
  local kept: {compiler.Error} = {}
  for _, w in ipairs(result.warnings) do
    if w.msg ~= "variable shadows previous declaration of 'print'" then
      kept[#kept + 1] = w
    end
  end
  result.warnings = kept
  return result
end

--- Whether `m`'s own source both defines tests of its own and returns
--- its own value at the top level. `with_test_tail` appends a generated
--- `return` after the module's compiled Lua, and Lua allows only one
--- `return` as a block's last statement, so the two together always
--- produce a parse error the moment both are true. `collect` already
--- read both facts off one parse of `m.source`, so this only reads
--- what `m` itself carries -- never a second parse of the same source.
local function collides_with_test_tail(m: Module): boolean
  return #m.tests > 0 and m.has_top_level_return
end

--- Whether an example module found `Example.<name>` functions but has
--- no top-level `return` to hand any of them back: unlike a test
--- module, an example module gets no generated tail, since its own
--- `return Example` is what the runner and `cosmic docs` both need
--- reachable from outside the file -- see `analyzer.ExampleEntry`.
--- Caught here, at compile time, rather than left to fail the moment
--- the runner indexes a table that `require` handed back as `true`.
local function missing_example_return(m: Module): boolean
  return #m.tests > 0 and not m.has_top_level_return
end

--- tl's own checker (`tl.lua`'s `var_name:sub(1, 1) == "_"` check)
--- already treats a name starting with `_` as intentionally unused and
--- never warns about it -- but says so nowhere in the warning it raises
--- for every other name, and every warning is a refused compile on
--- cosmic's paths (see `generate`), so a fresh agent hits this as a
--- hard build failure with no hint of the one-character fix. Appended
--- once, at the one place every message is rendered, rather than
--- patching the vendored checker's own text.
local function with_unused_hint(msg: string): string
  if msg:match("^unused variable ") or msg:match("^unused argument ") then
    return msg .. " -- name it _ or _<name> to mark it intentionally unused"
  end
  return msg
end

--- The bare name tl's checker names in a message reporting that
--- nothing by that name exists: "unknown variable: NAME" (a global
--- reference -- `os.time()`, once `build.teal` strips `os` from the
--- checker's own environment for exactly this) or "module not found:
--- 'NAME'" (a `require` of a literal string nothing provides). `nil`
--- for any other message, since only these two name a single missing
--- word worth looking up.
local function unresolved_name(msg: string): string
  return msg:match("^unknown variable: (.+)$") or
    msg:match("^module not found: '(.+)'$")
end

--- Appends a pointer at whatever `cosmic docs` already answers for the
--- name a resolution failure names, when `symbols.named` finds it
--- exactly -- the same rule `cosmic docs <word>` itself matches by, so
--- this can never point somewhere that command would disagree with.
--- Only the symbol's name, never its documentation: the error already
--- says where to read that in full (`cosmic docs <name>`), and a
--- compile failure is not the place to reprint it.
local function with_docs_hint(msg: string, databases: {Sqlite.Handle},
                              public: {boolean}): string
  local name = unresolved_name(msg)
  if name == nil then
    return msg
  end
  local found = symbols.named(databases, public, name)
  if #found == 0 then
    return msg
  end
  return msg .. " -- see also in docs: " .. table.concat(found, ", ")
end

--- Checker forms that reliably identify a language topic. Argument failures
--- point to the general checked function-contract guide; a diagnostic does
--- not carry enough AST binding information here to claim a particular call.
local function diagnostic_docs(msg: string): string | nil
  if msg:match("^wrong number of arguments %(") or
      msg:match("^argument %d+: got .+, expected ") then
    return "generics_functions_returns"
  elseif msg:match("^invalid key '.-' in record ") then
    return "records_interfaces_methods"
  elseif msg:match("^cannot use operator '.-' for types ") and
      msg:find(" | ", 1, true) ~= nil then
    return "unions_narrowing_casts"
  end
  return nil
end

local function with_diagnostic_docs(msg: string, databases: {Sqlite.Handle},
                                    public: {boolean}): string
  local query = diagnostic_docs(msg)
  if query == nil or not symbols.has_example_query(databases, public, query) then
    return msg
  end
  return msg .. " -- see also: cosmic docs " .. query
end

--- Every hint a checker message earns, appended once, at the one place
--- every message is rendered, rather than patched into the vendored
--- checker's own text or duplicated at each call site.
local function with_hint(msg: string, databases: {Sqlite.Handle},
                         public: {boolean}): string
  return with_diagnostic_docs(
    with_docs_hint(with_unused_hint(msg), databases, public), databases, public)
end

--- `file`'s own complaints, one line each. A removed name's replacement
--- (`teal.replacement`) comes straight after the checker's own words,
--- ahead of any pointer at the docs: it is the answer, they are more.
local function complain(file: string, source: string, result: compiler.Result,
                        databases: {Sqlite.Handle}, public: {boolean}): string
  local lines: {string} = {}
  for _, group in ipairs({ result.syntax_errors, result.type_errors, result.warnings }) do
    for _, e in ipairs(group or {}) do
      local where = e.filename ~= "" and e.filename or file
      local said = with_hint(e.msg, databases, public)
      local instead = where == file and teal.replacement(e.msg, source, e.y, e.x) or nil
      if instead ~= nil then
        said = e.msg .. " -- " .. instead .. said:sub(#e.msg + 1)
      end
      lines[#lines + 1] = where .. ":" .. e.y .. ":" .. e.x .. ": " .. said
    end
  end
  return table.concat(lines, "\n")
end

--- The statements one compile pass runs, prepared once each.
local record Cache
  run: integer
  tool: string
  --- Whether this run refuses a module `build.contracts` refuses,
  --- rather than keeping its compile for this run's own database only
  --- (see `importer.compile`'s `unjudged`).
  judged: boolean
  look: Sqlite.Statement
  put: Sqlite.Statement
  plan: Sqlite.Statement
end

local function prepare_cache(handle: work.Handle, tool: string,
                             judged: boolean): Cache | nil, string
  local db = handle.db
  -- A compile build.contracts refused, kept anyway by an unjudged run,
  -- is marked seen -1 and never reused: the next run compiles and
  -- judges the module again.
  local look, look_trouble = db:prepare(
    "UPDATE compiled SET seen = ?2 WHERE key = ?1 AND seen >= 0 RETURNING lua")
  if look == nil then
    return nil, look_trouble
  end
  local put, put_trouble = db:prepare(
    "INSERT OR REPLACE INTO compiled (key, tool, lua, bytecode, seen) " ..
    "VALUES (?1, ?2, ?3, ?4, ?5)")
  if put == nil then
    look:finalize()
    return nil, put_trouble
  end
  local plan, plan_trouble = db:prepare(
    "INSERT INTO plan (path, key, ordinal) VALUES (?1, ?2, ?3)")
  if plan == nil then
    look:finalize()
    put:finalize()
    return nil, plan_trouble
  end
  return { run = handle.run, tool = tool, judged = judged, look = look, put = put,
           plan = plan }
end

local function finish_cache(cache: Cache)
  cache.look:finalize()
  cache.put:finalize()
  cache.plan:finalize()
end

--- How many runs a compile stays cached after the last one that used
--- it.
local kept_runs = 100

local once = bind.once

--- The cached Lua under `key`, marked as used by this run, or nil
--- when nothing is cached there.
local function cached_lua(cache: Cache, key: string): string | nil, string
  local look = cache.look
  local bound, bind_trouble = look:bind_text(1, key)
  if bound then bound, bind_trouble = look:bind_integer(2, cache.run) end
  if not bound then
    return nil, bind_trouble
  end
  local state, trouble = look:step()
  if state == nil then
    return nil, trouble
  end
  local lua: string | nil = nil
  if state == "row" then
    lua = look:bytes(0)
  end
  local reset, reset_trouble = look:reset()
  if not reset then
    return nil, reset_trouble
  end
  return lua, ""
end

--- Bytecode for compiled Lua, checked to be the shape every target
--- shares.
local function bytecode_of(code: string, name: string,
                           file: string): string | nil, string
  local chunk, load_trouble = load(code, "@" .. name, "t")
  if chunk == nil then
    return nil, file .. ": " .. tostring(load_trouble)
  end
  local bytecode = string.dump(chunk, false)
  if bytecode:sub(1, #bytecode_header) ~= bytecode_header then
    return nil, file .. ": this host dumps bytecode the three " ..
      "targets do not share"
  end
  return bytecode
end

--- Puts one compile in the cache under its key, and the module in
--- this run's plan. A `refused` compile is kept for this run alone.
local function remember(cache: Cache, path: string, key: string, ordinal: integer,
                        lua: string | nil, bytecode: string | nil,
                        refused: boolean): boolean, string
  if lua ~= nil and bytecode ~= nil then
    local put = cache.put
    local bound, bind_trouble = put:bind_text(1, key)
    if bound then bound, bind_trouble = put:bind_text(2, cache.tool) end
    if bound then bound, bind_trouble = put:bind_text(3, lua) end
    if bound then bound, bind_trouble = put:bind_blob(4, bytecode) end
    if bound then bound, bind_trouble = put:bind_integer(5, refused and -1 or cache.run) end
    if not bound then
      return false, bind_trouble
    end
    local kept, put_trouble = once(put)
    if not kept then
      return false, put_trouble
    end
  end
  local plan = cache.plan
  local bound, bind_trouble = plan:bind_text(1, path)
  if bound then bound, bind_trouble = plan:bind_text(2, key) end
  if bound then bound, bind_trouble = plan:bind_integer(3, ordinal) end
  if not bound then
    return false, bind_trouble
  end
  return once(plan)
end

--- Compiles one module: the checker over its source, the test tail
--- when it is a test, and the bytecode.
local record Generated
  lua: string
  bytecode: string
  --- The record-field uses the checker's types resolved -- see
  --- `build.receivers`.
  references: {receivers.Reference}
  --- Whether `build.contracts` refused the module, and the compile was
  --- kept anyway for an unjudged run.
  refused: boolean
end

local function generate(m: Module, built: compiler, env: compiler.Env,
                        typed: receivers.State, own_tree: boolean, judged: boolean,
                        databases: {Sqlite.Handle},
                        public: {boolean}): Generated | nil, string
  local code, result = built.gen(m.source, env, nil, "tl")
  if m.kind == "test" and result ~= nil then
    result = discount_test_warnings(result, m.tests)
  end
  if m.generated and result ~= nil then
    result = discount_doctest_shadow_warnings(result)
  end
  local complaint = result ~= nil and complain(m.file, m.source, result, databases, public) or ""
  if code == nil or complaint ~= "" then
    return nil, m.file .. ": the compiler refused it\n" .. complaint
  end
  -- The checker has just seen this module whole; a module compiled
  -- after it that requires it is checked against that, rather than
  -- against a second read and check of the same source.
  env.modules[m.path] = result.type
  local checked = result.ast
  if not (checked is ast.Node) then
    return nil, m.file .. ": the compiler answered no syntax tree"
  end
  local refused = false
  if own_tree and contracts.applies(m.kind, m.generated) then
    local problems = contracts.check(m.file, checked, typed, contracts.quiet_records(env),
      contracts.binding_tables(env), nil, result.type)
    if #problems > 0 and judged then
      return nil, table.concat(problems, "\n")
    end
    refused = #problems > 0
  end
  local references = receivers.references(typed, env, checked)
  if m.kind == "test" then
    code = with_test_tail(code, m.tests)
  end
  local bytecode, dump_trouble = bytecode_of(code, m.path, m.file)
  if bytecode == nil then
    return nil, dump_trouble
  end
  return { lua = code, bytecode = bytecode, references = references, refused = refused }, ""
end

--- The record-field uses one compile found, kept under its key beside
--- the compile itself, replacing whatever an earlier compile under the
--- same key left.
local function keep_references(db: Sqlite.Handle, key: string,
                               references: {receivers.Reference}): boolean, string
  local ok, why = Sqlite.run(db, "DELETE FROM typed_refs WHERE key = ?1", { text(key) })
  if not ok then
    return false, why
  end
  for ordinal, entry in ipairs(references) do
    ok, why = Sqlite.run(db,
      "INSERT INTO typed_refs (key, ordinal, module, member, line) " ..
      "VALUES (?1, ?2, ?3, ?4, ?5)",
      { text(key), { integer = ordinal }, text(entry.module), text(entry.member),
        { integer = entry.line } })
    if not ok then
      return false, why
    end
  end
  return true, ""
end

--- The vendored compiler, planned and cached like any module: its Lua
--- is its source, so only the bytecode is made, and only once per
--- compiler identity. Nothing to do when the working database holds no compiler,
--- as a project's does not.
local function plan_compiler(handle: work.Handle, cache: Cache,
                             tool: string, ordinal: integer): boolean, string
  local rows, trouble = Sqlite.text_rows(handle.db,
    "SELECT source FROM inputs WHERE kind = 'vendor'")
  if rows == nil then
    return false, trouble
  end
  if #rows == 0 then
    return true, ""
  end
  local source = rows[1][1]
  local key = Hash.hex_sha256(source .. "\n" .. tool)
  local lua, look_trouble = cached_lua(cache, key)
  if lua ~= nil then
    return remember(cache, "vendor.tl", key, ordinal, nil, nil, false)
  end
  if look_trouble ~= "" then
    return false, look_trouble
  end
  local chunk, load_trouble = load(source, "@vendor.tl", "t")
  if chunk == nil then
    return false, "the vendored compiler would not load: " .. tostring(load_trouble)
  end
  return remember(cache, "vendor.tl", key, ordinal, source,
    string.dump(chunk, false), false)
end

--- Compiles every module, in import order, into Lua and bytecode --
--- or finds it already compiled under the same key. The keys and the
--- compiles land in the working database inside the run's
--- transaction, kept even when a later module refuses, so a run that
--- fails still pays for each module once; a compile another tool
--- made, or one no run has used lately, is dropped.
---
--- The checker's environment (`build.teal`'s `environment_for`) is made
--- on first use, right before the first module that actually needs one
--- to compile, rather than up front: `new_env` parses and type-checks
--- tl's own prelude and stdlib declarations, so a build that finds
--- every module already cached never pays for it.
--- @param handle the working database the tree is staged in
--- @param built the compiler, loaded and ready
--- @param tool the identity of the compiler doing the compiling, which
---   every key carries
--- @param unjudged whether a module `build.contracts` refuses is kept
---   rather than refused: a stale tool rebuilding itself (`build.reboot`)
---   judges the tree by its own, older rules and exemptions, so it
---   leaves the last word to the tool it builds, which re-enters the
---   command. A compile the old rules refuse is kept only for this run's
---   database, never reused, so the next run compiles and judges the
---   module again; one they pass is cached as any other, since a change
---   to the rules themselves forgets every compile (`forget_stale_receivers`).
function importer.compile(handle: work.Handle, built: compiler,
                          tool: string, unjudged?: boolean): importer.Result | nil, string
  local own_tree, own_trouble = tree.is_own(handle.root)
  if own_tree == nil then return nil, own_trouble end
  local modules, trouble = collect(handle, own_tree, built)
  if modules == nil then
    return nil, trouble
  end
  local positioned, position_trouble = positions.check(modules, own_tree)
  if not positioned then
    return nil, position_trouble
  end
  local order, why = ordered(modules)
  if order == nil then
    return nil, why
  end
  local keys, keys_trouble = dependency_keys(handle.db, modules, built, tool)
  if keys == nil then
    return nil, keys_trouble
  end
  local result: importer.Result = {
    modules = {}, tool = tool, main = nil, refused = {},
    compiled = 0, cached = 0,
  }
  local db = handle.db
  local failure = ""
  -- Made on first use, by whichever module first fails to find a
  -- cached compile below: a run that compiles nothing never pays for
  -- `new_env`'s parse and type-check of tl's own prelude and stdlib.
  local env: compiler.Env | nil = nil
  local typed: receivers.State | nil = nil

  -- Where a refused module's own hint (`with_docs_hint`) looks up the
  -- name it could not resolve: this build's own working database
  -- first -- unrestricted, the way a project's own `o/cosmic.db` is
  -- for `cosmic docs` too -- then the running binary's own, which is
  -- where a stdlib symbol like `cosmic.removed`'s own fields actually
  -- live for any tree but cosmic's -- see `docs.databases`, the same
  -- shape built for the same reason.
  local hint_databases: {Sqlite.Handle} = { db }
  local hint_public: {boolean} = { false }
  for _, store_db in ipairs(Store.databases()) do
    hint_databases[#hint_databases + 1] = store_db
    hint_public[#hint_public + 1] = not own_tree
  end

  local compile_all = function(): boolean, string
    local cleared, clear_trouble = db:exec("DELETE FROM plan")
    if not cleared then
      return false, clear_trouble
    end
    local forgotten, forget_trouble = forget_stale_receivers(db)
    if not forgotten then
      return false, forget_trouble
    end
    local judged = not unjudged
    local cache, prepare_trouble = prepare_cache(handle, tool, judged)
    if cache == nil then
      return false, prepare_trouble
    end

    for ordinal, m in ipairs(order) do
      m.key = keys[m.path]

      if m.kind == "test" and collides_with_test_tail(m) then
        -- Refused on its own, narrowly: every other module still
        -- compiles below, unaffected. Compiling this one anyway would
        -- only surface as `<eof> expected near 'return'` once
        -- `with_test_tail` appends its own generated return after this
        -- file's, a Lua parse error naming neither the file nor the
        -- cause.
        result.refused[#result.refused + 1] = m.file .. ": a test file may not both " ..
          "define test_* functions and return its own value; remove the " ..
          "top-level return so the generated tail can hand the runner " ..
          "its tests"
      elseif m.kind == "example" and missing_example_return(m) then
        result.refused[#result.refused + 1] = m.file .. ": an example file " ..
          "must return the table its Example.* functions are declared on " ..
          "(`return Example`), or the runner has nothing to call"
      else
        local lua, look_trouble = cached_lua(cache, m.key)
        if lua == nil and look_trouble ~= "" then
          finish_cache(cache)
          return false, look_trouble
        end
        local bytecode: string | nil = nil
        local refused = false
        if lua ~= nil then
          result.cached = result.cached + 1
        else
          if env == nil then
            local made_env, env_trouble = teal.environment_for(built, handle)
            if made_env == nil then
              failure = env_trouble
              break
            end
            env = made_env
            typed = receivers.install(made_env)
          end
          local generated, generate_trouble =
            generate(m, built, env, assert(typed), own_tree, judged, hint_databases,
              hint_public)
          if generated == nil then
            failure = generate_trouble
            break
          end
          lua = generated.lua
          bytecode = generated.bytecode
          refused = generated.refused
          result.compiled = result.compiled + 1
          local kept_refs, refs_trouble = keep_references(db, m.key,
            generated.references)
          if not kept_refs then
            finish_cache(cache)
            return false, m.file .. ": " .. refs_trouble
          end
        end
        m.lua = lua
        local kept, keep_trouble = remember(cache, m.path, m.key, ordinal, lua,
          bytecode, refused)
        if not kept then
          finish_cache(cache)
          return false, m.file .. ": " .. keep_trouble
        end
        if m.kind == "main" then
          result.main = m.path
        end
        result.modules[#result.modules + 1] = m
      end
    end

    if failure == "" then
      local planned, plan_trouble = plan_compiler(handle, cache, tool,
        #order + 1)
      if not planned then
        finish_cache(cache)
        return false, plan_trouble
      end
    end
    finish_cache(cache)
    local pruned, prune_trouble = Sqlite.run(db,
      "DELETE FROM compiled WHERE tool <> ?1 OR (seen >= 0 AND seen < ?2)" ..
        (judged and " OR seen < 0" or ""),
      { text(tool), { integer = handle.run - kept_runs } })
    if not pruned then
      return false, prune_trouble
    end
    return db:exec("DELETE FROM typed_refs WHERE key NOT IN (SELECT key FROM compiled)")
  end
  local made, compile_trouble = compile_all()
  if not made then
    return nil, compile_trouble
  end
  if failure ~= "" then
    return nil, failure
  end
  return result
end

return importer
