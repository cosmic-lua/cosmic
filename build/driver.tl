--- The driver of the new checker: one program built over the modules of a build, and for each module the answer a
--- build, a check of the tree or `cosmic compile` reads.
---
--- A [`Driver.Build`] holds one [`Declarations.Program`], the store of every type, and asks its *providers* for the
--- module a `require` names: [`Driver.files`] (the sources of a tree, `.tl` and `.d.tl`, each under the names a
--- `require` may use), [`Driver.standard`] (the `cosmic.*` modules, each its source or its stub, from wherever the
--- host keeps them) and [`Driver.stubs`] (modules whose text is given, left unchecked). The *global* sources, the
--- declaration files of the standard library, are lowered first and declare the globals every module may use; the
--- text of the standard library is [`lang/stdlib.d.tl`], in the new grammar like the rest of the globals. A source is read as
--- written.
---
--- A module is lexed, parsed and scoped when first asked for, lowered ([`lang.declarations`]) after what it requires
--- (a cycle is lowered in the order it is met: the provider declares the other side first) and checked
--- ([`lang.check`]) on request. Each [`Driver.Outcome`] carries the errors of every stage and the warnings
--- ([`lang.warnings`]), each in source order, and the type of every node the checker typed, by the id of the node:
--- the report that [`build.syntax_receivers`], [`build.syntax_shape_specs`] and [`build.syntax_contracts`] read. A module that is not checked (a library, a stub, a binding) is lowered and has no body errors.
---
--- An error about a name cosmic removed (`os`, `Hash.hex`, `Zip.ZipReader`) has the replacement as its fix
--- ([`build.removed_fix`]).
---
--- A caller that is done with a module retires it ([`Driver.Build.retire`]): the program keeps the declarations the next module
--- reads, and the tokens, the syntax tree and the scopes of the module go. Asked for the modules in the order they require one
--- another, a build holds one module's syntax at a time and not the tree's.
---
--- The markers ([`build.ceilings`]) are enforced for a module by [`Driver.Build.held`]: an error with no marker on its line
--- is refused, with the same words as the check of the tree. A module that did not parse is refused for that alone.
---
--- Its callers are [`build.tree_checks`], `cosmic compile` ([`build.compile_grammar`]) and the pipeline of the
--- new checker ([`build.pipeline`]), which the build's own compile calls ([`build.importer`]).
local Ast = require("lang.ast")
local Ceilings = require("build.ceilings")
local Check = require("lang.check")
local Clock = require("cosmic.clock")
local Declarations = require("lang.declarations")
local Lexer = require("lang.lexer")
local RemovedFix = require("build.removed_fix")
local Scopes = require("lang.scopes")
local SourceParse = require("build.source_parse")
local Truthiness = require("lang.truthy")
local Types = require("lang.types")

