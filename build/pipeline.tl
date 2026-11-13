--- The build's compile with the new checker ([`build.grammar_mode`]): a module of the staged tree is read, checked against
--- its markers and written as Lua and bytecode by [`build.driver`] and [`lang.codegen`]. [`Pipeline.generate`] answers what
--- [`build.importer`] asks of a compile. The rows of a parse are [`build.parse_derive`]'s.
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
--- A MODULE IS REFUSED for an error with no marker on its line ([`build.ceilings`]), for any warning, for a text that does
--- not parse and for a construct the generator does not write. The markers are held by the tree's checks as they are here;
--- the other refusals are listed in build.pipeline.residue.
---
--- A MODULE IS KEYED by its text, markers and all, and the whole compile by the code that reads ([`Pipeline.coded`]), so that
--- an edit to a module or to the checker judges a module another run compiled again. The standard library the module was
--- checked against is in the compiler's identity ([`build.identity`]).
--
-- TODO: point to what `cosmic docs` answers for a name and to the worked example of a form in the lines of a warning, as
-- [`build.error_render`]'s `lines` does with the databases it is given, once [`Driver.Build`] answers the problems over their
-- markers and not only the lines that list them: the lines of an error carry the pointer ([`Pipeline.generate`]'s `hints`),
-- which the lines of a warning and of a text that does not parse do not.
local AnalysisSchema = require("build.analysis_schema")
local Ceilings = require("build.ceilings")
local CheckerDeclarations = require("build.checker_declarations")
local CodeWalk = require("build.code_walk")
local CompileGrammar = require("build.compile_grammar")
local Ast = require("lang.ast")
local Rules = require("build.contract_rules")
local Driver = require("build.driver")
local Memprobe = require("build.memprobe")
local ParseDerive = require("build.parse_derive")
local ErrorCatalog = require("build.error_catalog")
local ErrorRender = require("build.error_render")
local Fs = require("cosmic.fs")
local Hash = require("cosmic.hash")
local Lexer = require("lang.lexer")
local LuaTail = require("build.lua_tail")
local Node = require("build.syntax_node")
local ProjectRefusals = require("build.project_refusals")
local Receivers = require("build.syntax_receivers")
local Report = require("build.syntax_report")
local Stub = require("build.syntax_stub")
local Sqlite = require("cosmic.sqlite")
local Store = require("cosmic.store")
local String = require("cosmic.string")
local Stamp = require("build.stamp")
local SyntaxContracts = require("build.syntax_contracts")
local TreeProgram = require("build.tree_program")
local standard_text = require("build.standard_text")
local type Plans = require("build.plans")
-- Declares what text this module reads ([`build.code_walk`]'s `markers`): pipeline, stubs.
local _ = require("build.reads.pipeline")
local type Module = Plans.Module

local record Pipeline
  --- Whether [`Pipeline.build`] refused the tree for what it holds, rather than for a trouble reading it.
  type Refusal = ParseDerive.Refusal

  --- What a pipeline is made of besides the tree.
  record Options
    --- The standard library's declarations, which every module's globals are made of ([`build.tree_program`]).
    globals: TreeProgram.Globals
    --- Whether the checker keeps the type of each node, which the readers of the type report need.
    mut types: boolean
    --- Answers the `cosmic.*` modules the tree does not hold, each its stub or its source: [`Pipeline.carried`] where
    --- not given.
    mut standard: Driver.Provider?
    --- Whether the tree is a project outside cosmic's own, whose checker is its own and which no marker holds: every error
    --- refuses. Absent for cosmic's tree, whose markers hold what they mark.
    project: boolean?
  end

  --- A build over the tree.
  record Built
    build: Driver.Build
    --- The sources of the tree and the modules they answer to, which a build that reads the stub of a standard-library module
    --- in place of its source is made from.
    index: Driver.Index
    --- The declarations and the provider [`Pipeline.options`] gave, which that build is made with.
    globals: TreeProgram.Globals
    standard: Driver.Provider
    --- Whether the checker kept the type of each node, which the readers of the type report need.
    types: boolean
    --- Whether the build is a project's, outside cosmic's tree ([`Pipeline.Options`]'s `project`), whose programs are held to
    --- what [`build.project_refusals`] says.
    project: boolean?
    --- The stubs a caller gave ([`Pipeline.over`]), by module: none for a build that makes them of what it reads.
    given: {string: string}
    --- The stub of each standard-library module of the tree that a project's checker would read in its place, as a source that
    --- stands for the module and its aliases, made when the first is judged.
    mut stubs: {string: Driver.Source}?
    --- The build that reads those stubs where it reads their sources, made when the first stub is judged.
    mut stubbed: Driver.Build?
    --- Whether the declarations of a module stand, by path, for each module [`Pipeline.generate`] refused and each
    --- [`Pipeline.examine`] read: it parsed, and no error of its scopes or its declarations lies outside the body of a
    --- function, so what a module that requires it reads of it is what the module declares. A module that returns what
    --- no declaration describes has none that stand, nor has one with an error in a `return`: a value that does not fit
    --- the results declared is as often mended in the declaration, which a finding of the other module would rest on.
    --- Absent for a module that was written.
    standing: mut {string: boolean}
  end

  --- The options for the tree at `root`, `own` when it is cosmic's own ([`build.tree`]): the declarations and the
  --- markers it holds; in any other tree, a project's, the declarations of the standard library the tool carries
  --- ([`build.checker_declarations`]) and no marker, so that every error of the checker refuses. nil and why where the
  --- tool carries none of the declarations (a tool older than this one: boot it again).
  options: function(root: string, own: boolean): Options?, string

  --- The options for a project outside cosmic's tree, whose globals are the declarations `texts` ([`Pipeline.options`] gives
  --- the ones the tool carries): no markers, so every error of the checker refuses.
  project: function(texts: CheckerDeclarations.Texts): Options

  --- The options for a source that is no tree's (a lone file, a generated source): the declarations the tool carries
  --- ([`build.checker_declarations`]) and no markers. nil and why where the tool carries none.
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
    --- The stage (`scoped`, `declared`, `checked`) each finding of the checker is of, by `<line>:<column>:<code>` of the
    --- finding: from the checker's own lists, so that a code two stages have is told apart. A finding two stages report at
    --- one place and under one code is "" (no stage can hold it), and a warning has no entry.
    stages: {string: string}
  end

  --- [`Pipeline.lone`] with the refusal as a line for each problem, for a caller that lists them.
  checked_alone: function(file: string, text: string, options: Options, tests?: boolean): Alone

  --- The `cosmic.*` modules of the running binary, each its stub or its source ([`build.standard_text`]), a declaration
  --- ([`cosmic.sys`]) as one.
  carried: function(): Driver.Provider

  --- [`Pipeline.carried`] widened to every module of the running binary, the tool's own beside the standard library's
  --- ([`build.standard_text`]'s `own`): what `cosmic -e` types its chunk against.
  carried_own: function(): Driver.Provider

  --- A build over the modules of `entries`: pairs of a file and its text, with the module and the name its findings are told
  --- under for a source written from another file ([`Driver.index`]). `kinds` says of each file what the working database
  --- says of its input (`test`, ...); a `test` has its functions called from outside. `stubs` gives the stub of a
  --- standard-library module, by module, which a build otherwise makes of what it read of it.
  over: function(entries: {{string}}, kinds: {string: string}, options: Options, stubs?: {string: string}): Built

  --- A build over the `inputs` of the working database `db`: the tree and what is written from it (the guides, the
  --- templates, the bindings of C).
  build: function(db: Sqlite.Handle, options: Options, refusal?: Refusal): Built?, string

  --- The Lua and the bytecode of the module `m`, checked and written by the new checker: nil and why where the module is refused. A module is refused for a count over its ceiling
  --- ([`Driver.Build.held`]), a warning, a call no rule of the discipline judged with no `untyped` marker, and the
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

  --- What [`Pipeline.generate`] would refuse the module `m` for, "" where it would write it: `m` is checked and judged as
  --- a compile does and nothing of it is written, for a module that cannot be built because it requires a refused one
  --- whose declarations stand ([`Pipeline.Built.standing`]). Its own findings are then told in the run that refused the
  --- other. The module is retired, as a compile retires it, and its own standing recorded. `text` is read in place of the
  --- module's own where given: the repaired text of a source that does not parse ([`build.derivation`]'s `Broken`).
  examine: function(m: Module, built: Built, judged?: boolean, hints?: ErrorRender.Hints, text?: string): string

  --- Takes from the scope errors of `result` the shadowing of `print` that every example of a guide makes ([`build.doctest`]
  --- captures what it prints in a local of that name), as the fork's compile discounts it: the module is generated, and the
  --- name is its own.
  discounted: function(result: Driver.Outcome)

  --- The tool string a compile is keyed by, given the one the harness chose ([`build.grammar_mode`]'s `tool`): that and the
  --- identity of the code that reads and checks a source, which is the source, as the running binary carries it,
  --- of every module of the tree (`lang.*`, `build.*`) that [`build.pipeline`] reaches. A compile made with it is
  --- keyed by it, so that an edit to the checker or to a reader compiles the tree again; the compiler's identity
  --- ([`build.identity`]) holds none of it, so a default run is not read again for it. A parse is keyed by the part of it
  --- a parse runs, and no more ([`build.parse_derive`], [`build.importer`]'s `analyzer_identity`).
  coded: function(tool: string): string

  --- [`Pipeline.coded`] over the code the working database `db` stages, parsed, in place of the code the running binary
  --- carries: the identity of a boot, which runs the tree's own code under a bootstrap release that carries another. nil and
  --- why where the tree is not parsed.
  coded_of: function(tool: string, db: Sqlite.Handle): string?, string

  --- Writes a row for every code the new checker emits to the `catalog` table of `db` (of the schema `schema`, "" for the
  --- default), as [`ErrorCatalog.insert`] does.
  catalog: function(db: Sqlite.Handle, schema: string): integer?, string
end

--- Whether the stub of the module `module` of the file `file` is held to its source's type: a standard-library module that
--- the error-slot discipline covers.
local function judges_stub(file: string, module: string): boolean
  return AnalysisSchema.kind_of(file) == "module" and module:sub(1, 7) == "cosmic."
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
    types = true, standard = nil, project = true,
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

function Pipeline.options(root: string, own: boolean): Pipeline.Options?, string
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
  return {
    globals = TreeProgram.globals(prelude, stdlib),
    types = true, standard = nil, project = nil,
  }, ""
end

--- Whether the binary holds the module `name` as a declaration.
local function declared(name: string): boolean
  local databases = Store.databases()
  local own = databases[#databases]
  if own == nil then
    return false
  end
  local rows, _ = Sqlite.text_rows(own, "SELECT 1 FROM decls WHERE path = ?1", { { text = name } })
  return rows ~= nil and #rows > 0
end

--- Nil for a module the binary does not hold. One it holds without its source
--- (a pure test store, [`Store.withheld`]) is no absent module the checker may
--- call missing: it raises why.
local function withheld_or_absent(module: string): string?
  local withheld, trouble = Store.withheld(module)
  if trouble ~= "" then
    error(trouble, 0)
  end
  if withheld ~= nil then
    -- A standard-library module is served from its stub, which a test keeps by naming the module.
    if module:sub(1, 7) == "cosmic." then
      error("the stub of '" .. module .. "' is withheld: the store carries the module without it; a test that type-checks " ..
          "a snippet requiring it names it with `local type _ = require(\"" .. module ..
          "\")` at its top level, or declares `Test.policy { store_text = true }`", 0)
    end
    error(withheld, 0)
  end
  return nil
end

function Pipeline.carried(): Driver.Provider
  return Driver.standard(function(module: string): string?
    local found = standard_text.of(module)
    if found == nil then
      return withheld_or_absent(module)
    end
    return found.text
  end, declared)
end

function Pipeline.carried_own(): Driver.Provider
  return Driver.standard(function(module: string): string?
    local found = standard_text.own(module)
    if found == nil then
      return withheld_or_absent(module)
    end
    return found.text
  end, declared)
end

function Pipeline.over(entries: {{string}}, kinds: {string: string}, options: Pipeline.Options, stubs?: {string: string}):
    Pipeline.Built
  local index = TreeProgram.index(entries, kinds)
  local standard = options.standard or Pipeline.carried()
  return {
    build = TreeProgram.build(index, options.globals, options.types, nil, standard,
      TreeProgram.meant(index, options.project ~= true)), index = index,
    globals = options.globals, standard = standard, types = options.types, given = stubs or {}, stubs = nil, stubbed = nil,
    project = options.project, standing = {},
  }
end

--- `refusal`, when given, has `refused` set where the tree is refused for what it holds (a declaration beside its source,
--- a module named for one the binary answers) and not for a trouble reading it.
function Pipeline.build(db: Sqlite.Handle, options: Pipeline.Options, refusal?: Pipeline.Refusal): Pipeline.Built?, string
  local staged, trouble = ParseDerive.entries(db, options.project ~= true, refusal)
  if staged == nil then
    return nil, trouble
  end
  local entries, kinds = staged.entries, staged.kinds
  if options.project == true then
    local reserved = TreeProgram.reserved(entries, TreeProgram.library_modules(options.globals))
    if reserved ~= "" then
      if refusal ~= nil then refusal.refused = true end
      return nil, reserved
    end
  end
  return Pipeline.over(entries, kinds, options), ""
end

--- Where the identity of the code finds a module's source and what it requires.
local record Reader
  source: function(name: string): string?
  requires: function(name: string): {string}
end

--- The identity of the code that reads and checks ([`Pipeline.coded`]), over the modules `reader` answers for: each module
--- of [`build.code_walk`]'s walk from this one by its name and its source. What the walk leaves out of this module's own
--- requires, and why, is [`CodeWalk.type_only`].
local function identity(reader: Reader): string
  local names, trouble = CodeWalk.reach(CodeWalk.pipeline, function(name: string): {string}?, string
    return reader.requires(name), ""
  end)
  assert(names, trouble)
  local parts: mut {string} = {}
  for _, name in ipairs(names) do
    local source = reader.source(name)
    if source ~= nil then
      parts[#parts + 1] = name .. "\n" .. source
    end
  end
  table.sort(parts)
  return Hash.hex_sha256(table.concat(parts, "\n\0\n"))
end

--- The code as the running binary carries it.
local carried_code: Reader = {
  source = function(name: string): string?
    local source, _ = Store.source(name)
    if source == nil then
      -- Held without its source is no module the identity may leave out.
      local withheld, trouble = Store.withheld(name)
      if trouble ~= "" then error(trouble, 0) end
      if withheld ~= nil then error(withheld, 0) end
    end
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
      local rows, _ = Sqlite.text_rows(db, "SELECT source FROM inputs WHERE path = ?1 AND " .. AnalysisSchema.not_declaration("kind") .. " LIMIT 1", { { text = name } })
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
          "WHERE i.path = ?1 AND " .. AnalysisSchema.not_declaration("i.kind") .. " ORDER BY r.name", { { text = name } })
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

function Pipeline.code_of(source: function(name: string): string?, requires: function(name: string): {string}): string
  return identity({ source = source, requires = requires })
end

function Pipeline.coded(tool: string): string
  local code = carried_identity.code
  if code == nil then
    code = Stamp.read("stamp_coded") or identity(carried_code)
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
    return nil, "build/pipeline.tl is not parsed yet, so the code that reads the tree cannot be named"
  end
  return Hash.hex_sha256(tool .. "\0" .. identity(staged_code(db))), ""
end

function Pipeline.catalog(db: Sqlite.Handle, schema: string): integer?, string
  return ErrorCatalog.insert(db, schema)
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
  -- tools that still read it ([`build.parse_derive`]), and a caller may give its own.
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
  local stubbed = built.stubbed or TreeProgram.build(built.index, built.globals, false, stubs_of(built), built.standard,
    TreeProgram.meant(built.index, built.project ~= true))
  built.stubbed = stubbed
  stubbed:lower({ m.path })
  local why = stub_verdict(made, built.build, result, stubbed)
  stubbed:retire(m.path)
  if why ~= "" then
    return m.file .. ": the stub a project's checker reads in its place (build/stub.tl) cannot stand for its source: " .. why
  end
  return ""
end

--- Whether the declarations of the module `result` is of stand: it parsed, it returns what a declaration describes, and no
--- error of its scopes or its declarations lies outside the body of a function.
--
-- TODO: pass over the errors a marker holds, once [`Driver.Build.held`] answers which findings its markers held and not
-- only the lines of the rest: a module of cosmic's own tree with a marked error outside a function body builds, and reads
-- here as one whose declarations do not stand, so a module that requires it beside a refused one is left unchecked.
local function declarations_stand(result: Driver.Outcome): boolean
  if result.broken then
    return false
  end
  for _, e in ipairs(result.bodies) do
    if e.code == "export_not_declared" then
      return false
    end
  end
  if #result.scope_errors == 0 and #result.declared == 0 then
    return true
  end
  local tokens = result.chunk.tokens
  local from: mut {integer} = {}
  local to: mut {integer} = {}
  Node.walk(result.chunk, function(n: Ast.Node)
    local body: Ast.Block? = nil
    if (n.kind == "LocalFunction") then
      body = n.fn.body
    elseif (n.kind == "Function") then
      body = n.fn.body
    elseif (n.kind == "FunctionLit") then
      body = n.fn.body
    elseif (n.kind == "Method") then
      body = n.body
    end
    if body ~= nil then
      local start, close = Lexer.offset(tokens, body.first), Lexer.offset(tokens, body.close)
      from[#from + 1] = start
      to[#to + 1] = close
    end
  end)
  for _, list in ipairs({ result.scope_errors, result.declared }) do
    for _, e in ipairs(list) do
      local inside = false
      for i, start in ipairs(from) do
        if e.offset >= start and e.offset < assert(to[i]) then
          inside = true
        end
      end
      if not inside then
        return false
      end
    end
  end
  return true
end

--- Whether a module that requires the module `result` is of can be checked against it ([`Pipeline.Built.standing`]): its
--- declarations stand, and no error lies in a `return`.
--
-- TODO: tell an error that leaves the declarations in doubt from one that does not by what the checker compared (a value
-- against a declared result or parameter), once an error carries the declaration it was judged by ([`Driver.Problem`] has
-- the call of a refused argument alone): an error in a body that uses a parameter as another type than it declares, or a
-- field its record does not declare, is mended in the declaration as often, and is not seen here. The refusal of the module
-- checked says it holds of the declarations as written ([`build.importer`]).
local function interface_stands(result: Driver.Outcome): boolean
  if not declarations_stand(result) then
    return false
  end
  if #result.bodies == 0 then
    return true
  end
  local tokens = result.chunk.tokens
  local doubted = false
  Node.walk(result.chunk, function(n: Ast.Node)
    if (n.kind == "Return") and not doubted then
      local base = Node.base(n)
      local start = Lexer.offset(tokens, base.first)
      local finish = Lexer.offset(tokens, base.last) + #Lexer.text(tokens, base.last)
      for _, e in ipairs(result.bodies) do
        if e.offset >= start and e.offset < finish then
          doubted = true
        end
      end
    end
  end)
  return not doubted
end

--- The breaches of the error-slot discipline in a module `m` that is refused already, with `result` its outcome: what a
--- compile of it would say once the refusals are fixed, so that one run tells both. Only the breaches that rest on typed
--- code are told ([`SyntaxContracts.check`]'s `errors`), and none where the declarations of the module do not stand
--- (the types every rule reads) or the discipline does not hold it.
local function breaches_of_refused(m: Module, built: Pipeline.Built, result: Driver.Outcome): {string}
  if not declarations_stand(result) or not built.types or not Rules.applies(m.kind, m.generated) then
    return {}
  end
  local subject = Report.of(built.build.program, result)
  if subject == nil then
    return {}
  end
  return SyntaxContracts.check(subject, nil, SyntaxContracts.declared_in(built.index), result.errors).problems
end

--- [`Pipeline.generate`]'s work. With `kept` the build is one the caller keeps across modules ([`Pipeline.review`]): the
--- calls of [`Shape.record_of`] are resolved already, and the module is checked and not written as bytecode. With `examined`
--- ([`Pipeline.examine`]) the module is read as a compile reads it, and not written as bytecode either.
local function generated_of(m: Module, built: Pipeline.Built, facts?: boolean, judged?: boolean, hints?: ErrorRender.Hints,
                            kept?: boolean, examined?: boolean): Plans.Generated?, string
  local build = built.build
  local named = m.path
  local unwritten = kept == true or examined == true
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
    for _, line in ipairs(build:held(result, built.project ~= true)) do
      lines[#lines + 1] = line
    end
    for _, w in ipairs(result.warnings) do
      lines[#lines + 1] = ErrorRender.line(m.file, w)
    end
    if built.project == true then
      for _, line in ipairs(ProjectRefusals.check(m.file, result.chunk, result.scoped)) do
        lines[#lines + 1] = line
      end
    end
  end
  if hints ~= nil then
    -- A line of the checker's own error carries what the docs answer for it, as the fork's does ([`ErrorRender.lines`]).
    for _, p in ipairs(result.errors) do
      local told = ErrorRender.line(m.file, p)
      for i, line in ipairs(lines) do
        if line == told then
          local pointers = ErrorRender.pointers(result, p, hints)
          table.remove(lines, i)
          table.insert(lines, i, line .. pointers)
        end
      end
    end
  end
  if #lines > 0 then
    for _, line in ipairs(breaches_of_refused(m, built, result)) do
      lines[#lines + 1] = line
    end
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
    local read = SyntaxContracts.check(subject, nil, SyntaxContracts.declared_in(built.index))
    local problems = read.problems
    if built.project ~= true then
      -- Held by markers at the lines of the calls, in the text of the module itself.
      local findings: mut {Ceilings.Finding} = {}
      for _, line in ipairs(read.untyped_lines) do
        findings[#findings + 1] = { code = Ceilings.untyped_code, y = line, x = 1, msg = Ceilings.untyped_message,
          fix = Ceilings.untyped_fix }
      end
      local text = result.source.text
      if result.source.pinned ~= "" then
        text = ""
      end
      local joined: mut {string} = {}
      for _, line in ipairs(problems) do
        joined[#joined + 1] = line
      end
      for _, line in ipairs(Ceilings.marked("untyped", m.file, text, findings, { Ceilings.untyped_code }, "calls").lines) do
        joined[#joined + 1] = line
      end
      problems = joined
    elseif read.untyped > 0 then
      local calls = String.counted(read.untyped, "call")
      problems[#problems + 1] = m.file .. ": " .. calls .. " the checker gave no function, " .. -- checked: view_written
        "which no rule of the discipline judged: type what it calls through"
    end
    if #problems > 0 and judged ~= false then
      return nil, table.concat(problems, "\n")
    end
    refused = refused or #problems > 0
  end
  if not unwritten then
    for _, use in ipairs(Receivers.references(subject)) do
      references[#references + 1] = { module = use.module, member = use.member, line = use.line }
    end
  end
  -- What the readers took is read: the types of the module are of no use to the next, and a tree of them is the memory of a run.
  result.types = {}
  result.callees = {}
  if unwritten then
    return { lua = code, bytecode = "", references = references, refused = refused,
      fact_wraps = emitted.fact_wraps or 0, parameter_checks = emitted.parameter_checks or 0 }, ""
  end
  if m.kind == "test" then
    code = LuaTail.with_test_tail(code, m.tests)
  end
  local bytecode, dump_trouble = LuaTail.bytecode_of(code, m.path, m.file)
  if bytecode == nil then
    return nil, dump_trouble
  end
  return { lua = code, bytecode = bytecode, references = references, refused = refused,
    fact_wraps = emitted.fact_wraps or 0, parameter_checks = emitted.parameter_checks or 0 }, ""
end

--- How many modules [`Pipeline.generate`] has written, for the probe's marks ([`Memprobe.mark`]).
local record Written
  mut modules: integer
end

local written: Written = { modules = 0 }

--- Records whether the declarations of `m` stand ([`Pipeline.Built.standing`]), while the build still holds its result.
local function note_standing(m: Module, built: Pipeline.Built)
  local result: Driver.Outcome? = nil
  if not built.build:retired(m.path) then
    result = built.build:result(m.path, true)
  end
  built.standing[m.path] = result ~= nil and interface_stands(result)
end

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
  if made == nil then
    note_standing(m, built)
  end
  built.build:retire(m.path)
  written.modules = written.modules + 1
  if written.modules % 100 == 0 then
    Memprobe.mark(("pipeline: wrote %d"):format(written.modules))
  end
  if made == nil then
    return nil, why
  end
  return made, ""
end

--- Marks `m` written in `built` where its compile was made elsewhere, in a copy of this process
--- ([`build.compile_fanout`]): the build holds no result of it to write again.
function Pipeline.took(m: Module, built: Pipeline.Built)
  built.build:retire(m.path)
end

function Pipeline.review(m: Module, built: Pipeline.Built, hints?: ErrorRender.Hints): Plans.Generated?, string
  -- The collector is generational for the life of a session, as it is for a compile: see [`Pipeline.generate`].
  collectgarbage("generational")
  return generated_of(m, built, false, true, hints, true)
end

function Pipeline.examine(m: Module, built: Pipeline.Built, judged?: boolean, hints?: ErrorRender.Hints, text?: string): string
  if text ~= nil and built.build:replace(m.path, text) == nil then
    return m.file .. ": the new checker's build has no module " .. m.path
  end
  local made, why = generated_of(m, built, false, judged, hints, false, true)
  note_standing(m, built)
  built.build:retire(m.path)
  if made == nil then
    return why
  end
  return ""
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

--- Records in `stages` the stage of each of `list`, the findings of one stage, by place and code ([`Pipeline.Alone`]'s `stages`).
local function note_stages(stages: mut {string: string}, stage: string, list: {Driver.Problem})
  for _, p in ipairs(list) do
    local key = tostring(p.y) .. ":" .. tostring(p.x) .. ":" .. p.code
    local was = stages[key]
    if was ~= nil and was ~= stage then
      stages[key] = ""
    else
      stages[key] = stage
    end
  end
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
    return { code = nil, lines = { spec_trouble }, stages = {} }
  end
  build:lower({ module })
  local result = build:result(module, true)
  if result == nil then
    return { code = nil, lines = { file .. ": the new checker's build has no module " .. module }, stages = {} }
  end
  local told: mut {string} = {}
  local stages: mut {string: string} = {}
  if result.broken then
    for _, p in ipairs(result.syntax) do
      told[#told + 1] = ErrorRender.line(file, p)
    end
  else
    -- What the file returns is its entry point ([`build.standalone`]) or, for a chunk of `cosmic -e`, its exit code, which
    -- nothing requires and so no declaration needs to describe: the one error a lone file is allowed, at every `return`,
    -- whatever it returns.
    for _, line in ipairs(build:held(result, false, { checked = { "export_not_declared" } })) do
      told[#told + 1] = line
    end
    note_stages(stages, "scoped", result.scope_errors)
    note_stages(stages, "declared", result.declared)
    note_stages(stages, "checked", result.bodies)
    for _, w in ipairs(result.warnings) do
      told[#told + 1] = ErrorRender.line(file, w)
    end
    if options.project == true then
      for _, line in ipairs(ProjectRefusals.check(file, result.chunk, result.scoped)) do
        told[#told + 1] = line
      end
    end
  end
  if #told > 0 then
    return { code = nil, lines = told, stages = stages }
  end
  -- A file alone keeps an import it reads as a type only: nothing serves the module it names.
  local emitted = CompileGrammar.emit(build, result, false, true, false)
  if emitted.code == nil then
    return { code = nil, lines = { file .. ": the generator wrote no Lua: " .. emitted.trouble }, stages = stages }
  end
  return { code = emitted.code, lines = {}, stages = stages }
end

function Pipeline.lone(file: string, text: string, options: Pipeline.Options, tests?: boolean): string?, string
  local made = Pipeline.checked_alone(file, text, options, tests)
  if made.code == nil then
    return nil, table.concat(made.lines, "\n")
  end
  return made.code, ""
end

return Pipeline
