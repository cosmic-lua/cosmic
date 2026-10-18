--- Helpers for the tests of [`lang.check`]: a source checked the way a project's modules are (lexed, parsed, scoped,
--- lowered, checked) against a small standard library written in the grammar.
local Ast = require("lang.ast")
local Check = require("lang.check")
local Codegen = require("lang.codegen")
local Codes = require("lang.check_codes")
local Corrections = require("lang.stdlib_corrections")
local Declarations = require("lang.declarations")
local FactWraps = require("lang.fact_wraps")
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

  --- The library of [`Programs.run`] lowered once: a function that checks a source as the module `module` (`t` by
  --- default), after the `modules` it requires. Each source is a module of its own, so name them apart.
  runner: function(): function(source: string, module?: string, modules?: {string: string}): Run

  --- Checks `source` as the module `t` against the declarations the tree's checks read: `prelude`, the text of the
  --- fork's prelude (between the `[=====[` marks of checker/tl.tl), and `stdlib`, the text of checker/stdlib.d.tl, which
  --- [`lang.stdlib_corrections`] corrects and [`lang.translate`] writes in the new grammar.
  standard: function(prelude: string, stdlib: string, source: string, modules?: {string: string}): Run

  --- The declarations of [`Programs.standard`] lowered once: a function that checks a source as the module `module`
  --- (`t` by default), after the `modules` it requires, against them. Each source is a module of its own, so name them
  --- apart; a program that declares a global would show it to the next, and the translated programs do not.
  session: function(prelude: string, stdlib: string): function(source: string, module?: string, modules?: {string: string}): Run

  --- The codes of the errors of `run`, space separated, in order.
  codes: function(run: Run): string

  --- A `__fact`: it is called with the value of a narrowed read, what the checker concluded of it ([`lang.fact_wraps`]) and
  --- where the read is, answers the value and raises where the conclusion is false of it.
  type FactHook = function(v: any, taken: string, place: string, strings?: {string}, classes?: {any}, tag?: string,
                           tags?: {string}, at?: string): any

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
  --- fork does, a test for the kind, to show that the checks see what that lets through. `hook` is the `__fact` to run
  --- the wraps with, in place of this module's own: the one the tool's worker defines ([`build.test_worker`]'s
  --- `install_checks`) can be run on the programs a test draws.
  execute: function(source: string, facts: boolean, modules?: {string: string}, kind_only?: boolean, hook?: FactHook): Execution

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
]] .. "  global record coroutine\n    " .. table.concat(Corrections.lines("coroutine", "create"), "\n    ") .. "\n    " ..
  table.concat(Corrections.lines("coroutine", "wrap"), "\n    ") .. "\n    " ..
  table.concat(Corrections.lines("coroutine", "resume"), "\n    ") .. "\n    " ..
  table.concat(Corrections.lines("coroutine", "close"), "\n    ") .. "\n    " ..
  table.concat(Corrections.lines("coroutine", "status"), "\n    ") .. "\n  end\n  " ..
  table.concat(Corrections.added, "\n  ") .. "\n" .. [[
  global record table
    insert: function<A>(mut {A}, integer, A)
    insert: function<A>(mut {A}, A)
    concat: function({string}, p2?: string): string
    remove: function<A>(mut {A}, p2?: integer): A?
    sort: function(mut {integer}, ? function(integer, integer): boolean)
    sort: function(mut {number}, ? function(number, number): boolean)
    sort: function(mut {string}, ? function(string, string): boolean)
    sort: function<A>(mut {A}, function(A, A): boolean)
  end
  global record math
    max: function(integer, ...: integer): integer
    max: function(number, ...: number): number
  end
  local record Lib
    print: function(...: any)
    tostring: function(any): string
    tonumber: function(any): number?
    tonumber: function(any, integer): integer?
    ipairs: function<A>({A}): (function({A}, integer): (integer, A), {A}, integer)
    pairs: function<K, V>({K: V}): (function({K: V}, p2?: K): (K, V), {K: V}, K)
    assert: function<A>(A?): A
    assert: function<A, B>(A?, B, ...: any): (A, B, any...)
    error: function(p1?: any): never
    require: function(string): any
]] .. "    " .. table.concat(Corrections.protected("pcall", 3, 2), "\n    ") .. "\n    " ..
  table.concat(Corrections.protected("xpcall", 2, 2), "\n    ") .. "\n" .. [[
    type: function(any): string
    setmetatable: function<A>(A, any): A
  end
  global print <const> = Lib.print
  global tostring <const> = Lib.tostring
  global tonumber <const> = Lib.tonumber
  global ipairs <const> = Lib.ipairs
  global pairs <const> = Lib.pairs
  global assert <const> = Lib.assert
  global error <const> = Lib.error
  global require <const> = Lib.require
  global pcall <const> = Lib.pcall
  global xpcall <const> = Lib.xpcall
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
  local result: Check.Checked = { errors = {}, vars = {}, literals = {}, narrowed = {}, types = {}, warnings = {} }
  if dialect == "tl" then
    result = Check.check(program, input, lowered)
  end
  return {
    program = program, errors = result.errors, result = result, chunk = parsed.chunk, scoped = scoped,
    lowered = lowered, before = before,
  }
end

function Programs.runner(): function(source: string, module?: string, modules?: {string: string}): Programs.Run
  local program = Declarations.new()
  program.external["cosmic.sys"] = true
  local library = Parser.parse(Lexer.lex(Programs.library, "std.d.tl"), "std.d.tl", "decl")
  local globals = Scopes.declared(library.chunk)
  local _ = lower(program, "std", Programs.library, "decl", {})
  return function(source: string, module?: string, modules?: {string: string}): Programs.Run
    local names: {string} = {}
    for name in pairs(modules or {}) do
      names[#names + 1] = name
    end
    table.sort(names)
    for _, name in ipairs(names) do
      local _ = lower(program, name, (modules or {})[name], "tl", globals)
    end
    return lower(program, module or "t", source, "tl", globals)
  end
end

function Programs.run(source: string, modules?: {string: string}): Programs.Run
  return Programs.runner()(source, "t", modules)
end

function Programs.session(prelude: string, stdlib: string): function(source: string, module?: string, modules?: {string: string}): Programs.Run
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
  add("lang/stdlib_corrections.tl", table.concat(Corrections.added, "\n"))
  local _ = lower(program, "checker.prelude", prelude, "decl", {})
  local corrected = Corrections.apply(stdlib)
  assert(#corrected.problems == 0, table.concat(corrected.problems, "\n"))
  local _ = lower(program, "checker.stdlib", Translate.translate(corrected.text, "checker/stdlib.d.tl").text, "decl", globals)
  return function(source: string, module?: string, modules?: {string: string}): Programs.Run
    local names: {string} = {}
    for name in pairs(modules or {}) do
      names[#names + 1] = name
    end
    table.sort(names)
    for _, name in ipairs(names) do
      local _ = lower(program, name, (modules or {})[name], "tl", globals)
    end
    return lower(program, module or "t", source, "tl", globals)
  end
end

function Programs.standard(prelude: string, stdlib: string, source: string, modules?: {string: string}): Programs.Run
  return Programs.session(prelude, stdlib)(source, "t", modules)
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

--- A coroutine of the typed library, over Lua's own: what can be done with it, each closed over the thread.
local record Co
  resume: function(...: any): (boolean, any...)
  close: function(): (boolean, any...)
  status: function(): string
end

--- The typed `coroutine` library the declarations of [`lang.stdlib_corrections`] describe, over Lua's: a body is called
--- with the handle that yields and the value the first `resume` sent, `resume` answers `true` and what was yielded or
--- returned or `false` and the error, and a handle yields only for the coroutine it was made for.
--
-- TODO: drop this library, and run the Lua against the runtime's, once the runtime provides the typed `coroutine`
-- (the TODO of [`lang.stdlib_corrections`]).
local function typed_coroutines(): {string: any}
  local library: {string: any} = {}
  local function create(body: function(...: any): any...): Co
    local handle: {string: any} = {}
    local thread = coroutine.create(function(first: any): any
      return body(handle, first)
    end)
    handle.yield = function(_self: any, y: any): any
      if coroutine.running() ~= thread then
        error("a handle yields for the coroutine it was made for", 2)
      end
      return coroutine.yield(y)
    end
    return {
      resume = function(...: any): (boolean, any...)
        return coroutine.resume(thread, ...)
      end,
      close = function(): (boolean, any...)
        return coroutine.close(thread)
      end,
      status = function(): string
        return coroutine.status(thread)
      end,
    }
  end
  library.create = create
  library.resume = function(co: Co, ...: any): (boolean, any...)
    return co.resume(...)
  end
  library.close = function(co: Co): (boolean, any...)
    return co.close()
  end
  library.status = function(co: Co): string
    return co.status()
  end
  library.isyieldable = coroutine.isyieldable
  library.wrap = function(body: function(...: any): any...): function(...: any): any
    local co = create(body)
    return function(...: any): any
      local results = table.pack(co.resume(...))
      if not results[1] then
        error(results[2], 0)
      end
      return results[2]
    end
  end
  return library
end

--- The `__fact` that [`Programs.execute`] runs a program with unless it is given another: it raises `fact violated: ...`
--- for a read whose conclusion is false of the value.
local function own_fact(v: any, kinds: string, name: string, strings?: {string}, tables?: {any}, tag?: string, tags?: {string},
                        _at?: string): any
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

function Programs.execute(source: string, facts: boolean, modules?: {string: string}, kind_only?: boolean,
                          hook?: Programs.FactHook): Programs.Execution
  local run = Programs.run(source, modules)
  local done: Programs.Execution = { run = run, ran = false, lua = "", printed = {}, fault = nil }
  if not taken(run) then
    return done
  end
  local wraps: {integer: string} = {}
  if facts then
    wraps = FactWraps.of(run.result.narrowed, source, "t")
  end
  local classes: {integer: string} = {}
  for id, decl in pairs(run.result.literals) do
    classes[id] = decl.name
  end
  done.lua = Codegen.generate(run.chunk, run.scoped, nil, classes, kind_only and {} or Check.enums(run.lowered), wraps).text
  local env: {string: any} = {
    assert = assert, ipairs = ipairs, pairs = pairs, math = math, tostring = tostring, tonumber = tonumber, type = type, error = error, pcall = pcall, xpcall = xpcall,
    string = string, table = table, select = select, setmetatable = setmetatable, getmetatable = getmetatable,
    coroutine = typed_coroutines(),
  }
  env.print = function(...: any)
    local parts: {string} = {}
    for i = 1, select("#", ...) do
      parts[i] = tostring((select(i, ...)))
    end
    done.printed[#done.printed + 1] = table.concat(parts, "\t")
  end
  env.__fact = hook or own_fact
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
