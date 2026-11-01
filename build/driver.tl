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
--- The ceilings ([`build.ceilings`]) are enforced for a module by [`Driver.Build.held`]: a count of errors of a code
--- above its ceiling is refused, with the same words as the check of the tree. A module that did not parse is refused
--- for that alone.
---
--- Its callers are [`build.tree_checks`], `cosmic compile` ([`build.compile_grammar`]) and the pipeline of the
--- new checker ([`build.pipeline`]), which the build's own compile calls ([`build.importer`]).
local AnalysisSchema = require("build.analysis_schema")
local Ast = require("lang.ast")
local Ceilings = require("build.ceilings")
local Check = require("lang.check")
local Clock = require("cosmic.clock")
local Declarations = require("lang.declarations")
local Lexer = require("lang.lexer")
local Parser = require("lang.parser")
local RemovedFix = require("build.removed_fix")
local Scopes = require("lang.scopes")
local Truthiness = require("lang.truthy")
local Types = require("lang.types")

local record Driver
  --- The text of a module and what the driver does with it.
  record Source
    --- The name a `require` gives it, and the name of its file in an error.
    module: string
    filename: string
    text: string
    dialect: Ast.Dialect
    --- Whether its bodies are checked and its result carried. A library, a stub and a binding are lowered and not checked.
    checked: boolean
    --- Whether its top-level `local function test_*` are called from outside the file (a test module), so that they are
    --- not unused.
    tests: boolean
    --- The other names a `require` may give it.
    aliases: {string}
    --- The name its ceilings are kept under, "" where that is its `filename`. A source the build writes from another
    --- file (a guide's examples, a template, the declarations of a header) is named for the file it comes from, which
    --- the tree has, where its `filename` names the text written.
    pinned: string
  end

  --- What answers for the module a `require` names: its source, or nil where it has none.
  type Provider = function(module: string): Source?

  --- Whether an expression can be neither false nor nil ([`Driver.Outcome.never_false`]).
  type Truthy = function(e: Ast.Exp): boolean

  --- What a caller knows of a file of an index that its name does not say: whether it is a test module.
  record Extra
    tests: boolean
  end

  --- What a caller knows of the file `file`, whose text is `text`.
  type Extras = function(file: string, text: string): Extra

  --- What reads the text of a `cosmic.*` module for [`Driver.standard`]: its source or its stub, nil where there is none.
  type Reader = function(module: string): string?

  --- An error or a warning of a module.
  record Problem
    --- `error`, or the kind of the warning (`unused`, `unread`, `branch`, `hint`).
    kind: string
    --- The stage that found an error: `syntax`, `scoped`, `declared` or `checked`; `warning` for a warning.
    stage: string
    code: string
    msg: string
    fix: string
    y: integer
    x: integer
    offset: integer
    --- Whether the fix is what to write instead of a name cosmic removed ([`build.removed_fix`]), in place of the checker's own.
    removed: boolean
    --- The call whose argument the checker refused, for an error filed for a value given to a parameter ([`Check.Argument`]); nil
    --- for any other problem.
    argument?: Check.Argument
  end

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
    lowered: Declarations.Lowered?
    --- What checking made: nil until the module is checked, and for a module that is not.
    checked: Check.Checked?
    --- The errors of each stage, in source order.
    syntax: {Problem}
    scope_errors: mut {Problem}
    declared: mut {Problem}
    bodies: mut {Problem}
    --- Every error, in source order, and the warnings.
    errors: {Problem}
    warnings: mut {Problem}
    --- The type of each node the checker typed (an expression) or lowered (a type), by the id of the node.
    types: {integer: Types.Type}
    --- The function each call and method call took, by the id of the call node ([`Check.Checked.callees`]).
    callees: {integer: Types.Type}
  end

  --- The nanoseconds a build spent in each phase, for the speed of a run.
  record Timing
    --- Lexing, parsing and scoping.
    prepare: integer
    lower: integer
    check: integer
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
    --- What a `require` of `name` that names no module may have meant: [`Driver.ending`] over the project's index, none where
    --- the build is not given one (an editor serves its modules from the database, which lists none).
    meant?: function(name: string): {string}
    --- Whether the checker keeps the type of each node: the `types` of a result. A run that reads none leaves it, and saves the
    --- time of recording them.
    types: boolean
  end

  --- A build.
  record Build
    program: Declarations.Program
    --- The calls of [`Shape.record_of`] a module of the tree makes that [`build.tree_program`] could not resolve before it lowered the module, one line each.
    problems: mut {string}
    timing: Timing
    --- Asks `provider` for a module after the providers added before it.
    provide: function(Build, provider: Provider)
    --- The module `name` (or one of its aliases) lexed, parsed and scoped, nil where no provider has it.
    parsed: function(Build, name: string): Outcome?
    --- Whether the build has the module `name`: a global source, a module a provider has, or one it has retired. Nothing is read
    --- to tell.
    provides: function(Build, name: string): boolean
    --- Lowers the modules `names`, each after what it requires, and the globals before them.
    lower: function(Build, names: {string})
    --- The result for `name`, lowered with what it requires. With `bodies` its bodies are checked too. nil where no
    --- provider has it. Call it for the modules you want, after [`Driver.Build.lower`] of all of them, since the
    --- errors of a module's declarations include checks that waited for a module lowered later.
    result: function(Build, name: string, bodies: boolean): Outcome?
    --- The lines that refuse `result` against `ceilings`: its syntax errors, and for each stage the errors of a code above
    --- its ceiling, each with its place and fix and then the count and `pinned N`. None where the module is held. The stages
    --- are those of the tree's checks, over the same text: a module is held to `[scoped]`, `[declared]` and `[checked]`, and
    --- to no syntax error. A module whose bodies were not checked is told so.
    held: function(Build, result: Outcome, ceilings: Ceilings.Table): {string}
    --- Replaces the text of the module `name` with `text`, and answers its outcome, or nil where no provider has `name`. A module cannot be lowered twice in one program, so
    --- the build begins a new one: every module is lowered again, when it is next asked for, from the syntax tree it has
    --- already, and an outcome answered before is no longer the build's. The splices of [`build.syntax_shape_specs`] are
    --- made in the text of [`Driver.Outcome.text`] and checked this way.
    replace: function(Build, name: string, text: string): Outcome?
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
    retire: function(Build, name: string)
    --- Whether the module `name` was retired ([`Driver.Build.retire`]) and no replacement has begun the program again since.
    retired: function(Build, name: string): boolean
    --- [`Driver.Build.retire`] of every module the build holds but those `keep` answers true for: for a build whose result
    --- for a module is read once it is lowered, and whose lowering of the modules it requires is not read at all.
    retire_all: function(Build, keep?: function(Outcome): boolean)
    --- A build of its own over the same options and providers, made when first asked for and the same afterwards: a caller
    --- reads a module in it without lowering the module here. Its program, and what it holds of the modules read in it, are
    --- its own; a module of this build is not retired in it.
    scratch: function(Build): Build
  end

  --- A build over `options`.
  new: function(options: Options): Build

  --- A source with the defaults: checked, no alias, and a test module only where `tests`.
  source: function(module: string, filename: string, text: string, dialect: Ast.Dialect, tests?: boolean): Source

  --- A declaration file whose globals every module may use ([`Driver.Options.globals`]): not checked, answering to `aliases` as
  --- well.
  declarations: function(module: string, filename: string, text: string, aliases: {string}): Source

  --- The sources of a tree and the names they answer to.
  record Index
    sources: mut {Source}
    by_module: mut {string: Source}
  end

  --- The modules `entries` (pairs of a path below the root and its text) are: each `.tl` and `.d.tl` a module named by its
  --- path ([`Declarations.module_of`]), checked. A module is answered to by that name alone, the one the run time resolves:
  --- `b/m.tl` is `b.m`, never `m`. A project inside the tree names its modules from its own root by being built from there.
  --- `skip` says which paths are left out. A module
  --- given as both `.tl` and `.d.tl` is refused before an index is made ([`Driver.declared`]); of two files that are one module
  --- otherwise (`x.tl` and `x/init.tl`) the first given is the module's source, and the other is a source of the index all the
  --- same. A `*_test.tl` is a test module
  --- ([`Driver.Source.tests`]). An entry may give a third word, the module it is, and a fourth, the name its ceilings
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

  --- The modules of `index` whose names end in `.name`, as "`b.m` (b/m.tl)", sorted: what a `require("name")` that names no
  --- module may have meant, since a module is required by its whole name.
  ending: function(index: Index, name: string): {string}

  --- The provider of the `cosmic.*` modules `read` finds, each its stub or its source: `read` answers the text of a
  --- module, or nil. They are lowered for the types they give and never checked. A module `declared` says is one is read as a
  --- declaration file, which has no code.
  standard: function(read: Reader, declared?: function(module: string): boolean): Provider

  --- The provider of the modules whose text is `texts`, by name, unchecked.
  stubs: function(texts: {string: string}): Provider

  --- The globals the `sources` declare, `adjust`ed: what a scope builder is given for a module.
  globals: function(sources: {Source}, adjust: (function(globals: {string: Scopes.Global}))?): {string: Scopes.Global}

  --- A source as a build reads it, and no more: its text lexed and parsed.
  --- The readers of the syntax tree ([`build.syntax_derivation`]) take their tree from this, with the text it was parsed from.
  record Parsed
    text: string
    chunk: Ast.Chunk
    --- The syntax errors, in source order: none for a tree that is whole.
    syntax: {Problem}
  end
  parse: function(source: Source): Parsed
end

local function make(module: string, filename: string, text: string, dialect: Ast.Dialect, checked: boolean,
                    aliases: {string}, tests: boolean, pinned: string): Driver.Source
  return {
    module = module, filename = filename, text = text, dialect = dialect,
    checked = checked, tests = tests, aliases = aliases, pinned = pinned,
  }
end

function Driver.source(module: string, filename: string, text: string, dialect: Ast.Dialect, tests?: boolean): Driver.Source
  return make(module, filename, text, dialect, true, {}, tests == true, "")
end

function Driver.declarations(module: string, filename: string, text: string, aliases: {string}): Driver.Source
  return make(module, filename, text, "decl", false, aliases, false, "")
end

--- A source, read: its text parsed.
local record Read
  source: Driver.Source
  text: string
  never_false: Driver.Truthy?
  chunk: Ast.Chunk
  errors: {Parser.Error}
end

local function read_source(source: Driver.Source, written?: string): Read
  local text = written or source.text
  local parsed = Parser.parse(Lexer.lex(text, source.filename), source.filename, source.dialect)
  return { source = source, text = text, never_false = Truthiness.never_false, chunk = parsed.chunk, errors = parsed.errors }
end

--- The last read of each declaration file that declares the globals, by the file's name. A process that builds many trees
--- (a compile of each step of an edit) lowers the same prelude and standard library into each build's own program, and
--- would parse them again for each: the syntax of a source is read-only to a program, and a build already lowers the same
--- one into a new program ([`Driver.Build`]'s restart), so a read is kept while the text, the dialect and the name of the
--- file are those it was made from. A file with other text is read again, and replaces the one kept: a changed declaration
--- is never served stale.
local record Remembered
  mut reads: mut {string: Read}
end

local remembered: Remembered = { reads = {} }

local function global_read(source: Driver.Source): Read
  local held = remembered.reads[source.filename]
  if held ~= nil and held.text == source.text and held.source.dialect == source.dialect and
      held.source.module == source.module then
    return { source = source, text = held.text, never_false = held.never_false, chunk = held.chunk, errors = held.errors }
  end
  local read = read_source(source)
  remembered.reads[source.filename] = read
  return read
end

function Driver.parse(source: Driver.Source): Driver.Parsed
  local read = read_source(source)
  local syntax: mut {Driver.Problem} = {}
  for _, e in ipairs(read.errors) do
    syntax[#syntax + 1] = {
      kind = "error", stage = "syntax", code = tostring(e.code), msg = e.msg, fix = e.fix, y = e.y, x = e.x, offset = e.offset,
      removed = false,
    }
  end
  return { text = read.text, chunk = read.chunk, syntax = syntax }
end

function Driver.globals(sources: {Driver.Source}, adjust: (function(globals: {string: Scopes.Global}))?):
    {string: Scopes.Global}
  local out: mut {string: Scopes.Global} = {}
  for _, source in ipairs(sources) do
    for name, g in pairs(Scopes.declared(read_source(source).chunk)) do
      out[name] = g
    end
  end
  if adjust ~= nil then
    adjust(out)
  end
  return out
end

function Driver.index(entries: {{string}}, skip: function(path: string): boolean, extras?: Driver.Extras): Driver.Index
  local index: Driver.Index = { sources = {}, by_module = {} }
  for _, entry in ipairs(entries) do
    local file = entry[1]
    local text = entry[2]
    if file ~= nil and text ~= nil and not skip(file) then
      local dialect: Ast.Dialect = "tl"
      if file:match("%.d%.tl$") then
        dialect = "decl"
      end
      local extra: Driver.Extra = { tests = false }
      if extras ~= nil then
        extra = extras(file, text)
      end
      local module = entry[3] or Declarations.module_of(file)
      local source = make(module, file, text, dialect, true, {},
        extra.tests or file:match("_test%.tl$") ~= nil, entry[4] or "")
      index.sources[#index.sources + 1] = source
      if index.by_module[source.module] == nil then
        index.by_module[source.module] = source
      end
    end
  end
  return index
end

function Driver.candidates(module: string): {string}
  local stem = module:gsub("%.", "/")
  return { stem .. ".d.tl", stem .. "/init.d.tl", stem .. ".tl", stem .. "/init.tl" }
end

function Driver.pairing(declaration: string, source: string, module: string): string
  return declaration .. ": " .. source .. " is already the module " .. module .. ". A .d.tl is only for a module " ..
    "implemented in C, and the .tl is what is checked, so one module cannot have both. If the .tl is the module, " ..
    "delete " .. declaration .. ". To keep both, rename one of them so that they are different modules."
end

--- The complaint of each declaration file of `entries` that stands beside a source of its module, keyed by the file.
local function pairs_of(entries: {{string}}, skip: function(path: string): boolean): mut {string: string}
  local sources: mut {string: string} = {}
  for _, entry in ipairs(entries) do
    local file = entry[1]
    if file ~= nil and entry[2] ~= nil and not skip(file) and file:match("%.d%.tl$") == nil then
      local module = entry[3] or Declarations.module_of(file)
      if sources[module] == nil then
        sources[module] = file
      end
    end
  end
  local found: mut {string: string} = {}
  for _, entry in ipairs(entries) do
    local file = entry[1]
    if file ~= nil and entry[2] ~= nil and not skip(file) and file:match("%.d%.tl$") ~= nil then
      local module = entry[3] or Declarations.module_of(file)
      local source = sources[module]
      if source ~= nil then
        found[file] = Driver.pairing(file, source, module)
      end
    end
  end
  return found
end

--- The complaints in `found`, one to a line in the order of the files they start with, so that the order does not depend
--- on the order of the entries.
local function lines_of(found: {string: string}): string
  local out: mut {string} = {}
  for _, complaint in pairs(found) do
    out[#out + 1] = complaint
  end
  table.sort(out)
  return table.concat(out, "\n")
end

function Driver.naming(file: string, text: string, own: boolean): string
  local named = AnalysisSchema.kinds_named(text)
  if #named > 1 then
    return file .. ": a .d.tl must name exactly one kind, and this one names " .. table.concat(named, " and ") ..
      ": keep the one line that says what it is (`" .. AnalysisSchema.binding_tag() .. "` for a module implemented in C)"
  end
  local kind = AnalysisSchema.kind_of(file, text)
  local how = "If it declares a module implemented in C, add the line `" .. AnalysisSchema.binding_tag() ..
    "` to its leading comment; otherwise write it as a .tl (types and code in a .tl are checked and real at run time)."
  if kind == "decl" and own and AnalysisSchema.is_language_file(file) then
    return file .. ": the language's own declarations must say so: add the line `" .. AnalysisSchema.language_tag() ..
      "` to its leading comment"
  elseif kind == "decl" then
    return file .. ": a .d.tl must name what it is, and this one names nothing. " .. how
  elseif kind == "language" and not own then
    return file .. ": `" .. AnalysisSchema.language_tag() .. "` is accepted only when building cosmic's own tree, and this is " ..
      "not one. " .. how
  elseif kind == "language" and not AnalysisSchema.is_language_file(file) then
    return file .. ": `" .. AnalysisSchema.language_tag() .. "` is only for the language's own declarations, " ..
      AnalysisSchema.prelude_file() .. " and " .. AnalysisSchema.stdlib_file() .. ", which are the build's globals. " .. how
  end
  return ""
end

local function unnamed_of(entries: {{string}}, skip: function(path: string): boolean, own: boolean): mut {string: string}
  local found: mut {string: string} = {}
  for _, entry in ipairs(entries) do
    local file, text = entry[1], entry[2]
    if file ~= nil and text ~= nil and not skip(file) and file:match("%.d%.tl$") ~= nil then
      local complaint = Driver.naming(file, text, own)
      if complaint ~= "" then
        found[file] = complaint
      end
    end
  end
  return found
end

function Driver.declared(entries: {{string}}, skip: function(path: string): boolean, own: boolean): string
  local found = pairs_of(entries, skip)
  for file, complaint in pairs(unnamed_of(entries, skip, own)) do
    if found[file] == nil then
      found[file] = complaint
    end
  end
  return lines_of(found)
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

function Driver.ending(index: Driver.Index, name: string): {string}
  local found: mut {string} = {}
  local tail = "." .. name
  for _, source in ipairs(index.sources) do
    local module = source.module
    if index.by_module[module] == source and #module > #tail and module:sub(-#tail) == tail then
      found[#found + 1] = "`" .. module .. "` (" .. source.filename .. ")"
    end
  end
  table.sort(found)
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
  closed: boolean
  checked: boolean
  bodies: boolean
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
    program.external[name] = true
  end
  return program
end

function Driver.new(options: Driver.Options): Driver.Build
  local build: Driver.Build = {
    program = program_of(options.external, options.library), problems = {}, timing = { prepare = 0, lower = 0, check = 0 },
    provide = function(_self: Driver.Build, _provider: Driver.Provider) end,
    parsed = function(_self: Driver.Build, _name: string): Driver.Outcome? return nil end,
    provides = function(_self: Driver.Build, _name: string): boolean
      return false
    end,
    lower = function(_self: Driver.Build, _names: {string}) end,
    result = function(_self: Driver.Build, _name: string, _bodies: boolean): Driver.Outcome?
      return nil
    end,
    held = function(_self: Driver.Build, _result: Driver.Outcome, _ceilings: Ceilings.Table): {string}
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

  --- What a `require` that names no module may have meant, for the one at `offset` of `result`: "" where no module ends in the
  --- name, else "; did you mean `b.m` (b/m.tl)?" or the candidates, "; did you mean one of `a.m` (a/m.tl), `b.m` (b/m.tl)?".
  local function meant(result: Driver.Outcome, offset: integer): string
    local tokens = result.chunk.tokens
    local at = RemovedFix.token_at(tokens, offset)
    if at == nil or tokens.kind[at + 2] ~= "string" then
      return ""
    end
    local name = tokens.value[at + 2]
    if name == nil then
      return ""
    end
    local ending = options.meant
    if ending == nil then
      return ""
    end
    local found = ending(name)
    if #found == 0 then
      return ""
    elseif #found == 1 then
      return "; did you mean " .. found[1] .. "?"
    end
    return "; did you mean one of " .. table.concat(found, ", ") .. "?"
  end

  --- The entry for a source that has been read: scoped against the globals.
  local function entry_of(read: Read): Entry
    local source = read.source
    local scoped = Scopes.build(read.chunk, source.filename, globals)
    local syntax: mut {Driver.Problem} = {}
    for _, e in ipairs(read.errors) do
      syntax[#syntax + 1] = problem_of("error", "syntax", tostring(e.code), e.msg, e.fix, e.y, e.x, e.offset)
    end
    local result: Driver.Outcome = {
      module = source.module, source = source, text = read.text, never_false = read.never_false, chunk = read.chunk,
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
    build.program.provider = function(self: Declarations.Program, module: string): boolean
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

  -- TODO: keep what is lowered of the modules that do not require the replaced one, once a Declarations.Program can forget a
  -- module (lang/declarations.tl): after the replacement of a module this program has met, every module is lowered again,
  -- the retired ones read from their sources and kept until their callers retire them. The splice of [`Shape.record_of`] does
  -- not meet the module here: it reads it in [`Driver.Build.scratch`], so that the replacement takes the first branch below.
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
    -- Every module is lowered again, those retired among them when they are next asked for.
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

  --- Whether `entry` is one of the declaration files that declare the globals.
  local function declares_globals(entry: Entry): boolean
    for _, declaring in ipairs(global_entries) do
      if declaring == entry then
        return true
      end
    end
    return false
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
            types[id] = t
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

  build.held = function(_self: Driver.Build, result: Driver.Outcome, ceilings: Ceilings.Table): {string}
    local out: mut {string} = {}
    local source = result.source
    local file = source.filename
    if source.pinned ~= "" then
      file = source.pinned
    end
    local function stage(list: {Driver.Problem}, codes: {string}, name: Ceilings.Stage, what: string)
      local findings: mut {Ceilings.Finding} = {}
      for _, p in ipairs(list) do
        findings[#findings + 1] = { code = p.code, y = p.y, x = p.x, msg = p.msg, fix = p.fix }
      end
      local held = Ceilings.over(file, findings, codes, Ceilings.of(ceilings, name), what, ceilings.none)
      for _, line in ipairs(held.lines) do
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
      out[#out + 1] = file .. ": its bodies were not checked, so no ceiling on them was held: ask for the result with the " ..
        "bodies checked"
    end
    return out
  end

  return build
end

return Driver
