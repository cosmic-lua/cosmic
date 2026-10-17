--- Helpers for the tests of [`lang.check`]: a source checked the way a project's modules are (lexed, parsed, scoped,
--- lowered, checked) against a small standard library written in the grammar.
local Ast = require("lang.ast")
local Check = require("lang.check")
local Codegen = require("lang.codegen")
local Codes = require("lang.check_codes")
local Corrections = require("lang.stdlib_corrections")
local Declarations = require("lang.declarations")
local Lexer = require("lang.lexer")
local Parser = require("lang.parser")
local Scopes = require("lang.scopes")
local Translate = require("lang.translate")
local Types = require("lang.types")

local record Programs
  --- What checking one source gave.
  record Run
    program: Declarations.Program
    errors: {Codes.Error}
    result: Check.Checked
    chunk: Ast.Chunk
    scoped: Scopes.Scoped
    lowered: Declarations.Lowered
    --- The codes of the errors of the parser, the scope builder and the lowering, which came first.
    before: {string}
  end

  --- The declarations the standard library is: the globals a program may use, as a declaration file.
  library: string

  --- Checks `source` as the module `t`, after lowering the library and the `modules` it requires (by name, in the
  --- order of their names).
  run: function(source: string, modules?: {string: string}): Run

  --- Checks `source` as the module `t` against the declarations the tree's checks read: `prelude`, the text of the
  --- fork's prelude (between the `[=====[` marks of checker/tl.tl), and `stdlib`, the text of checker/stdlib.d.tl, which
  --- [`lang.stdlib_corrections`] corrects and [`lang.translate`] writes in the new grammar.
  standard: function(prelude: string, stdlib: string, source: string, modules?: {string: string}): Run

  --- The codes of the errors of `run`, space separated, in order.
  codes: function(run: Run): string

  --- What running a checked program did.
  record Execution
    run: Run
    --- Whether the checker took the program (no error but the `unchecked_*` of forms a later piece types) and it ran.
    ran: boolean
    --- The Lua that ran, or "".
    lua: string
    --- What the program printed, one string per call of `print`, its arguments tab separated.
    printed: {string}
    --- The error the run raised, or nil: a nil operand, a `fact violated` or an `assert` that failed.
    fault: string | nil
  end

  --- Checks `source` and, where the checker takes it, writes it as Lua and runs it with `print` collected. With `facts`
  --- every read of a place whose type a test narrowed ([`Check.Checked.narrowed`]) is wrapped in a check of what the
  --- checker concluded: that the value is none of the kinds taken out, a member of the enum, of a class, or of the
  --- members a tag tells apart, which raises `fact violated: <place> is ...`. `kind_only` writes `v is E` of an enum as the
  --- fork does, a test for the kind, to show that the checks see what that lets through.
  execute: function(source: string, facts: boolean, modules?: {string: string}, kind_only?: boolean): Execution

  --- The type of the first variable called `name`.
  var: function(run: Run, name: string): Types.Type
end

Programs.library = [[
do
  global record string
    upper: function(string): string
    sub: function(string, integer, p3?: integer): string
    format: function(string, ...: any): string
    find: function(string, string, p3?: integer, p4?: boolean): integer?, integer?
    gsub: function(string, string, string, p4?: integer): string, integer
    gsub: function(string, string, function(string): string, p4?: integer): string, integer
  end
  global record Opts
    n: integer
  end
  global record Over
    put: function(Opts, p2?: integer): integer
    put: function(string, p2?: integer): integer
  end
  global record More
    run: function(function(string, string): string)
    run: function(function(string): string)
    run: function(function(): string)
  end
  global record Fewer
    run: function(function(string): string)
    run: function(function(string, string): string)
  end
  global record coroutine
    create: function(function()): any
    wrap: function(function()): function()
    yield: function()
  end
  global record table
    insert: function<A>(mut {A}, A)
    concat: function({string}, p2?: string): string
  end
  local record Lib
    print: function(...: any)
    tostring: function(any): string
    tonumber: function(any): number?
    tonumber: function(any, integer): integer?
    ipairs: function<A>({A}): (function({A}, integer): (integer, A), {A}, integer)
    assert: function<A>(A?, p2?: string): A
    error: function(p1?: any): never
    require: function(string): any
    pcall: function(function(...: any): any, ...: any): boolean
    type: function(any): string
    setmetatable: function<A>(A, any): A
  end
  global print <const> = Lib.print
  global tostring <const> = Lib.tostring
  global tonumber <const> = Lib.tonumber
  global ipairs <const> = Lib.ipairs
  global assert <const> = Lib.assert
  global error <const> = Lib.error
  global require <const> = Lib.require
  global pcall <const> = Lib.pcall
  global type <const> = Lib.type
  global setmetatable <const> = Lib.setmetatable
end
]]

