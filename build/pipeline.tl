--- The build's compile with the new checker ([`build.grammar_mode`]): a module of the staged tree is read, checked against
--- its ceilings and written as Lua and bytecode by [`build.driver`] and [`lang.codegen`]. [`Pipeline.generate`] answers what
--- [`build.importer`] asks of a compile, and [`Pipeline.derive`] writes the rows of a parse.
---
--- THE PROGRAM is every module of the staged tree (the `inputs` of the working database), in the new grammar, set up as the
--- pins are measured ([`build.tree_program`]); the `cosmic.*` modules the tree does
--- not hold (a project's `require` of the standard library) are the binary's own, each its stub or its source, and the
--- bindings of C are typed from the declarations the build writes of the headers ([`cosmic.sys`], the raw process and socket
--- tables), the tree's or the binary's. The globals of every module are the declarations of the Lua standard library: in
--- cosmic's tree the files [`lang/prelude.d.tl`] and [`lang/stdlib.d.tl`], in a project the ones the tool carries
--- ([`build.checker_declarations`]).
---
--- A project written in a form only the fork read is refused with the new checker's words and fix
--- ([`build.error_catalog`], [`build.error_render`]).
---
--- A MODULE IS REFUSED for a count of errors above its ceiling ([`build.ceilings`]), for any warning, for a text that does
--- not parse and for a construct the generator does not write. The
--- ceilings are held by the tree's checks as they are here; the other refusals are listed in build.pipeline.residue.
---
--- A MODULE IS KEYED by the ceilings that hold it too ([`Pipeline.pinned`]), and the whole compile by the code that reads
--- ([`Pipeline.coded`]), so that a pin or an edit to the checker judges a module another run compiled again. The standard
--- library the module was checked against is in the compiler's identity ([`build.identity`]).
--
-- TODO: point to what `cosmic docs` answers for a name and to the worked example of a form in the lines of a warning, as
-- [`build.error_render`]'s `lines` does with the databases it is given, once [`Driver.Build`] answers the problems over their
-- ceilings and not only the lines that list them: the lines of an error carry the pointer ([`Pipeline.generate`]'s `hints`),
-- which the lines of a warning and of a text that does not parse do not.
local Ceilings = require("build.ceilings")
local CheckerDeclarations = require("build.checker_declarations")
local CompileGrammar = require("build.compile_grammar")
local Ast = require("lang.ast")
local Rules = require("build.contract_rules")
local Declarations = require("lang.declarations")
local Driver = require("build.driver")
local Memprobe = require("build.memprobe")
local ErrorCatalog = require("build.error_catalog")
local ErrorRender = require("build.error_render")
local Fs = require("cosmic.fs")
local GrammarMode = require("build.grammar_mode")
local Hash = require("cosmic.hash")
local LuaTail = require("build.lua_tail")
local Receivers = require("build.syntax_receivers")
local Report = require("build.syntax_report")
local Stub = require("build.syntax_stub")
local Sqlite = require("cosmic.sqlite")
local Store = require("cosmic.store")
local String = require("cosmic.string")
local SyntaxContracts = require("build.syntax_contracts")
local SyntaxDerivation = require("build.syntax_derivation")
local TreeProgram = require("build.tree_program")
local standard_text = require("build.standard_text")
local tree = require("build.tree")
local type Plans = require("build.plans")
local type Derivation = require("build.derivation")
local type Module = Plans.Module

local record Pipeline
  type Mode = GrammarMode.Mode

  --- The mode `COSMIC_GRAMMAR` asks for ([`GrammarMode.mode`]).
  mode: function(): Mode?, string

  --- The tool string a compile in `mode` is keyed by ([`GrammarMode.tool`]).
  tool: function(tool: string, mode: Mode, wraps?: boolean): string

  --- What a pipeline is made of besides the tree.
  record Options
    --- The standard library's declarations, which every module's globals are made of ([`build.tree_program`]).
    globals: TreeProgram.Globals
    --- The ceilings that hold the modules: none for a project outside cosmic's tree, whose every error refuses.
    ceilings: Ceilings.Table
    --- Whether the checker keeps the type of each node, which the readers of the type report need.
    types: boolean
    --- Answers the `cosmic.*` modules the tree does not hold, each its stub or its source: [`Pipeline.carried`] where
    --- not given.
    standard: Driver.Provider?
    --- Whether the tree is a project outside cosmic's own, whose checker is its own. Absent for cosmic's tree.
    project: boolean?
  end

  --- A build over the tree and its ceilings.
  record Built
    build: Driver.Build
    ceilings: Ceilings.Table
    --- The sources of the tree and the modules they answer to, which a build that reads the stub of a standard-library module
    --- in place of its source is made from.
    index: Driver.Index
    --- The declarations and the provider [`Pipeline.options`] gave, which that build is made with.
    globals: TreeProgram.Globals
    standard: Driver.Provider
    --- Whether the checker kept the type of each node, which the readers of the type report need.
    types: boolean
    --- The stubs a caller gave ([`Pipeline.over`]), by module: none for a build that makes them of what it reads.
    given: {string: string}
    --- The stub of each standard-library module of the tree that a project's checker would read in its place, as a source that
    --- stands for the module and its aliases, made when the first is judged.
    stubs: {string: Driver.Source}?
    --- The build that reads those stubs where it reads their sources, made when the first stub is judged.
    stubbed: Driver.Build?
  end

  --- The options for the tree at `root`: in cosmic's own tree the declarations and the ceilings it holds; in any other
  --- tree, a project's, the declarations of the standard library the tool carries ([`build.checker_declarations`]) and no
  --- ceiling, so that every error of the checker refuses. nil and why where the tree cannot be told, or the tool carries
  --- none of the declarations (a tool older than this one: boot it again).
  options: function(root: string): Options?, string

  --- The options for a project outside cosmic's tree, whose globals are the declarations `texts` ([`Pipeline.options`] gives
  --- the ones the tool carries): no ceilings, so every error of the checker refuses.
  project: function(texts: CheckerDeclarations.Texts): Options

  --- The options for a source that is no tree's (a lone file, a generated source): the declarations the tool carries
  --- ([`build.checker_declarations`]) and no ceilings. nil and why where the tool carries none.
  alone: function(): Options?, string

  --- The Lua of the source `text`, which is the file `file`, checked as a module of its own that requires only what the
  --- binary carries ([`Pipeline.carried`]) and written for `options`: nil and every line the checker refuses it for. A
  --- warning is a refusal. Nothing is pinned but that a lone file returns its entry point, which no declaration describes: the
  --- contracts, the test tail and the record-field uses are the tree's compile alone.
  lone: function(file: string, text: string, options: Options, tests?: boolean): string?, string

  --- The modules the source `text`, the file `file`, requires by a literal name, in the order they stand (a type-only require
  --- among them): the syntax tree of the new checker's parse of the text. nil and the refusal, in the checker's words,
  --- where the text does not parse.
  requires: function(file: string, text: string): {string}?, string

  --- What [`Pipeline.checked_alone`] made of a source: its Lua, or the lines that refuse it, one problem each.
  record Alone
    code: string?
    lines: {string}
  end

  --- [`Pipeline.lone`] with the refusal as a line for each problem, for a caller that lists them.
  checked_alone: function(file: string, text: string, options: Options, tests?: boolean): Alone

  --- The `cosmic.*` modules of the running binary, each its stub or its source ([`build.standard_text`]), a declaration
  --- ([`cosmic.sys`]) as one.
  carried: function(): Driver.Provider

  --- [`Pipeline.carried`] widened to every module of the running binary, the tool's own beside the standard library's
  --- ([`build.standard_text`]'s `own`): what `cosmic -e` types its chunk against.
  carried_own: function(): Driver.Provider

  --- A build over the modules of `entries`: pairs of a file and its text, with the module and the name the ceilings are kept
  --- under for a source written from another file ([`Driver.index`]). `kinds` says of each file what the working database
  --- says of its input (`test`, ...); a `test` has its functions called from outside. `stubs` gives the stub of a
  --- standard-library module, by module, which a build otherwise makes of what it read of it.
  over: function(entries: {{string}}, kinds: {string: string}, options: Options, stubs?: {string: string}): Built

  --- A build over the `inputs` of the working database `db`: the tree and what is written from it (the guides, the
  --- templates, the bindings of C).
  build: function(db: Sqlite.Handle, options: Options): Built?, string

  --- The Lua and the bytecode of the module `m`, checked and written by the new checker: nil and why where the module is refused. A module is refused for a count over its ceiling
  --- ([`Driver.Build.held`]), a warning, a call no rule of the discipline judged beyond its `[untyped]` ceiling, and the
  --- generator's own refusals; and the compile holds besides:
  --- a module of the error-slot discipline to it ([`build.syntax_contracts`]), a standard-library module to its stub
  --- ([`build.syntax_stub`]), and it finds the record-field uses `cosmic uses` lists ([`build.syntax_receivers`]). With
  --- `facts` each read of a place a test narrowed is wrapped in a check ([`lang.fact_wraps`]). Where `judged` is false (a
  --- stale tool rebuilding itself) a breach of the discipline or of the stub is kept and the compile marked `refused`. `built` must have kept the types ([`Pipeline.Options.types`]). The line of an error the docs answer for
  --- carries a pointer to them when `hints` is given (the databases to look in, as [`ErrorRender.Hints`]). The module is
  --- retired from the build when it is written ([`Driver.Build.retire`]), so a build writes a module once, and the caller
  --- asks for the modules in the order they require one another: the build then holds the declarations of the modules it has
  --- written and the syntax of the one it is writing. The collector is generational from the first module.
  generate: function(m: Module, built: Built, facts?: boolean, judged?: boolean, hints?: function(): {Sqlite.Handle}, {boolean}):
      Plans.Generated?, string

  --- [`Pipeline.generate`] for a build the caller keeps across edits of a module (`cosmic lsp`'s session): the module is
  --- checked and judged as it is there, and it is neither retired nor written as bytecode (nor are its record-field uses read), so the caller may put
  --- another text in its place ([`Driver.Build.replace`]) and ask again. The calls of [`Shape.record_of`] are resolved by the caller. The
  --- types the checker kept of the module are let go once read.
  review: function(m: Module, built: Built, hints?: ErrorRender.Hints): Plans.Generated?, string

  --- Takes from the scope errors of `result` the shadowing of `print` that every example of a guide makes ([`build.doctest`]
  --- captures what it prints in a local of that name), as the fork's compile discounts it: the module is generated, and the
  --- name is its own.
  discounted: function(result: Driver.Outcome)

  --- The tool string a compile in the new mode is keyed by, given the one the harness chose ([`GrammarMode.tool`]): that and the
  --- identity of the code that reads and checks a source in the new mode, which is the source, as the running binary carries it,
  --- of every module of the tree (`lang.*`, `build.*`) that [`build.pipeline`] reaches. A compile or a parse made with it is
  --- keyed by it, so that an edit to the checker or to a reader reads the tree again; the compiler's identity
  --- ([`build.identity`]) holds none of it, so a default run is not read again for it.
  coded: function(tool: string): string

  --- [`Pipeline.coded`] over the code the working database `db` stages, parsed, in place of the code the running binary
  --- carries: the identity of a boot, which runs the tree's own code under a bootstrap release that carries another. nil and
  --- why where the tree is not parsed.
  coded_of: function(tool: string, db: Sqlite.Handle): string?, string

  --- The digest of the ceilings that hold each file, by file, every stage together: the compile of a module is keyed by the
  --- one of its file, so that a pin that falls judges the module again. A file with no ceiling has none. A module written
  --- from another file (a guide, a template) is the file it is written from, which its ceilings are kept under.
  pinned: function(ceilings: Ceilings.Table): {string: string}

  --- Reads the sources `fresh` ([`build.derivation`]'s `fresh`) as written, and writes the rows of each ([`build.syntax_derivation`])
  --- into `db` beside the others. A source that does not parse is listed in `broken` when given and stops the derive
  --- otherwise, told in the words of the new checker ([`build.error_render`]).
  derive: function(db: Sqlite.Handle, fresh: {Derivation.Fresh}, tally: Derivation.Parses,
                   made: {Derivation.Source}, broken?: {Derivation.Broken}): boolean, string

  --- Writes a row for every code the new checker emits to the `catalog` table of `db` (of the schema `schema`, "" for the
  --- default), as [`ErrorCatalog.insert`] does.
  catalog: function(db: Sqlite.Handle, schema: string): integer?, string
end

Pipeline.mode = GrammarMode.mode
Pipeline.tool = GrammarMode.tool

--- Whether the stub of the module `module` of the file `file` is held to its source's type: a standard-library module that
--- the error-slot discipline covers.
local function judges_stub(file: string, module: string): boolean
  return SyntaxContracts.kind_of(file) == "module" and module:sub(1, 7) == "cosmic."
end

--- Why the stub `made` of a module does not stand for its source `source` (the module read by `built`), or "" where it does.
local function stub_verdict(made: Stub.Made, built: Driver.Build, source: Driver.Outcome, stubbed: Driver.Build): string
  if not made.pruned then
    return "its stub keeps every statement, so a project's checker would read and load all of it: a standard-library " ..
      "module must end by returning a name whose last top-level declaration spells its type"
  end
  local module = source.module
  local result = stubbed:result(module, true)
  if result == nil then
    return "its stub is not a module"
  end
  -- The stub may not add a refusal to the source's: a code it is refused for more often than the source is.
  local had: mut {string: integer} = {}
  for _, e in ipairs(source.errors) do
    had[e.code] = (had[e.code] or 0) + 1
  end
  local has: mut {string: integer} = {}
  for _, e in ipairs(result.errors) do
    local count = (has[e.code] or 0) + 1
    has[e.code] = count
    -- A body the stub leaves out is a function that returns nothing, and code after the `error()` that stands for a body
    -- that never returns is unreachable: the stub is the declarations, and not the bodies the fork read none of either.
    if count > (had[e.code] or 0) and e.code ~= "missing_return" and e.code ~= "unreachable" then
      return tostring(e.y) .. ":" .. tostring(e.x) .. ": " .. e.msg .. " (" .. e.code .. ")"
    end
  end
  local different = Stub.difference(built.program, stubbed.program, module)
  if different ~= nil then
    return "the stub a project's checker reads in its place types it differently from its source: " .. different
  end
  return ""
end

function Pipeline.project(texts: CheckerDeclarations.Texts): Pipeline.Options
  return {
    globals = TreeProgram.globals(texts.prelude, texts.stdlib),
    ceilings = { stages = {}, none = true }, types = true, standard = nil, project = true,
  }
end

function Pipeline.alone(): Pipeline.Options?, string
  local carried, why = CheckerDeclarations.carried()
  if carried == nil then
    return nil, "COSMIC_GRAMMAR=new: this tool carries no declarations of the standard library (" .. why ..
      "): boot the tree it was built from again (bin/zig build boot)"
  end
  return Pipeline.project(carried), ""
end

function Pipeline.options(root: string): Pipeline.Options?, string
  local own, own_why = tree.is_own(root)
  if own == nil then
    return nil, own_why
  end
  if not own then
    return Pipeline.alone()
  end
  local prelude, prelude_why = Fs.read(root .. "/" .. CheckerDeclarations.prelude_file())
  if prelude == nil then
    return nil, prelude_why
  end
  local stdlib, stdlib_why = Fs.read(root .. "/" .. CheckerDeclarations.stdlib_file())
  if stdlib == nil then
    return nil, stdlib_why
  end
  local ceilings, ceilings_why = Ceilings.read(root)
  if ceilings == nil then
    return nil, ceilings_why
  end
  return {
    globals = TreeProgram.globals(prelude, stdlib),
    ceilings = ceilings, types = true, standard = nil, project = nil,
  }, ""
end

--- Whether the binary holds the module `name` as a declaration.
local function declared(name: string): boolean
  local databases = Store.databases()
  local rows, _ = Sqlite.text_rows(databases[#databases], "SELECT 1 FROM decls WHERE path = ?1", { { text = name } })
  return rows ~= nil and #rows > 0
end

function Pipeline.carried(): Driver.Provider
  return Driver.standard(function(module: string): string?
    local found = standard_text.of(module)
    if found == nil then
      return nil
    end
    return found.text
  end, declared)
end

function Pipeline.carried_own(): Driver.Provider
  return Driver.standard(function(module: string): string?
    local found = standard_text.own(module)
    if found == nil then
      return nil
    end
    return found.text
  end, declared)
end

function Pipeline.over(entries: {{string}}, kinds: {string: string}, options: Pipeline.Options, stubs?: {string: string}):
    Pipeline.Built
  local index = TreeProgram.index(entries, kinds)
  local standard = options.standard or Pipeline.carried()
  return {
    build = TreeProgram.build(index, options.globals, options.types, nil, standard), ceilings = options.ceilings, index = index,
    globals = options.globals, standard = standard, types = options.types, given = stubs or {}, stubs = nil, stubbed = nil,
  }
end

--- What `inputs` of `db` stages for the new checker: the files and their text (the tree's own, and what is written from it),
--- and the kind of each ([`Pipeline.over`]).
local function entries_of(db: Sqlite.Handle): {{string}}?, {string: string}, string
  local rows, trouble = Sqlite.text_rows(db,
    "SELECT file, path, kind, origin, source FROM inputs WHERE kind <> 'vendor' ORDER BY file")
  if rows == nil then
    return nil, {}, trouble
  end
  local entries: mut {{string}} = {}
  local kinds: mut {string: string} = {}
  for _, row in ipairs(rows) do
    local file, path, kind, origin, source = row:text(1), row:text(2), row:text(3), row:text(4), row:text(5)
    if origin == "syscalls" then
      -- The declaration is the file of the module, named for the header it is written from in the ceilings.
      local named = (path:gsub("%.", "/")) .. ".d.tl"
      entries[#entries + 1] = { named, source, path, file }
      kinds[named] = kind
    elseif origin == "tree" then
      entries[#entries + 1] = { file, source }
      kinds[file] = kind
    else
      entries[#entries + 1] = { file, source, path }
      kinds[file] = kind
    end
  end
  return entries, kinds, ""
end

function Pipeline.build(db: Sqlite.Handle, options: Pipeline.Options): Pipeline.Built?, string
  local entries, kinds, trouble = entries_of(db)
  if entries == nil then
    return nil, trouble
  end
  return Pipeline.over(entries, kinds, options), ""
end

--- Where the identity of the code finds a module's source and what it requires.
local record Reader
  source: function(name: string): string?
  requires: function(name: string): {string}
end

--- The identity of the code that reads and checks in the new mode ([`Pipeline.coded`]), over the modules `reader` answers for.
local function identity(reader: Reader): string
  local parts: mut {string} = {}
  local seen: mut {string: boolean} = {}
  local stack: mut {string} = { "build.pipeline" }
  while #stack > 0 do
    local name = assert(table.remove(stack))
    if not seen[name] and (name:sub(1, 5) == "lang." or name:sub(1, 6) == "build.") then
      seen[name] = true
      local source = reader.source(name)
      if source ~= nil then
        parts[#parts + 1] = name .. "\n" .. source
      end
      for _, next_name in ipairs(reader.requires(name)) do
        stack[#stack + 1] = next_name
      end
    end
  end
  table.sort(parts)
  return Hash.hex_sha256(table.concat(parts, "\n\0\n"))
end

--- The code as the running binary carries it.
local carried_code: Reader = {
  source = function(name: string): string?
    local source, _ = Store.source(name)
    return source
  end,
  requires = function(name: string): {string}
    local required, _ = Store.requires(name)
    return required or {}
  end,
}

--- The code as the working database `db` stages it: a boot runs the tree's own, which the bootstrap release that runs it does
--- not carry. A declaration is no code, and the binary answers no source for one.
local function staged_code(db: Sqlite.Handle): Reader
  return {
    source = function(name: string): string?
      local rows, _ = Sqlite.text_rows(db, "SELECT source FROM inputs WHERE path = ?1 AND kind <> 'decl' LIMIT 1", { { text = name } })
      if rows == nil then
        return nil
      end
      local row = rows[1]
      if row == nil then
        return nil
      end
      return row:text(1)
    end,
    requires = function(name: string): {string}
      local rows, _ = Sqlite.text_rows(db,
        "SELECT DISTINCT r.name FROM inputs i JOIN requires r ON r.source_hash = i.source_hash " ..
          "WHERE i.path = ?1 AND i.kind <> 'decl' ORDER BY r.name", { { text = name } })
      local out: mut {string} = {}
      for _, row in ipairs(rows or {}) do
        out[#out + 1] = row:text(1)
      end
      return out
    end,
  }
end

function Pipeline.discounted(result: Driver.Outcome)
  local kept: mut {Driver.Problem} = {}
  for _, p in ipairs(result.scope_errors) do
    if not (p.code == "shadows" and p.msg:find("shadows the global `print`", 1, true) ~= nil) then
      kept[#kept + 1] = p
    end
  end
  result.scope_errors = kept
end

--- The identity of the code the running binary carries, which nothing in this process changes: read once, rather than
--- hashing the sources of the checker's closure again for each compile of a process that compiles many trees.
local record Remembered
  mut code: string?
end

local carried_identity: Remembered = { code = nil }

function Pipeline.coded(tool: string): string
  local code = carried_identity.code
  if code == nil then
    code = identity(carried_code)
    carried_identity.code = code
  end
  return Hash.hex_sha256(tool .. "\0" .. code)
end

function Pipeline.coded_of(tool: string, db: Sqlite.Handle): string?, string
  -- The requires of a source are rows the parse of it made, so a tree not parsed yet has none: the identity would be the
  -- pipeline's own source alone, and an edit to the checker would read as none.
  local rows, trouble = Sqlite.text_rows(db,
    "SELECT count(*) FROM inputs i JOIN requires r ON r.source_hash = i.source_hash WHERE i.path = 'build.pipeline'")
  if rows == nil then
    return nil, trouble
  end
  local count = rows[1]
  if count == nil or count:text(1) == "0" then
    return nil, "build/pipeline.tl is not parsed yet, so the code that reads the tree in the new mode cannot be named"
  end
  return Hash.hex_sha256(tool .. "\0" .. identity(staged_code(db)))
end

function Pipeline.pinned(ceilings: Ceilings.Table): {string: string}
  local lines: mut {string: mut {string}} = {}
  for stage, held in pairs(ceilings.stages) do
    for key, count in pairs(held) do
      local file = key:match("^(%S+)") or key
      local list = lines[file] or {}
      lines[file] = list
      list[#list + 1] = stage .. " " .. key .. " " .. tostring(count)
    end
  end
  local out: mut {string: string} = {}
  for file, list in pairs(lines) do
    table.sort(list)
    out[file] = Hash.hex_sha256(table.concat(list, "\n"))
  end
  return out
end

function Pipeline.catalog(db: Sqlite.Handle, schema: string): integer?, string
  return ErrorCatalog.insert(db, schema)
end

--- Puts the collector back in the mode `previous` names: the answer it gave when it was switched to the generational one.
local function restore_collector(previous: string)
  if previous == "incremental" then
    collectgarbage("incremental")
  end
end

function Pipeline.derive(db: Sqlite.Handle, fresh: {Derivation.Fresh}, tally: Derivation.Parses,
                         made: mut {Derivation.Source}, broken?: mut {Derivation.Broken}): boolean, string
  local entries, kinds, trouble = entries_of(db)
  if entries == nil then
    return false, trouble
  end
  local index = TreeProgram.index(entries, kinds)
  -- A source is found by the name of its file in the database, which for a declaration written from a header is the header's.
  local by_file: mut {string: Driver.Source} = {}
  for _, source in ipairs(index.sources) do
    local named = source.filename
    if source.pinned ~= "" then
      named = source.pinned
    end
    by_file[named] = source
  end
  -- Each source is read once and its rows kept: the garbage of one is freed as the next is read, and not when the heap has
  -- doubled. The collector goes back to the mode it was in.
  local previous = collectgarbage("generational")
  for _, one in ipairs(fresh) do
    -- A file the program leaves out (a fixture of a test) is read as written, as a module of its own.
    local source = by_file[one.file]
    if source == nil then
      local dialect: Ast.Dialect = "tl"
      if one.file:match("%.d%.tl$") ~= nil then
        dialect = "decl"
      end
      source = Driver.source(Declarations.module_of(one.file), one.file, one.source, dialect)
    end
    local read = Driver.parse(source)
    local first = read.syntax[1]
    if first ~= nil then
      local message = ErrorRender.line(one.file, first)
      if broken == nil then
        restore_collector(previous)
        return false, message
      end
      broken[#broken + 1] = { source_hash = one.source_hash, file = one.file, message = message }
    else
      local put, why = SyntaxDerivation.insert(db, one.source_hash, one.file, read.text, read.chunk, one.mapped)
      if not put then
        restore_collector(previous)
        return false, why
      end
      tally.parsed = tally.parsed + 1
      made[#made + 1] = { source_hash = one.source_hash, mapped = one.mapped }
    end
  end
  restore_collector(previous)
  return true, ""
end

--- The stub of each standard-library module of the tree that has a declaration-only one, as the source a build reads in place of
--- the module, under the module's own aliases: the ones `built` was given, or those it makes of what it read of each.
local function stubs_of(built: Pipeline.Built): {string: Driver.Source}
  local held = built.stubs
  if held ~= nil then
    return held
  end
  local texts: mut {string: string} = {}
  for module, text in pairs(built.given) do
    texts[module] = text
  end
  if next(built.given) == nil then
    for _, source in ipairs(built.index.sources) do
      if built.index.by_module[source.module] == source and judges_stub(source.filename, source.module) then
        -- Read apart from the build, so that the tokens of the whole library are not held while a stub is made of each.
        local read = Driver.parse(source)
        if #read.syntax == 0 then
          local made = Stub.made(read.chunk)
          if made.pruned then
            texts[source.module] = made.text
          end
        end
      end
    end
  end
  local out: mut {string: Driver.Source} = {}
  for module, text in pairs(texts) do
    local home = built.index.by_module[module]
    if home ~= nil then
      local source = Driver.source(module, home.filename, text, "tl")
      source.aliases = home.aliases
      out[module] = source
      for _, alias in ipairs(source.aliases) do
        out[alias] = source
      end
    end
  end
  built.stubs = out
  return out
end

--- The stub of the standard-library module `m` is no stub a project's checker could read in its place: why, "" where it is
--- one that types the module as its source does. `result` is the module read from its source in `built`.
local function stub_trouble(m: Module, built: Pipeline.Built, result: Driver.Outcome): string
  -- The stub is made of what the checker read of the module, in the new grammar: the projection carries the fork's, for the
  -- tools that still read it ([`Pipeline.derive`]), and a caller may give its own.
  local given = m.stub
  local made: Stub.Made = Stub.made(result.chunk)
  if given ~= nil and next(built.given) ~= nil then
    made = { text = given.text, pruned = given.pruned }
  end
  if not made.pruned then
    return m.file .. ": its stub keeps every statement, so a project's checker " ..
      "would read and load all of it: a standard-library module must end by returning a " ..
      "name whose last top-level declaration spells its type (`local record M ... end`, " ..
      "a local function, or `local m: M = ...`) (build/stub.tl)"
  end
  local stubbed = built.stubbed or TreeProgram.build(built.index, built.globals, false, stubs_of(built), built.standard)
  built.stubbed = stubbed
  stubbed:lower({ m.path })
  local why = stub_verdict(made, built.build, result, stubbed)
  stubbed:retire(m.path)
  if why ~= "" then
    return m.file .. ": the stub a project's checker reads in its place (build/stub.tl) cannot stand for its source: " .. why
  end
  return ""
end

--- The name the build holds the module `m` under: its own, or where a declaration file is written for the module too, the one
--- its implementation is held under ([`Driver.implementation`]).
local function built_name(m: Module, built: Pipeline.Built): string
  local implementation = Driver.implementation(m.path)
  if built.index.by_module[implementation] ~= nil then
    return implementation
  end
  return m.path
end

--- [`Pipeline.generate`]'s work. With `kept` the build is one the caller keeps across modules ([`Pipeline.review`]): the
--- calls of [`Shape.record_of`] are resolved already, and the module is checked and not written as bytecode.
local function generated_of(m: Module, built: Pipeline.Built, facts?: boolean, judged?: boolean, hints?: ErrorRender.Hints,
                            kept?: boolean): Plans.Generated?, string
  local build = built.build
  local named = built_name(m, built)
  if kept ~= true then
    if build:retired(named) then
      return nil, m.file .. ": this build has written the module already: a build writes each module once"
    end
    -- The calls of [`Shape.record_of`] are resolved in the text the checker reads, and the module is read again with them.
    local spliced, spec_trouble = TreeProgram.splice(build, named, m.file)
    if spliced == nil then
      return nil, spec_trouble
    end
  end
  build:lower({ named })
  local result = build:result(named, true)
  if result == nil then
    return nil, m.file .. ": the new checker's build has no module " .. m.path
  end
  if m.generated == true then
    Pipeline.discounted(result)
  end
  local lines: mut {string} = {}
  if result.broken then
    -- A pin counts the errors of a translation that does not parse; there is no syntax tree to write Lua from.
    for _, p in ipairs(result.syntax) do
      lines[#lines + 1] = ErrorRender.line(m.file, p)
    end
  else
    for _, line in ipairs(build:held(result, built.ceilings)) do
      lines[#lines + 1] = line
    end
    for _, w in ipairs(result.warnings) do
      lines[#lines + 1] = ErrorRender.line(m.file, w)
    end
  end
  if hints ~= nil then
    -- A line of the checker's own error carries what the docs answer for it, as the fork's does ([`ErrorRender.lines`]).
    for _, p in ipairs(result.errors) do
      local told = ErrorRender.line(m.file, p)
      for i, line in ipairs(lines) do
        if line == told then
          lines[i] = line .. ErrorRender.pointers(result, p, hints)
        end
      end
    end
  end
  if #lines > 0 then
    return nil, m.file .. ": the compiler refused it\n" .. table.concat(lines, "\n")
  end
  -- The module that holds the hook the wraps and the parameter checks call is written without them: a checked call in the
  -- hook would call the hook.
  local emitted = CompileGrammar.emit(build, result, facts == true and m.path ~= "build.test_worker", true, true)
  local code = emitted.code
  if code == nil then
    return nil, m.file .. ": the generator wrote no Lua: " .. emitted.trouble
  end
  local refused = false
  local references: mut {Receivers.Reference} = {}
  -- What the fork holds a compile to besides the checker, over the type report of the module.
  local subject = Report.of(build.program, result)
  if subject == nil or not built.types then
    return nil, m.file .. ": the new checker kept no type report of it, which the discipline and the record-field uses read"
  end
  if m.kind == "module" and m.path:sub(1, 7) == "cosmic." then
    local trouble = stub_trouble(m, built, result)
    if trouble ~= "" and judged ~= false then
      return nil, trouble
    end
    refused = trouble ~= ""
  end
  if Rules.applies(m.kind, m.generated) then
    local read = SyntaxContracts.check(subject)
    local problems = read.problems
    local allowed = Ceilings.of(built.ceilings, "untyped")[m.file] or 0
    if read.untyped > allowed then
      if built.ceilings.none == true then
        problems[#problems + 1] = m.file .. ": " .. String.counted(read.untyped, "call") .. " the checker gave no function, " ..
          "which no rule of the discipline judged: type what it calls through"
      else
        problems[#problems + 1] = m.file .. ": " .. String.counted(read.untyped, "call") .. " the checker gave no function, " ..
          "which no rule of the discipline judged, pinned " .. tostring(allowed) ..
          "; type what it calls through rather than raise the pin (build/ceilings.txt's [untyped])"
      end
    end
    if #problems > 0 and judged ~= false then
      return nil, table.concat(problems, "\n")
    end
    refused = refused or #problems > 0
  end
  if kept ~= true then
    for _, use in ipairs(Receivers.references(subject)) do
      references[#references + 1] = { module = use.module, member = use.member, line = use.line }
    end
  end
  -- What the readers took is read: the types of the module are of no use to the next, and a tree of them is the memory of a run.
  result.types = {}
  result.callees = {}
  if kept == true then
    return { lua = code, bytecode = "", references = references, refused = refused }, ""
  end
  if m.kind == "test" then
    code = LuaTail.with_test_tail(code, m.tests)
  end
  local bytecode, dump_trouble = LuaTail.bytecode_of(code, m.path, m.file)
  if bytecode == nil then
    return nil, dump_trouble
  end
  return { lua = code, bytecode = bytecode, references = references, refused = refused }, ""
end

--- How many modules [`Pipeline.generate`] has written, for the probe's marks ([`Memprobe.mark`]).
local record Written
  mut modules: integer
end

local written: Written = { modules = 0 }

function Pipeline.generate(m: Module, built: Pipeline.Built, facts?: boolean, judged?: boolean,
                           hints?: function(): {Sqlite.Handle}, {boolean}): Plans.Generated?, string
  -- Between two modules there is the garbage of one and the live data of the build. The generational collector frees the
  -- garbage of a module as it is made, where the default waits until the heap has doubled, and the memory it frees is not given
  -- back: the resident set of the run stays near the live data and not near the garbage. The caller writes modules until it is
  -- done, with no call after the last, so the collector stays in this mode for the rest of the process.
  if written.modules == 0 then
    collectgarbage("generational")
  end
  local made, why = generated_of(m, built, facts, judged, hints)
  built.build:retire(built_name(m, built))
  written.modules = written.modules + 1
  if written.modules % 100 == 0 then
    Memprobe.mark(("pipeline: wrote %d"):format(written.modules))
  end
  if made == nil then
    return nil, why
  end
  return made, ""
end

function Pipeline.review(m: Module, built: Pipeline.Built, hints?: ErrorRender.Hints): Plans.Generated?, string
  -- The collector is generational for the life of a session, as it is for a compile: see [`Pipeline.generate`].
  collectgarbage("generational")
  return generated_of(m, built, false, true, hints, true)
end

function Pipeline.requires(file: string, text: string): {string}?, string
  local index = Driver.index({ { file, text, "lone" } }, function(_: string): boolean
    return false
  end)
  local source = index.sources[1]
  if source == nil then
    return nil, file .. ": the new checker read no source of it"
  end
  local read = Driver.parse(source)
  local first = read.syntax[1]
  if first ~= nil then
    return nil, ErrorRender.line(file, first)
  end
  local out: mut {string} = {}
  for _, required in ipairs(read.chunk.requires) do
    out[#out + 1] = required.module
  end
  return out, ""
end

function Pipeline.checked_alone(file: string, text: string, options: Pipeline.Options, tests?: boolean): Pipeline.Alone
  -- A module of its own, named for nothing a `require` can say.
  local module = "lone"
  local kind = if tests == true then "test" else "main" end
  local built = Pipeline.over({ { file, text, module } }, { [file] = kind }, options)
  local build = built.build
  -- The calls of [`Shape.record_of`] are resolved in the text the checker reads, as the tree's compile does.
  local spliced, spec_trouble = TreeProgram.splice(build, module, file)
  if spliced == nil then
    return { code = nil, lines = { spec_trouble } }
  end
  build:lower({ module })
  local result = build:result(module, true)
  if result == nil then
    return { code = nil, lines = { file .. ": the new checker's build has no module " .. module } }
  end
  local told: mut {string} = {}
  if result.broken then
    for _, p in ipairs(result.syntax) do
      told[#told + 1] = ErrorRender.line(file, p)
    end
  else
    -- What the file returns is its entry point ([`build.standalone`]) or, for a chunk of `cosmic -e`, its exit code, which
    -- nothing requires and so no declaration needs to describe: the one error a lone file is allowed, at every `return`,
    -- whatever it returns.
    local entry: Ceilings.Table = { stages = { checked = { [file .. " export_not_declared"] = math.maxinteger } },
      none = true }
    for _, line in ipairs(build:held(result, entry)) do
      told[#told + 1] = line
    end
    for _, w in ipairs(result.warnings) do
      told[#told + 1] = ErrorRender.line(file, w)
    end
  end
  if #told > 0 then
    return { code = nil, lines = told }
  end
  -- A file alone keeps an import it reads as a type only: nothing serves the module it names.
  local emitted = CompileGrammar.emit(build, result, false, true, false)
  if emitted.code == nil then
    return { code = nil, lines = { file .. ": the generator wrote no Lua: " .. emitted.trouble } }
  end
  return { code = emitted.code, lines = {} }
end

function Pipeline.lone(file: string, text: string, options: Pipeline.Options, tests?: boolean): string?, string
  local made = Pipeline.checked_alone(file, text, options, tests)
  if made.code == nil then
    return nil, table.concat(made.lines, "\n")
  end
  return made.code, ""
end

return Pipeline
