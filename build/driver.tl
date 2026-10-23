--- The driver of the new checker: one program built over the modules of a build, and for each module the answer a
--- build, a check of the tree or `cosmic compile` reads.
---
--- A [`Driver.Build`] holds one [`Declarations.Program`], the store of every type, and asks its *providers* for the
--- module a `require` names: [`Driver.files`] (the sources of a tree, `.tl` and `.d.tl`, each under the names a
--- `require` may use), [`Driver.standard`] (the `cosmic.*` modules, each its source or its stub, from wherever the
--- host keeps them) and [`Driver.stubs`] (modules whose text is given, left unchecked). The *global* sources, the
--- declaration files of the standard library, are lowered first and declare the globals every module may use; the
--- text of the standard library is [`lang/stdlib.d.tl`], in the new grammar like the rest of the globals. A source in the
--- fork's Teal ([`Driver.Source.translate`]) is
--- translated first ([`lang.translate`]).
---
--- A module is lexed, parsed and scoped when first asked for, lowered ([`lang.declarations`]) after what it requires
--- (a cycle is lowered in the order it is met: the provider declares the other side first) and checked
--- ([`lang.check`]) on request. Each [`Driver.Outcome`] carries the errors of every stage and the warnings
--- ([`lang.warnings`]), each in source order, and the type of every node the checker typed, by the id of the node:
--- the report that [`build.receivers`], [`build.links`], [`build.shape_specs`] and [`build.contracts`] will read in
--- place of the fork's. A module that is not checked (a library, a stub, a binding) is lowered and has no body errors.
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
--- Its callers are [`build.tree_checks`], `cosmic compile --grammar new` ([`build.compile_grammar`]) and the pipeline of the
--- new checker ([`build.pipeline`]), which the build's own compile calls in the mode `COSMIC_GRAMMAR=new` chooses
--- ([`build.importer`]).
local Ast = require("lang.ast")
local Ceilings = require("build.ceilings")
local Check = require("lang.check")
local Clock = require("cosmic.clock")
local Declarations = require("lang.declarations")
local Lexer = require("lang.lexer")
local Parser = require("lang.parser")
local RemovedFix = require("build.removed_fix")
local Scopes = require("lang.scopes")
local Translate = require("lang.translate")
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
    --- Whether the text is the fork's Teal, which [`lang.translate`] writes in the new grammar first.
    translate: boolean
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
    --- Made of the text after it is corrected and translated, before it is parsed, where given: the steps a source needs
    --- to be read in the new grammar that no translation makes ([`build.pipeline`]). It keeps the lines.
    mend: Mend | nil
  end

  --- What answers for the module a `require` names: its source, or nil where it has none.
  type Provider = function(module: string): Source | nil

  --- Whether an expression can be neither false nor nil ([`Driver.Outcome.never_false`]).
  type Truthy = function(e: Ast.Exp): boolean

  --- What is done to the text of a source after it is translated: the text the checker reads.
  type Mend = function(text: string): string

  --- What a caller knows of a file of an index that its name does not say: whether it is a test module, and the steps its
  --- text needs after it is translated ([`Driver.Source.mend`]).
  record Extra
    tests: boolean
    mend: Mend | nil
  end

  --- What a caller knows of the file `file`, whose text is `text`.
  type Extras = function(file: string, text: string): Extra

  --- What reads the text of a `cosmic.*` module for [`Driver.standard`]: its source or its stub, nil where there is none.
  type Reader = function(module: string): string | nil

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
  end

  --- What a module came to.
  record Outcome
    module: string
    source: Source
    --- The text the checker reads, in the new grammar: the source's text translated where it says so, or
    --- the text a [`Driver.Build.replace`] gave.
    text: string
    --- Whether an expression can be neither false nor nil, from its syntax alone ([`lang.truthy`]),
    --- for the code generator's `if` expressions: set for every source, the translated and the written in the new
    --- grammar alike. The translator writes an `if` expression only for a value that cannot be false, and a file written
    --- in the new grammar holds the same form; the generator is told what the rule knows, or it writes a function called
    --- on the spot where the fork writes `and`/`or`, and a file's Lua would depend on how the file came.
    never_false: Truthy | nil
    chunk: Ast.Chunk
    scoped: Scopes.Scoped
    --- Whether the text did not parse: it is lowered as far as its tree goes, for the modules that require it, and a
    --- check counts nothing of it.
    broken: boolean
    --- What lowering made: nil until the module is lowered.
    lowered: Declarations.Lowered | nil
    --- What checking made: nil until the module is checked, and for a module that is not.
    checked: Check.Checked | nil
    --- The errors of each stage, in source order.
    syntax: {Problem}
    scope_errors: {Problem}
    declared: {Problem}
    bodies: {Problem}
    --- Every error, in source order, and the warnings.
    errors: {Problem}
    warnings: {Problem}
    --- The type of each node the checker typed (an expression) or lowered (a type), by the id of the node.
    types: {integer: Types.Type}
    --- The function each call and method call took, by the id of the call node ([`Check.Checked.callees`]).
    callees: {integer: Types.Type}
  end

  --- The nanoseconds a build spent in each phase, for the speed of a run.
  record Timing
    --- Translating, correcting, lexing, parsing and scoping.
    prepare: integer
    lower: integer
    check: integer
  end

  record Options
    --- The declaration files of the standard library, in the order they are lowered: each declares globals.
    globals: {Source}
    --- Called with the globals the sources declared, to take away the ones the host withholds and add the ones it
    --- provides.
    adjust: function(globals: {string: Scopes.Global}) | nil
    --- The modules that are bindings of C, whose types the checker does not read: a type name of one is `invalid`.
    external: {string}
    --- Whether the checker keeps the type of each node: the `types` of a result. A run that reads none leaves it, and saves the
    --- time of recording them.
    types: boolean
  end

  --- A build.
  record Build
    program: Declarations.Program
    --- The calls of [`Shape.record_of`] a module of the tree makes that [`build.tree_program`] could not resolve before it lowered the module, one line each.
    problems: {string}
    timing: Timing
    --- Asks `provider` for a module after the providers added before it.
    provide: function(Build, provider: Provider)
    --- The module `name` (or one of its aliases) lexed, parsed and scoped, nil where no provider has it.
    parsed: function(Build, name: string): Outcome | nil
    --- Whether the build has the module `name`: a global source, a module a provider has, or one it has retired. Nothing is read
    --- to tell.
    provides: function(Build, name: string): boolean
    --- Lowers the modules `names`, each after what it requires, and the globals before them.
    lower: function(Build, names: {string})
    --- The result for `name`, lowered with what it requires. With `bodies` its bodies are checked too. nil where no
    --- provider has it. Call it for the modules you want, after [`Driver.Build.lower`] of all of them, since the
    --- errors of a module's declarations include checks that waited for a module lowered later.
    result: function(Build, name: string, bodies: boolean): Outcome | nil
    --- The lines that refuse `result` against `ceilings`: its syntax errors, and for each stage the errors of a code above
    --- its ceiling, each with its place and fix and then the count and `pinned N`. None where the module is held. The stages
    --- are those of the tree's checks, over the same text: a module read in the new grammar is held to `[scoped]`,
    --- `[declared]` and `[checked]`, and to no syntax error; a module of the fork's Teal, which the driver translates, to
    --- `[declared]` and `[checked]` and, where its translation does not parse, to `[translated]` (its scope errors are
    --- the translation's hazards, counted in `[hazards]`). A module whose bodies were not checked is told so.
    held: function(Build, result: Outcome, ceilings: Ceilings.Table): {string}
    --- Replaces the text of the module `name` with `text`, in the grammar the checker reads (it is neither corrected,
    --- translated nor mended again, though the module stays what it was: held to the ceilings of a translation, say),
    --- and answers its outcome, or nil where no provider has `name`. A module cannot be lowered twice in one program, so
    --- the build begins a new one: every module is lowered again, when it is next asked for, from the syntax tree it has
    --- already, and an outcome answered before is no longer the build's. The splices of [`build.syntax_shape_specs`] are
    --- made in the text of [`Driver.Outcome.text`] and checked this way.
    replace: function(Build, name: string, text: string): Outcome | nil
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

  --- A source with the defaults: checked, not translated, not corrected, no alias, and a test module only where `tests`.
  source: function(module: string, filename: string, text: string, dialect: Ast.Dialect, tests?: boolean): Source

  --- A declaration file whose globals every module may use ([`Driver.Options.globals`]): not checked, translated when
  --- `translate`, answering to `aliases` as well.
  declarations: function(module: string, filename: string, text: string, translate: boolean, aliases: {string}): Source

  --- The sources of a tree and the names they answer to.
  record Index
    sources: {Source}
    by_module: {string: Source}
  end

  --- The modules `entries` (pairs of a path below the root and its text) are: each `.tl` and `.d.tl` a module named by its
  --- path ([`Declarations.module_of`]), checked, in the fork's Teal (`translate`) when `translate`. A module is also
  --- answered to by the name of its path below each directory, since a project inside the tree (`ci/`, a fixture
  --- directory) names its modules from its own root. `skip` says which paths are left out. Where a module is given as
  --- `.tl` and `.d.tl` the declaration is the one answered, under every name. A `*_test.tl` is a test module
  --- ([`Driver.Source.tests`]). An entry may give a third word, the module it is, and a fourth, the name its ceilings
  --- are kept under ([`Driver.Source.pinned`]), for a source the build writes from another file, whose path says
  --- neither: the entry's path is then the name of the text, and `.d.tl` still marks a declaration. `extras` says of a file
  --- what its name does not: a test module ([`Driver.Source.tests`]) and the steps its text needs ([`Driver.Source.mend`]).
  index: function(entries: {{string}}, translate: boolean, skip: function(path: string): boolean, extras?: Extras): Index

  --- The provider of `index`.
  files: function(index: Index): Provider

  --- The provider of the `cosmic.*` modules `read` finds, each its stub or its source: `read` answers the text of a
  --- module, or nil. They are lowered for the types they give and never checked. The binary keeps them in the fork's
  --- Teal, which `translate` says is translated first ([`lang.translate`]). A module `declared` says is one is read as a
  --- declaration file, which has no code.
  standard: function(read: Reader, translate?: boolean, declared?: function(module: string): boolean): Provider

  --- The provider of the modules whose text is `texts`, by name, unchecked.
  stubs: function(texts: {string: string}): Provider

  --- The globals the `sources` declare, `adjust`ed: what a scope builder is given for a module.
  globals: function(sources: {Source}, adjust: function(globals: {string: Scopes.Global}) | nil): {string: Scopes.Global}

  --- A source as a build reads it, and no more: its text corrected, translated and mended where it says so, lexed and parsed.
  --- The readers of the syntax tree ([`build.syntax_derivation`]) take their tree from this, with the text it was parsed from.
  record Parsed
    text: string
    chunk: Ast.Chunk
    --- The syntax errors, in source order: none for a tree that is whole.
    syntax: {Problem}
  end
  parse: function(source: Source): Parsed
end

local function make(module: string, filename: string, text: string, dialect: Ast.Dialect, translate: boolean,
                    checked: boolean, aliases: {string}, tests: boolean, pinned: string, mend: Driver.Mend | nil): Driver.Source
  return {
    module = module, filename = filename, text = text, dialect = dialect, translate = translate,
    checked = checked, tests = tests, aliases = aliases, pinned = pinned, mend = mend,
  }
end

function Driver.source(module: string, filename: string, text: string, dialect: Ast.Dialect, tests?: boolean): Driver.Source
  return make(module, filename, text, dialect, false, true, {}, tests == true, "", nil)
end

function Driver.declarations(module: string, filename: string, text: string, translate: boolean, aliases: {string}): Driver.Source
  return make(module, filename, text, "decl", translate, false, aliases, false, "", nil)
end

--- The text of a source as the checker reads it: translated and mended where it says so.
local function text_of(source: Driver.Source): string
  local text = source.text
  if source.translate then
    text = Translate.translate(text, source.filename).text
  end
  local mend = source.mend
  if mend ~= nil then
    text = mend(text)
  end
  return text
end

--- A source, read: its text translated, parsed.
local record Read
  source: Driver.Source
  text: string
  never_false: Driver.Truthy | nil
  chunk: Ast.Chunk
  errors: {Parser.Error}
end

local function read_source(source: Driver.Source, written?: boolean): Read
  local text = source.text
  if written ~= true then
    text = text_of(source)
  end
  local parsed = Parser.parse(Lexer.lex(text, source.filename), source.filename, source.dialect)
  return { source = source, text = text, never_false = Truthiness.never_false, chunk = parsed.chunk, errors = parsed.errors }
end

function Driver.parse(source: Driver.Source): Driver.Parsed
  local read = read_source(source)
  local syntax: {Driver.Problem} = {}
  for _, e in ipairs(read.errors) do
    syntax[#syntax + 1] = {
      kind = "error", stage = "syntax", code = tostring(e.code), msg = e.msg, fix = e.fix, y = e.y, x = e.x, offset = e.offset,
      removed = false,
    }
  end
  return { text = read.text, chunk = read.chunk, syntax = syntax }
end

function Driver.globals(sources: {Driver.Source}, adjust: function(globals: {string: Scopes.Global}) | nil):
    {string: Scopes.Global}
  local out: {string: Scopes.Global} = {}
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

function Driver.index(entries: {{string}}, translate: boolean, skip: function(path: string): boolean,
                      extras?: Driver.Extras): Driver.Index
  local index: Driver.Index = { sources = {}, by_module = {} }
  for _, entry in ipairs(entries) do
    local file = entry[1]
    local text = entry[2]
    if file ~= nil and text ~= nil and not skip(file) then
      local dialect: Ast.Dialect = "tl"
      if file:match("%.d%.tl$") then
        dialect = "decl"
      end
      local extra: Driver.Extra = { tests = false, mend = nil }
      if extras ~= nil then
        extra = extras(file, text)
      end
      local source = make(entry[3] or Declarations.module_of(file), file, text, dialect, translate, true, {},
        extra.tests or file:match("_test%.tl$") ~= nil, entry[4] or "", extra.mend)
      index.sources[#index.sources + 1] = source
      local held = index.by_module[source.module]
      -- A declaration is read ahead of a source of the same name, as the fork reads it.
      if held == nil or dialect == "decl" then
        index.by_module[source.module] = source
      end
    end
  end
  for _, source in ipairs(index.sources) do
    -- Only the source a module is read from answers to the tail of its name, so that the module is one whichever name asks.
    if index.by_module[source.module] == source then
      local name = source.module
      local dot = name:find(".", 1, true)
      while dot ~= nil do
        name = name:sub(dot + 1)
        if index.by_module[name] == nil then
          index.by_module[name] = source
          source.aliases[#source.aliases + 1] = name
        end
        dot = name:find(".", 1, true)
      end
    end
  end
  return index
end

function Driver.files(index: Driver.Index): Driver.Provider
  return function(module: string): Driver.Source | nil
    return index.by_module[module]
  end
end

function Driver.standard(read: Driver.Reader, translate?: boolean, declared?: function(module: string): boolean):
    Driver.Provider
  return function(module: string): Driver.Source | nil
    local text = read(module)
    if text == nil then
      return nil
    end
    local file = module:gsub("%.", "/")
    if declared ~= nil and declared(module) then
      return Driver.declarations(module, file .. ".d.tl", text, translate == true, {})
    end
    return make(module, file .. ".tl", text, "tl", translate == true, false, {}, false, "", nil)
  end
end

function Driver.stubs(texts: {string: string}): Driver.Provider
  return function(module: string): Driver.Source | nil
    local text = texts[module]
    if text == nil then
      return nil
    end
    return make(module, module:gsub("%.", "/") .. ".tl", text, "tl", false, false, {}, false, "", nil)
  end
end

--- Whether a build has started.
local record Flag
  done: boolean
end

--- A module the build has read: its input, and whether it is lowered and checked.
local record Entry
  result: Driver.Outcome
  input: Declarations.Input
  lowered: boolean
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
                        offset: integer, length: integer, types: {string}): Driver.Problem
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
    removed = instead ~= nil,
  }
end

--- `list` in source order: by offset, and where two are at one offset in the order they were found.
local function in_order(list: {Driver.Problem}): {Driver.Problem}
  local place: {Driver.Problem: integer} = {}
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
  local out: {integer: boolean} = {}
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
local function program_of(external: {string}): Declarations.Program
  local program = Declarations.new()
  for _, name in ipairs(external) do
    program.external[name] = true
  end
  return program
end

function Driver.new(options: Driver.Options): Driver.Build
  local build: Driver.Build = {
    program = program_of(options.external), problems = {}, timing = { prepare = 0, lower = 0, check = 0 },
    provide = function(_self: Driver.Build, _provider: Driver.Provider) end,
    parsed = function(_self: Driver.Build, _name: string): Driver.Outcome | nil return nil end,
    provides = function(_self: Driver.Build, _name: string): boolean
      return false
    end,
    lower = function(_self: Driver.Build, _names: {string}) end,
    result = function(_self: Driver.Build, _name: string, _bodies: boolean): Driver.Outcome | nil
      return nil
    end,
    held = function(_self: Driver.Build, _result: Driver.Outcome, _ceilings: Ceilings.Table): {string}
      return {}
    end,
    replace = function(_self: Driver.Build, _name: string, _text: string): Driver.Outcome | nil
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
  local providers: {Driver.Provider} = {}
  local entries: {string: Entry} = {}
  local globals: {string: Scopes.Global} = {}
  local global_entries: {Entry} = {}
  local started_up: Flag = { done = false }
  --- The names of the modules [`Driver.Build.retire`] forgot after the program lowered them, which nothing reads again.
  local retired: {string: boolean} = {}
  local scratches: {Driver.Build} = {}

  local function find(module: string): Driver.Source | nil
    for _, provider in ipairs(providers) do
      local source = provider(module)
      if source ~= nil then
        return source
      end
    end
    return nil
  end

  --- The entry for a source that has been read: scoped against the globals.
  local function entry_of(read: Read): Entry
    local source = read.source
    local scoped = Scopes.build(read.chunk, source.filename, globals)
    local syntax: {Driver.Problem} = {}
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
    local reads: {Read} = {}
    for _, source in ipairs(options.globals) do
      local read = read_source(source)
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

  local function prepare(name: string): Entry | nil
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

  build.parsed = function(_self: Driver.Build, name: string): Driver.Outcome | nil
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
  build.replace = function(_self: Driver.Build, name: string, text: string): Driver.Outcome | nil
    local held = prepare(name)
    if held == nil then
      return nil
    end
    local old = held.result.source
    local source = make(old.module, old.filename, text, old.dialect, old.translate, old.checked, old.aliases, old.tests,
      old.pinned, nil)
    local started = Clock.monotonic_ns()
    local fresh = entry_of(read_source(source, true))
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
    local made: {Entry: Entry} = {}
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
    local names: {string: Entry} = {}
    for key, entry in pairs(entries) do
      names[key] = again(entry)
    end
    for key, entry in pairs(names) do
      entries[key] = entry
    end
    for index, entry in ipairs(global_entries) do
      global_entries[index] = again(entry)
    end
    build.program = program_of(options.external)
    attach()
    for _, entry in ipairs(global_entries) do
      lower_entry(entry)
    end
    return fresh.result
  end

  build.lower = function(_self: Driver.Build, names: {string})
    start()
    local state: {Entry: boolean} = {}
    local order: {Entry} = {}
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

  build.result = function(self: Driver.Build, name: string, bodies: boolean): Driver.Outcome | nil
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
          result.bodies[#result.bodies + 1] = error_of(result, "checked", tostring(e.code), e.msg, e.fix, e.y, e.x, e.offset,
            e.length, e.types)
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
        result.scope_errors[#result.scope_errors + 1] = error_of(result, "scoped", tostring(e.code), e.msg, e.fix, e.y, e.x,
          e.offset, e.length, {})
      end
      if lowered ~= nil then
        for _, e in ipairs(build.program:errors(result.module)) do
          result.declared[#result.declared + 1] = error_of(result, "declared", tostring(e.code), e.msg, e.fix, e.y, e.x,
            e.offset, e.length, e.types)
        end
      end
    end
    local all: {Driver.Problem} = {}
    for _, list in ipairs({ result.syntax, result.scope_errors, result.declared, result.bodies }) do
      for _, p in ipairs(list) do
        all[#all + 1] = p
      end
    end
    result.errors = in_order(all)
    return result
  end

  build.held = function(_self: Driver.Build, result: Driver.Outcome, ceilings: Ceilings.Table): {string}
    local out: {string} = {}
    local source = result.source
    local file = source.filename
    if source.pinned ~= "" then
      file = source.pinned
    end
    local function stage(list: {Driver.Problem}, codes: {string}, name: Ceilings.Stage, what: string)
      local findings: {Ceilings.Finding} = {}
      for _, p in ipairs(list) do
        findings[#findings + 1] = { code = p.code, y = p.y, x = p.x, msg = p.msg, fix = p.fix }
      end
      local held = Ceilings.over(file, findings, codes, Ceilings.of(ceilings, name), what, ceilings.none)
      for _, line in ipairs(held.lines) do
        out[#out + 1] = line
      end
    end
    if result.broken then
      if source.translate then
        -- The text is the fork's Teal, and the errors of its translation are what `[translated]` counts.
        local codes: {string} = {}
        for _, p in ipairs(result.syntax) do
          codes[#codes + 1] = p.code
        end
        stage(result.syntax, codes, "translated", "translation")
      else
        for _, p in ipairs(result.syntax) do
          out[#out + 1] = file .. ":" .. tostring(p.y) .. ":" .. tostring(p.x) .. ": " .. p.msg .. " (" .. p.code .. "): " ..
            p.fix
        end
      end
      return out
    end
    -- A translated module's scope errors are those of its source, which `[scoped]` counts as the fork reads it (a name that is
    -- none, a type that is none), and those of the translation (a method moved above a name it reads, which `[hazards]`
    -- counts): the fork would have refused the first, and the Lua of the second reads a global.
    -- A hazard of the translation that is no scope error (a shadow, a changed signature) is seen by the tree check `[hazards]`
    -- alone, so a project or a lone file outside the tree, which the new mode builds from the declarations the tool carries
    -- ([`build.checker_declarations`]), would meet it silently.
    --
    -- TODO: count the shadow and signature hazards of a translation here, if a project is to be built in the fork's Teal by
    -- the new mode for longer than the rehearsal: the switch deletes the translator and with it the hazards
    -- (doc/plans/strict-teal.md, "the switch"), so it is left until then.
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