--- Lowers `source` as the module `module` of `program`.
local function lower(program: Declarations.Program, module: string, source: string, dialect: Ast.Dialect,
                     globals: {string: Scopes.Global}): Programs.Run
  local name = module .. (dialect == "decl" and ".d.tl" or ".tl")
  local parsed = Parser.parse(Lexer.lex(source, name), name, dialect)
  local scoped = Scopes.build(parsed.chunk, name, globals)
  local input: Declarations.Input = {
    module = module, filename = name, chunk = parsed.chunk, scoped = scoped, dialect = dialect,
  }
  local lowered = program:lower(input)
  local before: {string} = {}
  for _, e in ipairs(parsed.errors) do
    before[#before + 1] = e.code
  end
  for _, e in ipairs(scoped.errors) do
    before[#before + 1] = e.code
  end
  for _, e in ipairs(lowered.errors) do
    before[#before + 1] = e.code
  end
  local result: Check.Checked = { errors = {}, vars = {}, literals = {}, narrowed = {} }
  if dialect == "tl" then
    result = Check.check(program, input, lowered)
  end
  return {
    program = program, errors = result.errors, result = result, chunk = parsed.chunk, scoped = scoped,
    lowered = lowered, before = before,
  }
end

function Programs.run(source: string, modules?: {string: string}): Programs.Run
  local program = Declarations.new()
  program.external["cosmic.sys"] = true
  local library = Parser.parse(Lexer.lex(Programs.library, "std.d.tl"), "std.d.tl", "decl")
  local globals = Scopes.declared(library.chunk)
  local _ = lower(program, "std", Programs.library, "decl", {})
  local names: {string} = {}
  for name in pairs(modules or {}) do
    names[#names + 1] = name
  end
  table.sort(names)
  for _, name in ipairs(names) do
    local _ = lower(program, name, (modules or {})[name], "tl", globals)
  end
  return lower(program, "t", source, "tl", globals)
end

function Programs.standard(prelude: string, stdlib: string, source: string, modules?: {string: string}): Programs.Run
  local program = Declarations.new()
  program.external["cosmic.sys"] = true
  local globals: {string: Scopes.Global} = {}
  local function add(file: string, text: string)
    for name, g in pairs(Scopes.declared(Parser.parse(Lexer.lex(text, file), file, "decl").chunk)) do
      globals[name] = g
    end
  end
  add("prelude.d.tl", prelude)
  -- The prelude declares `interface userdata is userdata`, which the new parser reads as the declaration of `interface`.
  globals["interface"] = nil
  globals["userdata"] = { space = "type", const = false }
  add("checker/stdlib.d.tl", stdlib)
  local _ = lower(program, "checker.prelude", prelude, "decl", {})
  local corrected = Corrections.apply(stdlib)
  assert(#corrected.problems == 0, table.concat(corrected.problems, "\n"))
  local _ = lower(program, "checker.stdlib", Translate.translate(corrected.text, "checker/stdlib.d.tl").text, "decl", globals)
  local names: {string} = {}
  for name in pairs(modules or {}) do
    names[#names + 1] = name
  end
  table.sort(names)
  for _, name in ipairs(names) do
    local _ = lower(program, name, (modules or {})[name], "tl", globals)
  end
  return lower(program, "t", source, "tl", globals)
end

--- The checker took the program: it has no error but the forms a later piece types.
local function taken(run: Programs.Run): boolean
  if #run.before > 0 then
    return false
  end
  for _, e in ipairs(run.errors) do
    if not tostring(e.code):find("^unchecked_") then
      return false
    end
  end
  return true
end

--- The Lua text of the strings of `list`, as a table.
local function lua_strings(list: {string}): string
  local out: {string} = {}
  for i, v in ipairs(list) do
    out[i] = (string.format("%q", v):gsub("\\\n", "\\n"))
  end
  return "{" .. table.concat(out, ", ") .. "}"
end

--- The arguments after the value of the call of `__fact` that wraps the read `n`: the kinds taken out, the place, and what
--- the checker concluded of the strings, classes and tag of the value, each nil where it concluded nothing.
local function fact_arguments(n: Check.Narrowed): string
  local strings, classes, tags = n.strings, n.classes, n.tags
  local parts: {string} = {
    lua_strings({ table.concat(n.taken, ",") }):sub(2, -2), (string.format("%q", n.text):gsub("\\\n", "\\n")),
    strings ~= nil and lua_strings(strings) or "nil", classes ~= nil and "{" .. table.concat(classes, ", ") .. "}" or "nil",
    n.tag ~= nil and lua_strings({ n.tag }):sub(2, -2) or "nil", tags ~= nil and lua_strings(tags) or "nil",
  }
  return table.concat(parts, ", ")
end

function Programs.execute(source: string, facts: boolean, modules?: {string: string}, kind_only?: boolean): Programs.Execution
  local run = Programs.run(source, modules)
  local done: Programs.Execution = { run = run, ran = false, lua = "", printed = {}, fault = nil }
  if not taken(run) then
    return done
  end
  local wraps: {integer: string} = {}
  if facts then
    for _, n in ipairs(run.result.narrowed) do
      wraps[n.id] = fact_arguments(n)
    end
  end
  local classes: {integer: string} = {}
  for id, decl in pairs(run.result.literals) do
    classes[id] = decl.name
  end
  done.lua = Codegen.generate(run.chunk, run.scoped, nil, classes, kind_only and {} or Check.enums(run.lowered), wraps).text
  local env: {string: any} = {
    assert = assert, ipairs = ipairs, tostring = tostring, tonumber = tonumber, type = type, error = error, pcall = pcall,
    string = string, table = table, select = select, setmetatable = setmetatable, getmetatable = getmetatable,
    coroutine = coroutine,
  }
  env.print = function(...: any)
    local parts: {string} = {}
    for i = 1, select("#", ...) do
      parts[i] = tostring((select(i, ...)))
    end
    done.printed[#done.printed + 1] = table.concat(parts, "\t")
  end
  env.__fact = function(v: any, kinds: string, name: string, strings: {string} | nil, tables: {any} | nil, tag: string | nil,
                        tags: {string} | nil): any
    local kind = type(v)
    local function fails(why: string)
      error("fact violated: " .. name .. " is " .. why, 0)
    end
    for k in kinds:gmatch("[^,]+") do
      if k == kind then
        fails("a " .. kind .. ", the checker proved not " .. kinds)
      end
    end
    local function among(list: {any}, value: any): boolean
      for _, each in ipairs(list) do
        if each == value then
          return true
        end
      end
      return false
    end
    if strings ~= nil and kind == "string" and not among(strings, v) then
      fails("the string " .. tostring(v) .. ", the checker proved one of " .. table.concat(strings, ","))
    end
    if v is {string: any} then
      if tables ~= nil and not among(tables, getmetatable(v)) then
        fails("a table of another class than the checker proved")
      end
      if tag ~= nil and tags ~= nil then
        local field = v[tag]
        if not among(tags, field) then
          fails("a table whose " .. tag .. " is " .. tostring(field) .. ", the checker proved one of " .. table.concat(tags, ","))
        end
      end
    end
    return v
  end
  local chunk, why = load(done.lua, "=t", "t", env)
  if chunk == nil then
    done.fault = "the Lua does not load: " .. tostring(why)
    return done
  end
  local ok, err = pcall(chunk)
  done.ran = true
  if not ok then
    done.fault = tostring(err)
  end
  return done
end

function Programs.codes(run: Programs.Run): string
  local out: {string} = {}
  for _, e in ipairs(run.errors) do
    out[#out + 1] = e.code
  end
  return table.concat(out, " ")
end

function Programs.var(run: Programs.Run, name: string): Types.Type
  for _, v in ipairs(run.scoped.list) do
    if v.name == name then
      local t = run.result.vars[v.id]
      assert(t ~= nil, name .. " has no type")
      return t
    end
  end
  error("no variable " .. name)
end

return Programs
