--- The driver of the new checker: one program built over the modules of a build, and for each module the answer a
--- build, a check of the tree or `cosmic compile` reads.
---
--- A [`Driver.Build`] holds one [`Declarations.Program`], the store of every type, and asks its *providers* for the
--- module a `require` names: [`Driver.files`] (the sources of a tree, `.tl` and `.d.tl`, each under the names a
--- `require` may use), [`Driver.standard`] (the `cosmic.*` modules, each its source or its stub, from wherever the
--- host keeps them) and [`Driver.stubs`] (modules whose text is given, left unchecked). The *global* sources, the
--- declaration files of the standard library, are lowered first and declare the globals every module may use; the
--- text of the standard library goes through [`lang.stdlib_corrections`] on the way, and what the corrections could not
--- apply is [`Driver.Build.problems`], the drift report. A source in the fork's Teal ([`Driver.Source.translate`]) is
--- translated first ([`lang.translate`]).
---
--- A module is lexed, parsed and scoped when first asked for, lowered ([`lang.declarations`]) after what it requires
--- (a cycle is lowered in the order it is met: the provider declares the other side first) and checked
--- ([`lang.check`]) on request. Each [`Driver.Outcome`] carries the errors of every stage and the warnings
--- ([`lang.warnings`]), each in source order, and the type of every node the checker typed, by the id of the node:
--- the report that [`build.receivers`], [`build.links`], [`build.shape_specs`] and [`build.contracts`] will read in
--- place of the fork's. A module that is not checked (a library, a stub, a binding) is lowered and has no body errors.
---
--- The ceilings ([`build.ceilings`]) are enforced for a module by [`Driver.Build.held`]: a count of errors of a code
--- above its ceiling is refused, with the same words as the check of the tree. A module that did not parse is refused
--- for that alone.
---
--- Not wired into the build yet: [`build.tree_checks`] is the one caller, in place of the lowering it had of its own.
--
-- TODO: have `cosmic compile --grammar new` ([`build.compile_grammar`]) and the build's own compile
-- ([`build.compilation`]) call this driver, once the readers of the new syntax tree and the type report are ported
-- (doc/plans/strict-teal.md, "the switch"); `compile_grammar.compile` does by hand the ordering and the globals the
-- driver does, and keeps the generator's inputs the driver does not carry.
local Ast = require("lang.ast")
local Ceilings = require("build.ceilings")
local Check = require("lang.check")
local Clock = require("cosmic.clock")
local Corrections = require("lang.stdlib_corrections")
local Declarations = require("lang.declarations")
local Lexer = require("lang.lexer")
local Parser = require("lang.parser")
local Scopes = require("lang.scopes")
local Translate = require("lang.translate")
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
    --- Whether the text is the fork's declaration file of the Lua standard library, which
    --- [`lang.stdlib_corrections`] corrects first.
    corrections: boolean
    --- Whether its bodies are checked and its result carried. A library, a stub and a binding are lowered and not checked.
    checked: boolean
    --- Whether its top-level `local function test_*` are called from outside the file (a test module), so that they are
    --- not unused.
    tests: boolean
    --- The other names a `require` may give it.
    aliases: {string}
  end

  --- What answers for the module a `require` names: its source, or nil where it has none.
  type Provider = function(module: string): Source | nil

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
  end

  --- What a module came to.
  record Outcome
    module: string
    source: Source
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
    --- What the corrections could not apply to the declaration file they correct, one line each.
    problems: {string}
    timing: Timing
    --- Asks `provider` for a module after the providers added before it.
    provide: function(Build, provider: Provider)
    --- The module `name` (or one of its aliases) lexed, parsed and scoped, nil where no provider has it.
    parsed: function(Build, name: string): Outcome | nil
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
    --- the translation's hazards, counted in `[hazards]`). A module whose bodies were not checked is told so. A declaration file the driver corrects
    --- is held by the tree's checks of the file as written, and by no ceiling here.
    held: function(Build, result: Outcome, ceilings: Ceilings.Table): {string}
  end

  --- A build over `options`.
  new: function(options: Options): Build

  --- A source with the defaults: checked, not translated, not corrected, not a test module, no alias.
  source: function(module: string, filename: string, text: string, dialect: Ast.Dialect): Source

  --- A declaration file whose globals every module may use ([`Driver.Options.globals`]): not checked, translated when
  --- `translate` and corrected ([`lang.stdlib_corrections`]) when `corrections`, answering to `aliases` as well.
  declarations: function(module: string, filename: string, text: string, translate: boolean, corrections: boolean,
                   aliases: {string}): Source

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
  --- ([`Driver.Source.tests`]).
  index: function(entries: {{string}}, translate: boolean, skip: function(path: string): boolean): Index

  --- The provider of `index`.
  files: function(index: Index): Provider

  --- The provider of the `cosmic.*` modules `read` finds, each its stub or its source: `read` answers the text of a
  --- module, or nil. They are lowered for the types they give and never checked.
  standard: function(read: Reader): Provider

  --- The provider of the modules whose text is `texts`, by name, unchecked.
  stubs: function(texts: {string: string}): Provider

  --- The globals the `sources` declare, `adjust`ed: what a scope builder is given for a module.
  globals: function(sources: {Source}, adjust: function(globals: {string: Scopes.Global}) | nil): {string: Scopes.Global}