local record Driver
  --- The text of a module and what the driver does with it ([`build.source_parse`]).
  type Source = SourceParse.Source

  --- What answers for the module a `require` names: its source, or nil where it has none.
  type Provider = function(module: string): Source?

  --- Whether an expression can be neither false nor nil ([`Driver.Outcome.never_false`]).
  type Truthy = function(e: Ast.Exp): boolean

  --- What a caller knows of a file of an index that its name does not say: whether it is a test module.
  type Extra = SourceParse.Extra

  --- What a caller knows of the file `file`, whose text is `text`.
  type Extras = SourceParse.Extras

  --- What reads the text of a `cosmic.*` module for [`Driver.standard`]: its source or its stub, nil where there is none.
  type Reader = function(module: string): string?

  --- An error or a warning of a module ([`build.source_parse`]).
  type Problem = SourceParse.Problem

  --- What a module came to.
  record Outcome
    module: string
    source: Source
    --- The text the checker reads: the source's text, or the text a [`Driver.Build.replace`] gave.
    text: string
    --- Whether an expression can be neither false nor nil, from its syntax alone ([`lang.truthy`]),
    --- for the code generator's `if` expressions: set for every source. A file writes an `if` expression only for a value
    --- that cannot be false; the generator is told what the rule knows, or it writes a function called on the spot where a
    --- file writes `and`/`or`.
    never_false: Truthy?
    chunk: Ast.Chunk
    scoped: Scopes.Scoped
    --- Whether the text did not parse: it is lowered as far as its tree goes, for the modules that require it, and a
    --- check counts nothing of it.
    broken: boolean
    --- What lowering made: nil until the module is lowered.
    mut lowered: Declarations.Lowered?
    --- What checking made: nil until the module is checked, and for a module that is not.
    mut checked: Check.Checked?
    --- The errors of each stage, in source order.
    syntax: {Problem}
    mut scope_errors: mut {Problem}
    declared: mut {Problem}
    bodies: mut {Problem}
    --- Every error, in source order, and the warnings.
    mut errors: {Problem}
    warnings: mut {Problem}
    --- The type of each node the checker typed (an expression) or lowered (a type), by the id of the node.
    mut types: {integer: Types.Type}
    --- The function each call and method call took, by the id of the call node ([`Check.Checked.callees`]).
    mut callees: {integer: Types.Type}
  end

  --- The nanoseconds a build spent in each phase, for the speed of a run.
  record Timing
    --- Lexing, parsing and scoping.
    mut prepare: integer
    mut lower: integer
    mut check: integer
    --- How many modules the program lowered (not the time), for a test that a module was not lowered again.
    mut lowerings: integer
  end

  record Options
    --- The declaration files of the standard library, in the order they are lowered: each declares globals.
    globals: {Source}
    --- Called with the globals the sources declared, to take away the ones the host withholds and add the ones it
    --- provides.
    adjust: (function(globals: {string: Scopes.Global}))?
    --- The modules that are bindings of C, whose types the checker does not read: a type name of one is `invalid`.
    external: {string}
    --- The names of the language's own modules ([`Declarations.Program.library`]); none where not given.
    library?: {string: boolean}
    --- What a `require` of `name` in the file `file` that names no module may have meant, as "`b.m` (b/m.tl)" each: the modules
    --- ending in the name ([`Driver.ending`]) that `file` may require, none where the build is not given one.
    meant?: function(name: string, file: string): {string}
    --- Whether the checker keeps the type of each node: the `types` of a result. A run that reads none leaves it, and saves the
    --- time of recording them.
    types: boolean
  end

  --- A build.
  record Build
    mut program: Declarations.Program
    --- The calls of [`Shape.record_of`] a module of the tree makes that [`build.tree_program`] could not resolve before it lowered the module, one line each.
    problems: mut {string}
    timing: Timing
    --- Asks `provider` for a module after the providers added before it.
    mut provide: function(Build, provider: Provider)
    --- The module `name` (or, of a declaration file of the globals, one of its aliases) lexed, parsed and scoped, nil where no provider has it.
    mut parsed: function(Build, name: string): Outcome?
    --- Whether the build has the module `name`: a global source, a module a provider has, or one it has retired. Nothing is read
    --- to tell.
    mut provides: function(Build, name: string): boolean
    --- Lowers the modules `names`, each after what it requires, and the globals before them.
    mut lower: function(Build, names: {string})
    --- The result for `name`, lowered with what it requires. With `bodies` its bodies are checked too. nil where no
    --- provider has it. Call it for the modules you want, after [`Driver.Build.lower`] of all of them, since the
    --- errors of a module's declarations include checks that waited for a module lowered later.
    mut result: function(Build, name: string, bodies: boolean): Outcome?
    --- The lines that refuse `result`: its syntax errors, and for each stage the errors of a code on a line whose markers do not
    --- hold them, each with its place and fix and then the count on the line and what is marked. None where the module is
    --- held. The stages are those of the tree's checks, over the same text: a module is held to its `scoped`, `declared` and
    --- `checked` markers, and to no syntax error. A module whose bodies were not checked is told so. With `markers` false (a
    --- project's, which no marker holds) every error is refused, and the lines point to no marker. `free` names, by stage
    --- (`scoped`, `declared`, `checked`), the codes that stage never refuses: a code free in one stage is still refused in
    --- another that has it.
    mut held: function(Build, result: Outcome, markers: boolean, free?: {string: {string}}): {string}
    --- Replaces the text of the module `name` with `text`, and answers its outcome, or nil where no provider has `name`. A module cannot be lowered twice in one program, so
    --- the program forgets the module and every module that requires it, through others as well ([`Declarations.forget`]),
    --- and lowers them again when they are next asked for, from the syntax tree the build has already; the others keep
    --- what is lowered, those retired among them, and a retired module that requires it is read from its source again. An
    --- outcome answered before for a module forgotten is no longer the build's. Where the module replaced, or one that
    --- requires it, declares a global, the build begins a new program and lowers every module again. The splices of [`build.syntax_shape_specs`] are
    --- made in the text of [`Driver.Outcome.text`] and checked this way.
    mut replace: function(Build, name: string, text: string): Outcome?
    -- TODO: write the declarations of a retired module ([`Types.encode_declaration`]) and its verdict to the working database,
    -- and read them back when a module requires it, once [`Declarations.Program`] can load a module from rows: its entries,
    -- aliases, statics and values have no text, and a store reads only declarations through [`Types.Loader`]. Measured over the
    -- tree (1182 modules, 2270 declarations): 0.91 MB serialized (median 96 B and p90 1.6 KB a module), and some 25 MB of the
    -- 1.5 GB a build held before modules were retired, so the rows would save little memory; they would let a build read a
    -- module's declarations without reading its source.
    --- Forgets the tokens, the syntax tree, the scopes and the result of the module `name` (and of the names it answers to):
    --- what the program knows of its declarations stays, so a module that requires it is lowered as before. The tokens,
    --- the tree and the scopes of a module are most of what a build holds, and the declarations the next module reads are a
    --- small part of it, so a caller that is done with a module retires it, and asks for the modules in the order they
    --- require one another. A module read again by [`Driver.Build.parsed`] is a new reading, outside the program;
    --- [`Driver.Build.lower`] and [`Driver.Build.result`] answer nothing for it. A declaration file that declares
    --- globals is not forgotten.
    mut retire: function(Build, name: string)
    --- Whether the module `name` was retired ([`Driver.Build.retire`]) and no replacement has begun the program again since.
    mut retired: function(Build, name: string): boolean
    --- [`Driver.Build.retire`] of every module the build holds but those `keep` answers true for: for a build whose result
    --- for a module is read once it is lowered, and whose lowering of the modules it requires is not read at all.
    mut retire_all: function(Build, keep?: function(Outcome): boolean)
    --- A build of its own over the same options and providers, made when first asked for and the same afterwards: a caller
    --- reads a module in it without lowering the module here. Its program, and what it holds of the modules read in it, are
    --- its own; a module of this build is not retired in it.
    mut scratch: function(Build): Build
  end

  --- A build over `options`.
  new: function(options: Options): Build

  --- A source with the defaults: checked, no alias, and a test module only where `tests`.
  source: function(module: string, filename: string, text: string, dialect: Ast.Dialect, tests?: boolean): Source

  --- A declaration file whose globals every module may use ([`Driver.Options.globals`]): not checked, answering to `aliases` as
  --- well.
  declarations: function(module: string, filename: string, text: string, aliases: mut {string}): Source

  --- The sources of a tree and the names they answer to.
  type Index = SourceParse.Index

  --- The modules `entries` (pairs of a path below the root and its text) are: each `.tl` and `.d.tl` a module named by its
  --- path ([`Declarations.module_of`]), checked. A module is answered to by that name alone, the one the run time resolves:
  --- `b/m.tl` is `b.m`, never `m`. A project inside the tree names its modules from its own root by being built from there.
  --- `skip` says which paths are left out. A module
  --- given as both `.tl` and `.d.tl` is refused before an index is made ([`Driver.declared`]); two files that are one module
  --- otherwise (`x.tl` and `x/init.tl`, or `x.d.tl` and `x/init.d.tl`) are refused by the derive ([`build.derivation`]),
  --- and are not given here. A `*_test.tl` is a test module
  --- ([`Driver.Source.tests`]). An entry may give a third word, the module it is, and a fourth, the name its findings
  --- are kept under ([`Driver.Source.pinned`]), for a source the build writes from another file, whose path says
  --- neither: the entry's path is then the name of the text, and `.d.tl` still marks a declaration. `extras` says of a file
  --- what its name does not: a test module ([`Driver.Source.tests`]).
  index: function(entries: {{string}}, skip: function(path: string): boolean, extras?: Extras): Index

  --- The complaints about the files of `entries` (as [`Driver.index`] takes them, less the `skip`ped paths) whose module is
  --- one of `names`: a project's `require("math")` would be checked against `math.tl`, where the binary answers that call
  --- with its own module. One to a line and in the order of the files: "" for none.
  reserved: function(entries: {{string}}, skip: function(path: string): boolean, names: {string: boolean}): string

  --- The files a module may be written in below the root, in the order a declaration comes before a source: `x.d.tl`,
  --- `x/init.d.tl`, `x.tl`, `x/init.tl`.
  candidates: function(module: string): {string}

  --- Why a declaration file and a source of one module may not both be given: the complaint of `declaration` (a `.d.tl`)
  --- standing beside `source` (a `.tl`), both the module `module`. It offers both ways out: delete the declaration, or
  --- rename one of the two so that they are different modules.
  pairing: function(declaration: string, source: string, module: string): string

  --- Why the declaration file `file` (below the root) with `text` may not be a build's: "" where its leading comment names
  --- exactly one kind, `--- @kind binding` (a module implemented in C) or `--- @kind language` (the language's own
  --- declarations, allowed only for the two files that are the build's globals, [`build.analysis_schema`]'s
  --- `is_language_file`, and only where `own` says the build is cosmic's own tree: a project has no such declarations,
  --- whatever it names its files). Else the complaint, which offers both ways out: tag it a binding, or write it as a `.tl`,
  --- whose types and code are checked and real at run time; the language's two files that name nothing are told to say
  --- `language`, and a file that names two kinds, to name one. A file that is no `.d.tl` is none of this helper's.
  naming: function(file: string, text: string, own: boolean): string

  --- Every complaint about the declaration files of `entries` (as [`Driver.index`] takes them, less the `skip`ped paths):
  --- those of [`Driver.pairing`] for a `.d.tl` beside a source of its module, and those of [`Driver.naming`] for a `.d.tl`
  --- that is in no pair, one to a line and in the order of the declarations: "" for none. What a build refuses a tree or
  --- project for before an index is made.
  declared: function(entries: {{string}}, skip: function(path: string): boolean, own: boolean): string

  --- The provider of `index`.
  files: function(index: Index): Provider

  --- The sources of `index` whose modules' names end in `.name`, by module: what a `require("name")` that names no module may
  --- have meant, since a module is required by its whole name.
  ending: function(index: Index, name: string): {Source}

  --- The provider of the `cosmic.*` modules `read` finds, each its stub or its source: `read` answers the text of a
  --- module, or nil. They are lowered for the types they give and never checked. A module `declared` says is one is read as a
  --- declaration file, which has no code.
  standard: function(read: Reader, declared?: function(module: string): boolean): Provider

  --- The provider of the modules whose text is `texts`, by name, unchecked.
  stubs: function(texts: {string: string}): Provider

  --- The globals the `sources` declare, `adjust`ed: what a scope builder is given for a module.
  globals: function(sources: {Source}, adjust: (function(globals: {string: Scopes.Global}))?): {string: Scopes.Global}

  --- A source as a build reads it, and no more: its text lexed and parsed ([`build.source_parse`]).
  type Parsed = SourceParse.Parsed
  parse: function(source: Source): Parsed
end

Driver.source = SourceParse.source
Driver.declarations = SourceParse.declarations
Driver.parse = SourceParse.parse
Driver.index = SourceParse.index
Driver.pairing = SourceParse.pairing
Driver.naming = SourceParse.naming
Driver.declared = SourceParse.declared

local type Read = SourceParse.Read
local make = SourceParse.make
local read_source = SourceParse.read
local global_read = SourceParse.remembered

function Driver.globals(sources: {Driver.Source}, adjust: (function(globals: {string: Scopes.Global}))?):
    {string: Scopes.Global}
  local out: mut {string: Scopes.Global} = {}
  for _, source in ipairs(sources) do
    for name, g in pairs(Scopes.declared(global_read(source).chunk)) do
      out[name] = g
    end
  end
  if adjust ~= nil then
    adjust(out)
  end
  return out
end

function Driver.candidates(module: string): {string}
  local stem = module:gsub("%.", "/")
  return { stem .. ".d.tl", stem .. "/init.d.tl", stem .. ".tl", stem .. "/init.tl" }
end

function Driver.reserved(entries: {{string}}, skip: function(path: string): boolean, names: {string: boolean}): string
  local found: mut {string} = {}
  for _, entry in ipairs(entries) do
    local file = entry[1]
    if file ~= nil and entry[2] ~= nil and not skip(file) then
      local module = entry[3] or Declarations.module_of(file)
      if names[module] == true then
        found[#found + 1] = file .. ": its module is named for `" .. module .. "`, which the binary answers at run time with the " ..
          "language's own module, so a project file of that name would be checked as one thing and run as another: " ..
          "rename it (for example to `" .. module .. "_lib`)"
      end
    end
  end
  table.sort(found)
  return table.concat(found, "\n")
end

function Driver.files(index: Driver.Index): Driver.Provider
  return function(module: string): Driver.Source?
    return index.by_module[module]
  end
end

function Driver.ending(index: Driver.Index, name: string): {Driver.Source}
  local found: mut {Driver.Source} = {}
  local tail = "." .. name
  for _, source in ipairs(index.sources) do
    local module = source.module
    if index.by_module[module] == source and #module > #tail and module:sub(-#tail) == tail then
      found[#found + 1] = source
    end
  end
  table.sort(found, function(a: Driver.Source, b: Driver.Source): boolean
    return a.module < b.module
  end)
  return found
end

function Driver.standard(read: Driver.Reader, declared?: function(module: string): boolean): Driver.Provider
  return function(module: string): Driver.Source?
    local found = read(module)
    if found == nil then
      return nil
    end
    local text: string = found
    local file = module:gsub("%.", "/")
    if declared ~= nil and declared(module) then
      return Driver.declarations(module, file .. ".d.tl", text, {})
    end
    local name = file .. ".tl"
    return make(module, name, text, "tl", false, {}, false, "")
  end
end

function Driver.stubs(texts: {string: string}): Driver.Provider
  return function(module: string): Driver.Source?
    local text = texts[module]
    if text == nil then
      return nil
    end
    return make(module, module:gsub("%.", "/") .. ".tl", text, "tl", false, {}, false, "")
  end
end

--- Whether a build has started.
local record Flag
  mut done: boolean
end

--- A module the build has read: its input, and whether it is lowered and checked.
local record Entry
  result: Driver.Outcome
  input: Declarations.Input
  mut lowered: boolean
  --- Whether it and everything it requires is lowered.
  mut closed: boolean
  mut checked: boolean
  mut bodies: boolean
end

local function problem_of(kind: string, stage: string, code: string, msg: string, fix: string, y: integer, x: integer,
                          offset: integer): Driver.Problem
  return { kind = kind, stage = stage, code = code, msg = msg, fix = fix, y = y, x = x, offset = offset, removed = false }
end

--- The problem for an error: its fix is the words of [`cosmic.removed`] where it is about a name cosmic removed
--- ([`build.removed_fix`]), else the fix the checker wrote.
local TEMPLATE_CONDITION <const> = "`{{if}}` and `{{with}}` need a value that can be absent: make the field optional, or " ..
  "drop the `{{if}}`"

local function error_of(result: Driver.Outcome, stage: string, code: string, msg: string, fix: string, y: integer, x: integer,
                        offset: integer, length: integer, types: {string}, argument?: Check.Argument): Driver.Problem
  local instead = RemovedFix.fix({ tokens = result.chunk.tokens, scoped = result.scoped }, code, offset, length, types)
  -- A condition of a template is written by the generator, over a local it names: the checker's fix would tell the template's
  -- author to write a test of that local. What a template can say is whether a value is there.
  local file = result.source.filename
  if result.source.pinned ~= "" then
    file = result.source.pinned
  end
  local told = instead or fix
  if instead == nil and code == "condition_type" and file:match("%.tmpl$") ~= nil and
      msg:find("no boolean or optional", 1, true) ~= nil then
    told = TEMPLATE_CONDITION
  end
  return {
    kind = "error", stage = stage, code = code, msg = msg, fix = told, y = y, x = x, offset = offset,
    removed = instead ~= nil, argument = argument,
  }
end

--- `list` in source order: by offset, and where two are at one offset in the order they were found.
local function in_order(list: mut {Driver.Problem}): {Driver.Problem}
  local place: mut {Driver.Problem: integer} = {}
  for index, p in ipairs(list) do
    place[p] = index
  end
  table.sort(list, function(a: Driver.Problem, b: Driver.Problem): boolean
    if a.offset ~= b.offset then
      return a.offset < b.offset
    end
    return (place[a] or 0) < (place[b] or 0)
  end)
  return list
end

--- The top-level `local function test_*` of a module: the offsets of their names, which a test module's runner calls.
local function test_functions(scoped: Scopes.Scoped, tokens: Lexer.Tokens): {integer: boolean}
  local out: mut {integer: boolean} = {}
  for _, v in ipairs(scoped.list) do
    if v.kind == "function" and v.top and v.name:sub(1, 5) == "test_" then
      local offset = tokens.offset[v.declared]
      if offset ~= nil then
        out[offset] = true
      end
    end
  end
  return out
end

--- A program for the bindings of C `external` names.
local function program_of(external: {string}, library: {string: boolean}?): Declarations.Program
  local program = Declarations.new(nil, library)
  for _, name in ipairs(external) do
    program.external[name] = true -- checked: view_written
  end
  return program
end

function Driver.new(options: Driver.Options): Driver.Build
  local build: Driver.Build = {
    program = program_of(options.external, options.library), problems = {}, timing = { prepare = 0, lower = 0, check = 0, lowerings = 0 },
    provide = function(_self: Driver.Build, _provider: Driver.Provider) end,
    parsed = function(_self: Driver.Build, _name: string): Driver.Outcome? return nil end,
    provides = function(_self: Driver.Build, _name: string): boolean
      return false
    end,
    lower = function(_self: Driver.Build, _names: {string}) end,
    result = function(_self: Driver.Build, _name: string, _bodies: boolean): Driver.Outcome?
      return nil
    end,
    held = function(_self: Driver.Build, _result: Driver.Outcome, _markers: boolean, _free?: {string: {string}}): {string}
      return {}
    end,
    replace = function(_self: Driver.Build, _name: string, _text: string): Driver.Outcome?
      return nil
    end,
    retire = function(_self: Driver.Build, _name: string) end,
    retired = function(_self: Driver.Build, _name: string): boolean
      return false
    end,
    retire_all = function(_self: Driver.Build, _keep?: function(Driver.Outcome): boolean) end,
    scratch = function(self: Driver.Build): Driver.Build
      return self
    end,
  }
  local timing = build.timing
  local providers: mut {Driver.Provider} = {}
  local entries: mut {string: Entry} = {}
  local globals: mut {string: Scopes.Global} = {}
  local global_entries: mut {Entry} = {}
  local started_up: Flag = { done = false }
  --- The names of the modules [`Driver.Build.retire`] forgot after the program lowered them, which nothing reads again.
  local retired: mut {string: boolean} = {}
  --- The names each module read requires, by the module: what a replacement follows to the modules that read the one it
  --- replaces, those retired among them, whose syntax tree is gone.
  local needs: mut {string: {string}} = {}
  local scratches: mut {Driver.Build} = {}

  local function find(module: string): Driver.Source?
    for _, provider in ipairs(providers) do
      local source = provider(module)
      if source ~= nil then
        return source
      end
    end
    return nil
  end

  --- What a `require` that names no module may have meant, for the one at `offset` of `result`: "" where the name is a global
  --- of the language (the checker's fix says to use it) or no module that the file may require ends in it, else
  --- "; did you mean `b.m` (b/m.tl)?" or the candidates, "; did you mean one of `a.m` (a/m.tl), `b.m` (b/m.tl)?".
  local function meant(result: Driver.Outcome, offset: integer): string
    local tokens = result.chunk.tokens
    local at = RemovedFix.token_at(tokens, offset)
    if at == nil then
      return ""
    end
    -- `require("m")`: the grammar refuses `require "m"` (string_call) before it is a require.
    if tokens.kind[at + 2] ~= "string" then
      return ""
    end
    local name = tokens.value[at + 2]
    local ending = options.meant
    local library = options.library
    if name == nil or ending == nil or (library ~= nil and library[name] == true) then
      return ""
    end
    local found = ending(name, result.source.filename)
    if #found == 0 then
      return ""
    elseif #found == 1 then
      return "; did you mean " .. found[1] .. "?"
    end
    -- A long list is a wall of text: the first few say what kind of name was meant.
    local shown = 5
    if #found <= shown then
      return "; did you mean one of " .. table.concat(found, ", ") .. "?"
    end
    return "; did you mean one of " .. table.concat(found, ", ", 1, shown) .. " and " .. tostring(#found - shown) ..
      " more?"
  end

  --- The entry for a source that has been read: scoped against the globals.
  local function entry_of(read: Read): Entry
    local source = read.source
    local scoped = Scopes.build(read.chunk, source.filename, globals)
    local required: mut {string} = {}
    for _, r in ipairs(read.chunk.requires) do
      required[#required + 1] = r.module
    end
    needs[source.module] = required
    local syntax: mut {Driver.Problem} = {}
    for _, e in ipairs(read.errors) do
      syntax[#syntax + 1] = problem_of("error", "syntax", tostring(e.code), e.msg, e.fix, e.y, e.x, e.offset)
    end
    local result: Driver.Outcome = {
      module = source.module, source = source, text = read.text, never_false = Truthiness.never_false, chunk = read.chunk,
      scoped = scoped, broken = #syntax > 0, lowered = nil, checked = nil, syntax = syntax, scope_errors = {},
      declared = {}, bodies = {}, errors = {}, warnings = {}, types = {}, callees = {},
    }
    return {
      result = result, lowered = false, closed = false, checked = false, bodies = false,
      input = {
        module = source.module, filename = source.filename, chunk = read.chunk, dialect = source.dialect, scoped = scoped,
      },
    }
  end

  --- An entry as it was read, with nothing lowered or checked of it: for a new program.
  local function unlowered(entry: Entry): Entry
    local old = entry.result
    local result: Driver.Outcome = {
      module = old.module, source = old.source, text = old.text, never_false = old.never_false, chunk = old.chunk,
      scoped = old.scoped, broken = old.broken, lowered = nil, checked = nil, syntax = old.syntax, scope_errors = {},
      declared = {}, bodies = {}, errors = {}, warnings = {}, types = {}, callees = {},
    }
    return {
      result = result, lowered = false, closed = false, checked = false, bodies = false, input = entry.input,
    }
  end

  local function alias_all(entry: Entry)
    for _, name in ipairs(entry.result.source.aliases) do
      build.program:alias(name, entry.result.module)
    end
  end

  local function lower_entry(entry: Entry)
    if entry.lowered then
      return
    end
    entry.lowered = true
    local started = Clock.monotonic_ns()
    entry.result.lowered = build.program:lower(entry.input)
    timing.lower = timing.lower + Clock.monotonic_ns() - started
    timing.lowerings = timing.lowerings + 1
    alias_all(entry)
  end

  --- Reads the global sources and lowers them, once: the globals are what every module is scoped against.
  local function start()
    if started_up.done then
      return
    end
    started_up.done = true
    local started = Clock.monotonic_ns()
    local reads: mut {Read} = {}
    for _, source in ipairs(options.globals) do
      local read = global_read(source)
      reads[#reads + 1] = read
      for name, g in pairs(Scopes.declared(read.chunk)) do
        globals[name] = g
      end
    end
    local adjust = options.adjust
    if adjust ~= nil then
      adjust(globals)
    end
    for _, read in ipairs(reads) do
      local entry = entry_of(read)
      entries[read.source.module] = entry
      for _, name in ipairs(read.source.aliases) do
        entries[name] = entry
      end
      global_entries[#global_entries + 1] = entry
    end
    timing.prepare = timing.prepare + Clock.monotonic_ns() - started
    for _, entry in ipairs(global_entries) do
      lower_entry(entry)
    end
  end

  local function prepare(name: string): Entry?
    start()
    local held = entries[name]
    if held ~= nil then
      return held
    end
    if retired[name] == true then
      return nil
    end
    local source = find(name)
    if source == nil then
      return nil
    end
    if retired[source.module] == true then
      retired[name] = true
      return nil
    end
    held = entries[source.module]
    if held == nil then
      local started = Clock.monotonic_ns()
      held = entry_of(read_source(source))
      timing.prepare = timing.prepare + Clock.monotonic_ns() - started
      entries[source.module] = held
    end
    entries[name] = held
    return held
  end

  --- Makes `program` answer the modules a `require` names from the entries.
  local function attach()
    build.program.provider = function(self: Declarations.Program, module: string): boolean -- checked: field_fixed
      local entry = prepare(module)
      if entry == nil then
        return false
      end
      self:declare(entry.input)
      alias_all(entry)
      return true
    end
  end
  attach()

  --- Forgets `entry`, under every name it answers to. The program keeps what it lowered of it.
  local function release(entry: Entry, lowered: boolean)
    for key, held in pairs(entries) do
      if held == entry then
        entries[key] = nil
        if lowered then
          retired[key] = true
        end
      end
    end
  end

  build.provide = function(_self: Driver.Build, provider: Driver.Provider)
    providers[#providers + 1] = provider
  end

  build.provides = function(_self: Driver.Build, name: string): boolean
    start()
    return entries[name] ~= nil or retired[name] == true or find(name) ~= nil
  end

  build.parsed = function(_self: Driver.Build, name: string): Driver.Outcome?
    local entry = prepare(name)
    if entry == nil then
      if retired[name] == true then
        -- A new reading, outside the program: the module is lowered in it already.
        start()
        local source = find(name)
        if source ~= nil then
          return entry_of(read_source(source)).result
        end
      end
      return nil
    end
    return entry.result
  end

  --- Whether `entry` is one of the declaration files that declare the globals.
  local function declares_globals(entry: Entry): boolean
    for _, declaring in ipairs(global_entries) do
      if declaring == entry then
        return true
      end
    end
    return false
  end

  --- The module `name` stands for: the one its entry reads, or the program knows it as, or `name`.
  local function canonical(name: string): string
    local entry = entries[name]
    if entry ~= nil then
      return entry.result.module
    end
    local info = build.program.modules[name]
    if info ~= nil then
      return info.name
    end
    return name
  end

  --- `module` and the modules that require it, or require one of those, whether the build holds them or retired them.
  local function dependents(module: string): {string: boolean}
    local set: mut {string: boolean} = { [module] = true }
    local grew = true
    while grew do
      grew = false
      for name, required in pairs(needs) do
        if set[name] ~= true then
          for _, r in ipairs(required) do
            if set[canonical(r)] == true then
              set[name] = true
              grew = true
              break
            end
          end
        end
      end
    end
    return set
  end

  --- The text of `held`, which the program has met, put in place of it in a new program, where every module is lowered again,
  --- those retired among them when they are next asked for.
  local function begin_again(held: Entry, fresh: Entry)
    for key in pairs(retired) do
      retired[key] = nil
    end
    -- Every entry again, each name answering to the entry its old one was.
    local made: mut {Entry: Entry} = {}
    local function again(entry: Entry): Entry
      if entry == held then
        return fresh
      end
      local kept = made[entry]
      if kept == nil then
        kept = unlowered(entry)
        made[entry] = kept
      end
      return kept
    end
    local names: mut {string: Entry} = {}
    for key, entry in pairs(entries) do
      names[key] = again(entry)
    end
    for key, entry in pairs(names) do
      entries[key] = entry
    end
    local replaced: mut {Entry} = {}
    for _, entry in ipairs(global_entries) do
      local swapped = again(entry)
      replaced[#replaced + 1] = swapped
    end
    global_entries = replaced
    build.program = program_of(options.external, options.library)
    attach()
    for _, entry in ipairs(global_entries) do
      lower_entry(entry)
    end
  end

  --- Forgets `set`, the modules that read the one replaced, in the program that keeps the rest: false, with nothing changed,
  --- where one of them declares a global, which a module that does not require it may name.
  local function forget_dependents(held: Entry, fresh: Entry, set: {string: boolean}): boolean
    for _, entry in ipairs(global_entries) do
      if set[entry.result.module] == true then
        return false
      end
    end
    local names: mut {string} = {}
    for module in pairs(set) do
      names[#names + 1] = module
    end
    -- The names the modules answer to, before the program forgets them.
    local answered: mut {string: boolean} = {}
    for key, info in pairs(build.program.modules) do
      if set[info.name] == true then
        answered[key] = true
      end
    end
    if not Declarations.forget(build.program, names) then
      return false
    end
    for key in pairs(retired) do
      if answered[key] == true or set[key] == true then
        retired[key] = nil
      end
    end
    local made: mut {Entry: Entry} = {}
    local swaps: mut {string: Entry} = {}
    for key, entry in pairs(entries) do
      if entry == held then
        swaps[key] = fresh
      elseif set[entry.result.module] == true then
        local kept = made[entry]
        if kept == nil then
          kept = unlowered(entry)
          made[entry] = kept
        end
        swaps[key] = kept
      end
    end
    for key, entry in pairs(swaps) do
      entries[key] = entry
    end
    return true
  end

  -- TODO: keep what is lowered of the other modules across the replacement of a declaration file of the globals, or of a module
  -- one requires, once a Declarations.Program forgets the globals and values of a module (lang/declarations.tl, `globals` and
  -- `values`): a module that names a global needs no `require`, so the program begins again for such a replacement.
  build.replace = function(_self: Driver.Build, name: string, text: string): Driver.Outcome?
    local held = prepare(name)
    if held == nil then
      return nil
    end
    local old = held.result.source
    local source = make(old.module, old.filename, text, old.dialect, old.checked, old.aliases, old.tests, old.pinned)
    local started = Clock.monotonic_ns()
    local fresh = entry_of(read_source(source, text))
    timing.prepare = timing.prepare + Clock.monotonic_ns() - started
    if build.program.modules[old.module] == nil then
      -- The program has not met the module, so nothing in it depends on the text that goes: the text that replaces it
      -- stands in the entries, and every other module stays lowered.
      for key, entry in pairs(entries) do
        if entry == held then
          entries[key] = fresh
        end
      end
      return fresh.result
    end
    -- The modules that do not require the one replaced keep what the program lowered of them; it forgets the others, which
    -- are lowered again when they are next asked for.
    -- The ids of the types forgotten are not given again, and each forgetting reads every id: once the dead are more than the
    -- live the program begins again, so that the store's size and the cost of an edit stay within twice what is live.
    local store = build.program.store
    if store.dead <= store.count - store.dead and not declares_globals(held) and forget_dependents(held, fresh, dependents(old.module)) then
      return fresh.result
    end
    begin_again(held, fresh)
    return fresh.result
  end

  build.lower = function(_self: Driver.Build, names: {string})
    start()
    local state: mut {Entry: boolean} = {}
    local order: mut {Entry} = {}
    local function visit(name: string)
      local entry = prepare(name)
      if entry == nil or state[entry] == true or entry.closed then
        return
      end
      state[entry] = true
      for _, r in ipairs(entry.result.chunk.requires) do
        visit(r.module)
      end
      order[#order + 1] = entry
    end
    for _, name in ipairs(names) do
      visit(name)
    end
    for _, entry in ipairs(order) do
      lower_entry(entry)
      entry.closed = true
    end
  end

  build.retire = function(_self: Driver.Build, name: string)
    local entry = entries[name]
    if entry == nil or declares_globals(entry) then
      return
    end
    release(entry, entry.lowered)
  end

  build.retired = function(_self: Driver.Build, name: string): boolean
    return retired[name] == true
  end

  build.retire_all = function(_self: Driver.Build, keep?: function(Driver.Outcome): boolean)
    -- Taking a name out of `entries` while it is walked is allowed; adding one is not, and `release` adds none.
    for _, entry in pairs(entries) do
      if not declares_globals(entry) and (keep == nil or not keep(entry.result)) then
        release(entry, entry.lowered)
      end
    end
  end

  build.scratch = function(_self: Driver.Build): Driver.Build
    local held = scratches[1]
    if held == nil then
      held = Driver.new(options)
      for _, provider in ipairs(providers) do
        held:provide(provider)
      end
      scratches[1] = held
    end
    return held
  end

  build.result = function(self: Driver.Build, name: string, bodies: boolean): Driver.Outcome?
    local entry = prepare(name)
    if entry == nil then
      return nil
    end
    self:lower({ name })
    local result = entry.result
    local source = result.source
    local lowered = result.lowered
    if bodies and not entry.bodies then
      entry.bodies = true
      if source.dialect == "tl" and source.checked and not result.broken and lowered ~= nil then
        local started = Clock.monotonic_ns()
        local checked = Check.check(build.program, entry.input, lowered, options.types)
        timing.check = timing.check + Clock.monotonic_ns() - started
        result.checked = checked
        for _, e in ipairs(checked.errors) do
          local code = tostring(e.code)
          local msg = e.msg
          if code == "require_unknown" then
            msg = msg .. meant(result, e.offset)
          end
          table.insert(result.bodies, error_of(result, "checked", code, msg, e.fix, e.y, e.x, e.offset, e.length, e.types,
            e.argument))
        end
        local exempt: {integer: boolean} = {}
        if source.tests then
          exempt = test_functions(result.scoped, result.chunk.tokens)
        end
        for _, w in ipairs(checked.warnings) do
          if not (w.code == "unused_function" and exempt[w.offset] == true) then
            result.warnings[#result.warnings + 1] = {
              kind = w.kind, stage = "warning", code = w.code, msg = w.msg, fix = w.fix, y = w.y, x = w.x,
              offset = w.offset, removed = false,
            }
          end
        end
        if options.types then
          local types = checked.types
          for id, t in pairs(lowered.types) do
            types[id] = t -- checked: view_written
          end
          result.types = types
          result.callees = checked.callees
        end
      end
    end
    if not entry.checked then
      entry.checked = true
      for _, e in ipairs(result.scoped.errors) do
        table.insert(result.scope_errors, error_of(result, "scoped", tostring(e.code), e.msg, e.fix, e.y, e.x,
          e.offset, e.length, {}))
      end
      if lowered ~= nil then
        for _, e in ipairs(build.program:errors(result.module)) do
          table.insert(result.declared, error_of(result, "declared", tostring(e.code), e.msg, e.fix, e.y, e.x,
            e.offset, e.length, e.types))
        end
      end
    end
    local all: mut {Driver.Problem} = {}
    for _, list in ipairs({ result.syntax, result.scope_errors, result.declared, result.bodies }) do
      for _, p in ipairs(list) do
        all[#all + 1] = p
      end
    end
    result.errors = in_order(all)
    return result
  end

  build.held = function(_self: Driver.Build, result: Driver.Outcome, markers: boolean, free?: {string: {string}}): {string}
    local out: mut {string} = {}
    local source = result.source
    local file = source.filename
    if source.pinned ~= "" then
      file = source.pinned
    end
    local function stage(list: {Driver.Problem}, codes: {string}, name: Ceilings.Stage, what: string)
      local exempt: mut {string: boolean} = {}
      for _, code in ipairs((free or {})[tostring(name)] or {}) do
        exempt[code] = true
      end
      local findings: mut {Ceilings.Finding} = {}
      for _, p in ipairs(list) do
        if exempt[p.code] ~= true then
          findings[#findings + 1] = { code = p.code, y = p.y, x = p.x, msg = p.msg, fix = p.fix }
        end
      end
      -- The markers are comments of the text itself; a text the build writes from another file has none, and a project's
      -- holds none.
      local text = source.text
      if source.pinned ~= "" or not markers then
        text = ""
      end
      for _, line in ipairs(Ceilings.marked(name, file, text, findings, codes, what, not markers).lines) do
        out[#out + 1] = line
      end
    end
    if result.broken then
      for _, p in ipairs(result.syntax) do
        table.insert(out, file .. ":" .. tostring(p.y) .. ":" .. tostring(p.x) .. ": " .. p.msg .. " (" .. p.code .. "): " .. p.fix)
      end
      return out
    end
    stage(result.scope_errors, Scopes.codes, "scoped", "scopes")
    stage(result.declared, Declarations.codes, "declared", "declarations")
    stage(result.bodies, Check.codes, "checked", "bodies")
    if source.checked and source.dialect == "tl" and result.checked == nil then
      out[#out + 1] = file .. ": its bodies were not checked, so no marker on them was held: ask for the result with the " ..
        "bodies checked"
    end
    return out
  end

  return build
end

return Driver
