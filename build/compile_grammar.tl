--- The new checker's grammar for `cosmic compile` (`--grammar new`, [`build/compile.tl`]): files written
--- in it, lexed ([`lang.lexer`]), parsed ([`lang.parser`]), scoped ([`lang.scopes`]), lowered
--- ([`lang.declarations`]), checked ([`lang.check`]) and written as Lua ([`lang.codegen`]), the way
--- [`build/tree_checks.tl`] and [`lang.check_programs`] drive them, but for the files a command line
--- names and nothing else. The program is a [`build.driver`] build over those files, and the generator's inputs
--- are put together by [`emit`], which the build's own pipeline ([`build.pipeline`]) calls too.
---
--- THE PROGRAM IS THE FILES GIVEN. A `.tl` file is checked as the module its path below the root
--- names ([`lang.declarations`]'s [`module_of`]: [`lang/ast.tl`] is [`lang.ast`], `a/init.tl` is `a`), and
--- a `require` of another file given is answered from it. A `.d.tl` file given is a declaration file:
--- its `global` declarations are the globals of every file, which is how the standard library reaches
--- the checker, and it has no Lua. A `cosmic.*` module no file given is the module of is a binding the
--- new checker cannot declare: it is typed `invalid` and reported (`unchecked_binding`), as the tree
--- check does. Any other `require` of a module not given is `require_unknown`.
---
--- A SYNTAX ERROR (the lexer's or the parser's, among them each form the grammar cuts) stops the run
--- before anything is scoped, lowered or written, in every file. Any other error, the scope builder's, the
--- declarations' and the checker's, is reported and the Lua is written all the same, line for line:
--- the generator reads the syntax tree and the names the scope builder resolved, and what the checker concluded of a
--- few things (below).
---
--- THE GENERATOR SEES NO OTHER MODULE, so what a test `v is T` needs of a name of another file comes from the
--- checker: a name the checker resolved to a primitive or a function type is written as a test for that, and
--- a test the Lua cannot tell (a record or an interface, which the checker reports as `is_on_record`, or a class
--- of another module) is a refusal, with no Lua: such a test written as a table test would be a
--- different program from the one the source says. A test of a collection or a function type, whose Lua is the
--- right one, is only reported.
---
--- WITH `facts` each read of a place whose type a test narrowed is written as a call of `__fact` that checks what the
--- checker concluded of it ([`lang.fact_wraps`]), for a run that defines the hook (`cosmic test --check-types`'s worker,
--- [`build.test_worker`]'s `install_checks`), and each function with typed parameters begins with a check of them
--- ([`lang.boundary_checks`]). The Lua has the same lines.
---
--- The generator keeps state of its own, so this is not re-entrant, like [`lang.codegen`].

local Ast = require("lang.ast")
local Check = require("lang.check")
local Codegen = require("lang.codegen")
local Declarations = require("lang.declarations")
local Driver = require("build.driver")
local BoundaryChecks = require("lang.boundary_checks")
local FactWraps = require("lang.fact_wraps")
local Lexer = require("lang.lexer")
local Parser = require("lang.parser")
local Scopes = require("lang.scopes")
local Types = require("lang.types")

local record compile_grammar
  --- A file to compile.
  record Source
    --- The path as the command line gave it, for the complaints about it.
    path: string
    --- The path below the root, which names the module and the file in an error.
    relative: string
    text: string
    --- Whether it is a `.d.tl` file.
    declaration: boolean
  end

  --- An error of any stage, as `cosmic compile` reports it.
  record Problem
    code: string
    msg: string
    fix: string
    y: integer
    x: integer
    offset: integer
  end

  --- What a compile checks against when it is given no declaration file: the globals of the standard library and the provider
  --- of the `cosmic.*` modules, as [`build.pipeline`] makes them for a standalone run.
  record Standalone
    globals: {Driver.Source}
    adjust: function(globals: {string: Scopes.Global})
    standard: Driver.Provider
  end

  --- What one file came to.
  record Compiled
    path: string
    --- Whether it is a `.d.tl` file, which has no Lua.
    declaration: boolean
    --- The Lua; nil for a declaration file, for a file with a syntax error, and where the generator refused
    --- a construct (`trouble` says which).
    code: string?
    --- The lexer's and the parser's errors.
    syntax_errors: {Problem}
    --- Every other error, in source order.
    type_errors: {Problem}
    --- Why the generator wrote no Lua for a tree that parsed.
    trouble: string
  end

  --- What [`emit`] wrote for a module.
  record Emitted
    --- The Lua; nil for a module with no bodies checked (a declaration file) and where the generator refused a
    --- construct (`trouble` says which).
    code: string?
    --- Why the generator wrote no Lua for a module that was checked: its refusals, one to a line, the first
    --- 20 and how many more there are. "" where it wrote some.
    trouble: string
  end

  --- The module the file `relative` (its path below the root) is.
  module_of: function(relative: string): string

  --- The Lua for `result`, a module of `build` that was lowered and checked with its bodies ([`Driver.Build.result`]):
  --- what [`lang.codegen`] writes of its syntax tree given what the checker concluded (the classes its table literals
  --- make, the values of the enums it tests, the kinds its type names resolved to, and with `facts` the wraps of the
  --- reads a test narrowed), and the tests it cannot write. The generator is told what the syntax of the text shows
  --- ([`Driver.Outcome.never_false`]). With `counted` the test of a record, an interface or a userdata is written as the fork
  --- writes it, the test for a table (for userdata): the tree's own, which the ceilings of `[checked]` count as the checker's
  --- `is_on_record` and let no more of, so that the program is not refused for a test the fork wrote. Without it such a test
  --- is refused, as it is of a program that has no ceiling for it. With `served` the Lua is that of a build that serves every
  --- module ([`Codegen.generate`]'s `served`: a type import never read as a value is not loaded), as the build's compile writes
  --- it; without it, that of a file compiled alone, as `cosmic compile` does.
  emit: function(build: Driver.Build, result: Driver.Outcome, facts?: boolean, counted?: boolean, served?: boolean): Emitted

  --- Compiles `sources` together. The answer holds one entry for each, in order. After a syntax error in
  --- any file no file has Lua and the other stages did not run. With `facts` the Lua checks the conclusions of the
  --- checker about the places a test narrowed. With `standalone` and no declaration file among `sources`, they are checked
  --- against its globals and `cosmic.*` modules, and a warning is reported with the errors, as a standalone run refuses it.
  compile: function(sources: {Source}, facts?: boolean, standalone?: Standalone): {Compiled}
end

compile_grammar.module_of = Declarations.module_of

local function problem(code: string, msg: string, fix: string, y: integer, x: integer, offset: integer): compile_grammar.Problem
  return { code = code, msg = msg, fix = fix, y = y, x = x, offset = offset }
end

--- A problem of the driver, as `cosmic compile` reports it.
local function reported(p: Driver.Problem): compile_grammar.Problem
  return problem(p.code, p.msg, p.fix, p.y, p.x, p.offset)
end

--- How many of a file's refusals the complaint lists.
local REPORTED <const> = 20

--- What a test for a type of these tags writes: the word of `type(v)`, or `integer`, `true`, `false`, `nil`.
local KINDS <const>: {string: string} = {
  integer = "integer", number = "number", string = "string", boolean = "boolean",
  ["true"] = "true", ["false"] = "false", ["nil"] = "nil",
}

--- The word a test for the type `t` is written by, nil where the syntax says it.
local function kind_of(t: Types.Type): string?
  if (t.tag == "fn") then
    return "function"
  end
  return KINDS[t.tag]
end

--- What the checker concluded of the type names of `result`, for the generator, and the tests of it the Lua cannot tell.
local function type_facts(program: Declarations.Program, result: Driver.Outcome, lowered: Declarations.Lowered,
                          counted?: boolean): {integer: string}, {string}
  local kinds: mut {integer: string} = {}
  local refused: mut {string} = {}
  local library = program.globals["table"]
  -- Every node, the walk's own list growing as it goes.
  local nodes: mut {Ast.Node} = { result.chunk.body }
  for _, node in ipairs(nodes) do
    if (node.kind == "TypeName") then
      local t = lowered.types[node.id]
      if t ~= nil then
        local word = kind_of(t)
        if word ~= nil then
          kinds[node.id] = word
        end
      end
    elseif (node.kind == "IsTest") then
      local t = lowered.types[node.type.id]
      local why: string?
      if t ~= nil and (t.tag == "named") and t.decl.kind ~= "enum" and not (library ~= nil and library.decl == t.decl) then
        local tested = node.type
        if counted == true and (t.decl.kind == "record" or t.decl.kind == "interface" or t.decl.kind == "userdata") and
            (tested.kind == "TypeName") then
          -- The test of a record is the test for a table, as the fork writes it: the checker reports it (`is_on_record`) and
          -- the ceilings of `[checked]` count it, so the tests the tree has are the ones this writes and no more.
          kinds[tested.id] = if t.decl.kind == "userdata" then "userdata" else "table" end
        elseif t.decl.kind ~= "class" then
          why = "a " .. t.decl.kind .. " has no run-time tag to test"
        elseif t.decl.module ~= result.module then
          why = "the class belongs to " .. t.decl.module .. ", whose table this module cannot reach"
        end
      end
      local tokens, at = result.chunk.tokens, node.first
      if t == nil then
        -- Reported with its position where the token has one, and without it where not: never dropped.
        local where = if tokens.y[at] ~= nil then tostring(Lexer.y(tokens, at)) .. ":" .. tostring(Lexer.x(tokens, at)) .. ": " else "" end
        refused[#refused + 1] = where .. "no type was lowered for this test"
      end
      if why ~= nil and tokens.y[at] ~= nil then
        refused[#refused + 1] = tostring(Lexer.y(tokens, at)) .. ":" .. tostring(Lexer.x(tokens, at)) ..
          ": a test the Lua cannot tell: " .. why ..
          " (is_on_record): test a tag (`x.kind == \"...\"`), declare a class, or validate the data"
      end
    end
    Ast.children(node, function(child: Ast.Node)
      nodes[#nodes + 1] = child
    end)
  end
  return kinds, refused
end

function compile_grammar.emit(build: Driver.Build, result: Driver.Outcome, facts?: boolean, counted?: boolean, served?: boolean):
    compile_grammar.Emitted
  local checked = result.checked
  local lowered = result.lowered
  if checked == nil or lowered == nil then
    return { code = nil, trouble = "" }
  end
  local classes: mut {integer: string} = {}
  for id, decl in pairs(checked.literals) do
    classes[id] = decl.name
  end
  local kinds, refusals = type_facts(build.program, result, lowered, counted)
  local wraps: {integer: string}? = nil
  local boundary_checks: {integer: string}? = nil
  if facts == true then
    wraps = FactWraps.of(checked.narrowed, result.text, result.source.filename, result.chunk)
    boundary_checks = BoundaryChecks.of(checked.boundaries, result.text, result.source.filename)
  end
  local generated = Codegen.generate(result.chunk, result.scoped, result.never_false, classes, Check.enums(lowered), wraps, kinds,
    served == true, boundary_checks)
  local lines: mut {string} = {}
  for _, e in ipairs(generated.errors) do
    lines[#lines + 1] = tostring(e.y) .. ":" .. tostring(e.x) .. ": " .. e.msg .. " (" .. e.code .. "): " .. e.fix
  end
  for _, line in ipairs(refusals) do
    lines[#lines + 1] = line
  end
  if #lines == 0 then
    return { code = generated.text, trouble = "" }
  elseif #lines > REPORTED then
    local more = #lines - REPORTED
    return { code = nil, trouble = table.concat(lines, "\n", 1, REPORTED) .. "\n... and " .. tostring(more) .. " more" }
  end
  return { code = nil, trouble = table.concat(lines, "\n") }
end

--- The `cosmic.*` modules the files of `sources` require that none of them is the module of: bindings the new checker cannot
--- declare, which the program is told of before anything is lowered.
--
-- TODO: parse each file once, by letting a build be told a binding after it has parsed a module and before it lowers one
-- ([`Driver.Options`]'s `external` is read when the build is made): the files that name `cosmic.` are parsed here and again by
-- the build.
local function bindings_of(sources: {compile_grammar.Source}, provided: {string: boolean}): {string}
  local out: mut {string} = {}
  local seen: mut {string: boolean} = {}
  for _, source in ipairs(sources) do
    -- Only a file that names one can require one: the others are not parsed here.
    if source.text:find("cosmic.", 1, true) ~= nil then
      local parsed = Parser.parse(Lexer.lex(source.text, source.relative), source.relative,
        if source.declaration then "decl" else "tl" end)
      for _, r in ipairs(parsed.chunk.requires) do
        if r.module:sub(1, 7) == "cosmic." and provided[r.module] ~= true and seen[r.module] ~= true then
          seen[r.module] = true
          out[#out + 1] = r.module
        end
      end
    end
  end
  return out
end

function compile_grammar.compile(sources: {compile_grammar.Source}, facts?: boolean, standalone?: compile_grammar.Standalone):
    {compile_grammar.Compiled}
  -- The declaration files given declare the globals of every file; a source is the module its path names.
  local globals: mut {Driver.Source} = {}
  local given: mut {Driver.Source} = {}
  local names: mut {string} = {}
  local by_module: mut {string: Driver.Source} = {}
  local provided: mut {string: boolean} = {}
  -- The modules a declaration is given for: a source of the same name is their implementation, as in a build
  -- ([`Driver.implementation`]), and a require reads the declaration.
  local declared: mut {string: boolean} = {}
  for _, source in ipairs(sources) do
    if source.declaration then declared[Declarations.module_of(source.relative)] = true end
  end
  for index, source in ipairs(sources) do
    local module = Declarations.module_of(source.relative)
    provided[module] = true
    local made: Driver.Source
    if source.declaration then
      made = Driver.declarations(module, source.relative, source.text, {})
      globals[#globals + 1] = made
    else
      if declared[module] == true then module = Driver.implementation(module) end
      made = Driver.source(module, source.relative, source.text, "tl")
    end
    given[index] = made
    names[index] = module
    by_module[module] = made
  end
  -- With no declaration file given, a standalone run's globals and `cosmic.*` modules stand for them: the binary's own, so
  -- nothing is typed `invalid` for lack of them.
  local alone = if #globals == 0 then standalone else nil end
  local build: Driver.Build
  if alone ~= nil then
    build = Driver.new({ globals = alone.globals, adjust = alone.adjust, external = {}, types = false })
  else
    build = Driver.new({ globals = globals, adjust = nil, external = bindings_of(sources, provided), types = false })
  end
  build:provide(function(module: string): Driver.Source?
    return by_module[module]
  end)
  if alone ~= nil then
    build:provide(alone.standard)
  end

  local results: mut {Driver.Outcome} = {}
  local syntax_errors: mut {{compile_grammar.Problem}} = {}
  local refused = false
  for index, source in ipairs(given) do
    local outcome = assert(build:parsed(source.module), source.module .. " is a source given")
    results[index] = outcome
    local found: mut {compile_grammar.Problem} = {}
    for _, p in ipairs(outcome.syntax) do
      found[#found + 1] = reported(p)
    end
    syntax_errors[index] = found
    refused = refused or #found > 0
  end
  local made: mut {compile_grammar.Compiled} = {}
  if refused then
    for index, source in ipairs(sources) do
      made[index] = {
        path = source.path, declaration = source.declaration, code = nil, syntax_errors = syntax_errors[index] or {},
        type_errors = {}, trouble = "",
      }
    end
    return made
  end

  -- A file is lowered after the files it requires, so that the checker finds their bodies; the declaration
  -- files come first, since every file may use their globals.
  build:lower(names)
  for index, source in ipairs(sources) do
    local result = assert(build:result(assert(names[index]), true))
    local errors: mut {compile_grammar.Problem} = {}
    for _, p in ipairs(result.errors) do
      -- What a standalone file returns is its entry point, which no declaration describes ([`build.pipeline`]'s `checked_alone`).
      if not (alone ~= nil and p.code == "export_not_declared") then
        errors[#errors + 1] = reported(p)
      end
    end
    if alone ~= nil then
      -- A standalone check refuses a warning as it does an error.
      for _, p in ipairs(result.warnings) do
        errors[#errors + 1] = reported(p)
      end
      table.sort(errors, function(a: compile_grammar.Problem, b: compile_grammar.Problem): boolean
        if a.y ~= b.y then return a.y < b.y end
        return a.x < b.x
      end)
    end
    local code: string? = nil
    local trouble = ""
    if not source.declaration then
      local emitted = compile_grammar.emit(build, result, facts)
      code, trouble = emitted.code, emitted.trouble
    end
    made[index] = {
      path = source.path, declaration = source.declaration, code = code, syntax_errors = syntax_errors[index] or {},
      type_errors = errors, trouble = trouble,
    }
  end
  return made
end

return compile_grammar