end

local function make(module: string, filename: string, text: string, dialect: Ast.Dialect, translate: boolean,
                    corrections: boolean, checked: boolean, aliases: {string}): Driver.Source
  return {
    module = module, filename = filename, text = text, dialect = dialect, translate = translate,
    corrections = corrections, checked = checked, tests = false, aliases = aliases,
  }
end

function Driver.source(module: string, filename: string, text: string, dialect: Ast.Dialect): Driver.Source
  return make(module, filename, text, dialect, false, false, true, {})
end

function Driver.declarations(module: string, filename: string, text: string, translate: boolean, corrections: boolean,
                             aliases: {string}): Driver.Source
  return make(module, filename, text, "decl", translate, corrections, false, aliases)
end

--- The text of a source as the checker reads it: corrected and translated where it says so, and what the corrections could
--- not apply, one line each.
local record Text
  text: string
  problems: {string}
end

local function text_of(source: Driver.Source): Text
  local text = source.text
  local problems: {string} = {}
  if source.corrections then
    -- The declarations of the standard library the new checker reads differently from the fork.
    local corrected = Corrections.apply(text)
    text = corrected.text
    for _, t in ipairs(corrected.problems) do
      problems[#problems + 1] = source.filename .. ": " .. t .. " (lang/stdlib_corrections.tl)"
    end
  end
  if source.translate then
    text = Translate.translate(text, source.filename).text
  end
  return { text = text, problems = problems }
end

--- A source, read: its text corrected and translated, parsed.
local record Read
  source: Driver.Source
  chunk: Ast.Chunk
  errors: {Parser.Error}
end

local function read_source(source: Driver.Source, problems: {string}): Read
  local made = text_of(source)
  for _, line in ipairs(made.problems) do
    problems[#problems + 1] = line
  end
  local parsed = Parser.parse(Lexer.lex(made.text, source.filename), source.filename, source.dialect)
  return { source = source, chunk = parsed.chunk, errors = parsed.errors }
end

function Driver.globals(sources: {Driver.Source}, adjust: function(globals: {string: Scopes.Global}) | nil):
    {string: Scopes.Global}
  local out: {string: Scopes.Global} = {}
  local problems: {string} = {}
  for _, source in ipairs(sources) do
    for name, g in pairs(Scopes.declared(read_source(source, problems).chunk)) do
      out[name] = g
    end
  end
  if adjust ~= nil then
    adjust(out)
  end
  return out
end

function Driver.index(entries: {{string}}, translate: boolean, skip: function(path: string): boolean): Driver.Index
  local index: Driver.Index = { sources = {}, by_module = {} }
  for _, entry in ipairs(entries) do
    local file = entry[1]
    local text = entry[2]
    if file ~= nil and text ~= nil and not skip(file) then
      local dialect: Ast.Dialect = "tl"
      if file:match("%.d%.tl$") then
        dialect = "decl"
      end
      local source = make(Declarations.module_of(file), file, text, dialect, translate, false, true, {})
      source.tests = file:match("_test%.tl$") ~= nil
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

function Driver.standard(read: Driver.Reader): Driver.Provider
  return function(module: string): Driver.Source | nil
    local text = read(module)
    if text == nil then
      return nil
    end
    return make(module, module:gsub("%.", "/") .. ".tl", text, "tl", false, false, false, {})
  end
end

function Driver.stubs(texts: {string: string}): Driver.Provider
  return function(module: string): Driver.Source | nil
    local text = texts[module]
    if text == nil then
      return nil
    end
    return make(module, module:gsub("%.", "/") .. ".tl", text, "tl", false, false, false, {})
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
  return { kind = kind, stage = stage, code = code, msg = msg, fix = fix, y = y, x = x, offset = offset }
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
local function test_functions(scoped: Scopes.Scoped, tokens: {Lexer.Token}): {integer: boolean}
  local out: {integer: boolean} = {}
  for _, v in ipairs(scoped.list) do
    if v.kind == "function" and v.top and v.name:sub(1, 5) == "test_" then
      local token = tokens[v.declared]
      if token ~= nil then
        out[token.offset] = true
      end
    end
  end
  return out
end

function Driver.new(options: Driver.Options): Driver.Build
  local program = Declarations.new()
  for _, name in ipairs(options.external) do
    program.external[name] = true
  end
  local build: Driver.Build = {
    program = program, problems = {}, timing = { prepare = 0, lower = 0, check = 0 },
    provide = function(_self: Driver.Build, _provider: Driver.Provider) end,
    parsed = function(_self: Driver.Build, _name: string): Driver.Outcome | nil return nil end,
    lower = function(_self: Driver.Build, _names: {string}) end,
    result = function(_self: Driver.Build, _name: string, _bodies: boolean): Driver.Outcome | nil
      return nil
    end,
    held = function(_self: Driver.Build, _result: Driver.Outcome, _ceilings: Ceilings.Table): {string}
      return {}
    end,
  }
  local timing = build.timing
  local providers: {Driver.Provider} = {}
  local entries: {string: Entry} = {}
  local globals: {string: Scopes.Global} = {}
  local global_entries: {Entry} = {}
  local started_up: Flag = { done = false }

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
      module = source.module, source = source, chunk = read.chunk, scoped = scoped, broken = #syntax > 0,
      lowered = nil, checked = nil, syntax = syntax, scope_errors = {}, declared = {}, bodies = {}, errors = {},
      warnings = {}, types = {},
    }
    return {
      result = result, lowered = false, closed = false, checked = false, bodies = false,
      input = {
        module = source.module, filename = source.filename, chunk = read.chunk, dialect = source.dialect, scoped = scoped,
      },
    }
  end

  local function alias_all(entry: Entry)
    for _, name in ipairs(entry.result.source.aliases) do
      program:alias(name, entry.result.module)
    end
  end

  local function lower_entry(entry: Entry)
    if entry.lowered then
      return
    end
    entry.lowered = true
    local started = Clock.monotonic_ns()
    entry.result.lowered = program:lower(entry.input)
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
      local read = read_source(source, build.problems)
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
    local source = find(name)
    if source == nil then
      return nil
    end
    held = entries[source.module]
    if held == nil then
      local started = Clock.monotonic_ns()
      held = entry_of(read_source(source, build.problems))
      timing.prepare = timing.prepare + Clock.monotonic_ns() - started
      entries[source.module] = held
    end
    entries[name] = held
    return held
  end

  program.provider = function(self: Declarations.Program, module: string): boolean
    local entry = prepare(module)
    if entry == nil then
      return false
    end
    self:declare(entry.input)
    alias_all(entry)
    return true
  end

  build.provide = function(_self: Driver.Build, provider: Driver.Provider)
    providers[#providers + 1] = provider
  end

  build.parsed = function(_self: Driver.Build, name: string): Driver.Outcome | nil
    local entry = prepare(name)
    if entry == nil then
      return nil
    end
    return entry.result
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
        local checked = Check.check(program, entry.input, lowered, options.types)
        timing.check = timing.check + Clock.monotonic_ns() - started
        result.checked = checked
        for _, e in ipairs(checked.errors) do
          result.bodies[#result.bodies + 1] = problem_of("error", "checked", tostring(e.code), e.msg, e.fix, e.y, e.x, e.offset)
        end
        local exempt: {integer: boolean} = {}
        if source.tests then
          exempt = test_functions(result.scoped, result.chunk.tokens)
        end
        for _, w in ipairs(checked.warnings) do
          if not (w.code == "unused_function" and exempt[w.offset] == true) then
            result.warnings[#result.warnings + 1] = {
              kind = w.kind, stage = "warning", code = w.code, msg = w.msg, fix = w.fix, y = w.y, x = w.x,
              offset = w.offset,
            }
          end
        end
        if options.types then
          local types = checked.types
          for id, t in pairs(lowered.types) do
            types[id] = t
          end
          result.types = types
        end
      end
    end
    if not entry.checked then
      entry.checked = true
      for _, e in ipairs(result.scoped.errors) do
        result.scope_errors[#result.scope_errors + 1] = problem_of("error", "scoped", tostring(e.code), e.msg, e.fix, e.y, e.x, e.offset)
      end
      if lowered ~= nil then
        for _, e in ipairs(program:errors(result.module)) do
          result.declared[#result.declared + 1] = problem_of("error", "declared", tostring(e.code), e.msg, e.fix, e.y, e.x, e.offset)
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
    local function stage(list: {Driver.Problem}, codes: {string}, name: Ceilings.Stage, what: string)
      local findings: {Ceilings.Finding} = {}
      for _, p in ipairs(list) do
        findings[#findings + 1] = { code = p.code, y = p.y, x = p.x, msg = p.msg, fix = p.fix }
      end
      local held = Ceilings.over(file, findings, codes, Ceilings.of(ceilings, name), what)
      for _, line in ipairs(held.lines) do
        out[#out + 1] = line
      end
    end
    if source.corrections then
      -- The text is the driver's own correction of a file ([`lang.stdlib_corrections`] writes some of it in the new
      -- grammar), not what the tree's checks count; the file is held there, as it is written.
      return out
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
    -- A translated module's scope errors are those of the translation (a method moved above a name it reads, which
    -- `[hazards]` counts); the tree's `[scoped]` counts the scope errors of the source the fork reads.
    if not source.translate then
      stage(result.scope_errors, Scopes.codes, "scoped", "scopes")
    end
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
