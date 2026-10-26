--- Helpers for the tests of [`lang.check`]: a source checked the way a project's modules are (lexed, parsed, scoped,
--- lowered, checked) against a small standard library written in the grammar.
local Ast = require("lang.ast")
local Check = require("lang.check")
local Codegen = require("lang.codegen")
local Codes = require("lang.check_codes")
local Declarations = require("lang.declarations")
local FactWraps = require("lang.fact_wraps")
local Lexer = require("lang.lexer")
local Parser = require("lang.parser")
local Scopes = require("lang.scopes")
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
    --- What checking each module it required gave, by name: those [`Programs.runner`] was given as `modules`.
    required?: {string: Run}
  end

  --- The declarations the standard library is: the globals a program may use, as a declaration file.
  library: string

  --- Checks `source` as the module `t`, after lowering the library and the `modules` it requires (by name, in the
  --- order of their names). `declared` are modules written as declaration files (`.d.tl`), lowered first.
  run: function(source: string, modules?: {string: string}, declared?: {string: string}): Run

  --- The library of [`Programs.run`] lowered once: a function that checks a source as the module `module` (`t` by
  --- default), after the `modules` it requires and the `declared` ones, which are declaration files. Each source is a module
  --- of its own, so name them apart.
  runner: function(): function(source: string, module?: string, modules?: {string: string}, declared?: {string: string}): Run

  --- Checks `source` as the module `t` against the declarations the tree's checks read: `prelude`, the text of
  --- lang/prelude.d.tl, and `stdlib`, the text of lang/stdlib.d.tl.
  standard: function(prelude: string, stdlib: string, source: string, modules?: {string: string}): Run

  --- The declarations of [`Programs.standard`] lowered once: a function that checks a source as the module `module`
  --- (`t` by default), after the `modules` it requires, against them. Each source is a module of its own, so name them
  --- apart; a program that declares a global would show it to the next, and the translated programs do not. `external` names
  --- the modules that are bindings of C whose types the program does not read ([`cosmic.sys`] by default).
  session: function(prelude: string, stdlib: string, external?: {string}): function(source: string, module?: string, modules?: {string: string}): Run

  --- The codes of the errors the declaration files themselves have, `prelude` first and then `stdlib`, each as `<file>: <code>`:
  --- of the parser, the scope builder and the lowering. None for declarations that are whole, which a program checked against
  --- them cannot tell, since an error of a global's declaration is not one of the program's.
  declared: function(prelude: string, stdlib: string): {string}

  --- The declarations `prelude` and `stdlib` lower to, one line each in the order of their names: a global with its kind, each
  --- field and method of it with its type, then each value a global binds, so that an edit of either file shows in a diff.
  dump: function(prelude: string, stdlib: string): string

  --- The Lua the code generator writes for the program of `run`, which the checker took.
  lua: function(run: Run): string

  --- The codes of the errors of `run`, space separated, in order.
  codes: function(run: Run): string

  --- A `__fact`: it is called with the value of a narrowed read, what the checker concluded of it ([`lang.fact_wraps`]) and
  --- where the read is, answers the value and raises where the conclusion is false of it.
  type FactHook = function(v: any, taken: string, place: string, strings?: {string}, classes?: {any}, tag?: string,
                           tags?: {string} | string, at?: string): any

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
    fault: string?
  end

  --- Checks `source` and, where the checker takes it, writes it as Lua and runs it with `print` collected; a `require` of one
  --- of `modules` runs that module's Lua, written the same way, once. With `facts`
  --- every read of a place whose type a test narrowed ([`Check.Checked.narrowed`]) is wrapped in a check of what the
  --- checker concluded: that the value is none of the kinds taken out, a member of the enum, of a class, or of the
  --- members a tag tells apart, which raises `fact violated: <place> is ...`. `kind_only` writes `v is E` of an enum as the
  --- fork does, a test for the kind, to show that the checks see what that lets through. `hook` is the `__fact` to run
  --- the wraps with, in place of this module's own: the one the tool's worker defines ([`build.test_worker`]'s
  --- `install_checks`) can be run on the programs a test draws.
  --- With `anyway` the Lua of a program the checker refuses (but for a syntax error) runs as well, which shows the fault the
  --- refusal keeps from a program.
  execute: function(source: string, facts: boolean, modules?: {string: string}, kind_only?: boolean, hook?: FactHook,
                    anyway?: boolean): Execution

  --- The type of the first variable called `name`.
  var: function(run: Run, name: string): Types.Type
end

Programs.library = [[
do
  global record string
    upper: function(string): string
    sub: function(string, integer, p3?: integer): string
    format: function(string, ...: any): string
    find: function(string, string, p3?: integer, p4?: boolean): integer?, integer?, string...
    gsub: function(string, string, string, p4?: integer): string, integer
    gsub: function(string, string, function(string): string, p4?: integer): string, integer
    gsub: function(string, string, {string: string}, p4?: integer): string, integer
    gsub: function(string, string, {integer: string}, p4?: integer): string, integer
    match: function(string, string, p3?: integer): string...
    gmatch: function(string, string, p3?: integer): function(): string...
    pack: function(string, ...: any): string
    unpack: function(string, string, p3?: integer): any...
    packsize: function(string): integer
  end
  global record Matcher
    find: function(string, string): integer
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
    close: function<Y, R, S>(Coroutine<Y, R, S>): (true) | (false, any)
    create: function<Y, S>(function(Yielder<Y, S>, S)): Coroutine<Y, nil, S>
    create: function<Y, R, S>(function(Yielder<Y, S>, S): R): Coroutine<Y, R, S>
    create: function<Y>(function(Yielder<Y, nil>)): Coroutine<Y, nil, nil>
    create: function<Y, R>(function(Yielder<Y, nil>): R): Coroutine<Y, R, nil>
    create: function(function()): Coroutine<never, nil, nil>
    create: function<R>(function(): R): Coroutine<never, R, nil>
    resume: function<Y, R>(Coroutine<Y, R, nil>): (true, Y | R) | (false, any)
    resume: function<Y, R, S>(Coroutine<Y, R, S>, S): (true, Y | R) | (false, any)
    enum Status
      "suspended"
      "running"
      "normal"
      "dead"
    end
    status: function<Y, R, S>(Coroutine<Y, R, S>): Status
    wrap: function<Y, S>(function(Yielder<Y, S>, S)): function(S): Y?
    wrap: function<Y, R, S>(function(Yielder<Y, S>, S): R): function(S): Y | R
    wrap: function<Y>(function(Yielder<Y, nil>)): function(): Y?
    wrap: function<Y, R>(function(Yielder<Y, nil>): R): function(): Y | R
    wrap: function(function()): function()
    wrap: function<R>(function(): R): function(): R
  end
  global record Yielder<Y, S>
    userdata

    yield: function(Yielder<Y, S>, Y): S
  end

  global record Coroutine<Y, R, S>
    userdata
  end
  global record table
    insert: function<A>(mut {A}, integer, A)
    insert: function<A>(mut {A}, A)
    concat: function({string}, p2?: string): string
    unpack: function<A>({A}): A...
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
    select: function(integer, ...: any): any...
    tonumber: function(any): number?
    tonumber: function(any, integer): integer?
    ipairs: function<A>({A}): (function({A}, integer): (integer, A), {A}, integer)
    pairs: function<K, V>({K: V}): (function({K: V}, p2?: K): (K, V), {K: V}, K)
    assert: function<A>(A?): A
    assert: function<A, B>(A?, B, ...: any): (A, B, any...)
    error: function(p1?: any): never
    require: function(string): any
    pcall: function((function())): (true) | (false, any)
    pcall: function<R1>((function(): R1)): (true, R1) | (false, any)
    pcall: function<R1, R2>((function(): (R1, R2))): (true, R1, R2) | (false, any)
    pcall: function<A1>((function(A1)), A1): (true) | (false, any)
    pcall: function<A1, R1>((function(A1): R1), A1): (true, R1) | (false, any)
    pcall: function<A1, R1, R2>((function(A1): (R1, R2)), A1): (true, R1, R2) | (false, any)
    pcall: function<A1, A2>((function(A1, A2)), A1, A2): (true) | (false, any)
    pcall: function<A1, A2, R1>((function(A1, A2): R1), A1, A2): (true, R1) | (false, any)
    pcall: function<A1, A2, R1, R2>((function(A1, A2): (R1, R2)), A1, A2): (true, R1, R2) | (false, any)
    pcall: function<A1, A2, A3>((function(A1, A2, A3)), A1, A2, A3): (true) | (false, any)
    pcall: function<A1, A2, A3, R1>((function(A1, A2, A3): R1), A1, A2, A3): (true, R1) | (false, any)
    pcall: function<A1, A2, A3, R1, R2>((function(A1, A2, A3): (R1, R2)), A1, A2, A3): (true, R1, R2) | (false, any)
    xpcall: function<H>((function()), (function(any): H)): (true) | (false, H | string)
    xpcall: function<R1, H>((function(): R1), (function(any): H)): (true, R1) | (false, H | string)
    xpcall: function<R1, R2, H>((function(): (R1, R2)), (function(any): H)): (true, R1, R2) | (false, H | string)
    xpcall: function<A1, H>((function(A1)), (function(any): H), A1): (true) | (false, H | string)
    xpcall: function<A1, R1, H>((function(A1): R1), (function(any): H), A1): (true, R1) | (false, H | string)
    xpcall: function<A1, R1, R2, H>((function(A1): (R1, R2)), (function(any): H), A1): (true, R1, R2) | (false, H | string)
    xpcall: function<A1, A2, H>((function(A1, A2)), (function(any): H), A1, A2): (true) | (false, H | string)
    xpcall: function<A1, A2, R1, H>((function(A1, A2): R1), (function(any): H), A1, A2): (true, R1) | (false, H | string)
    xpcall: function<A1, A2, R1, R2, H>((function(A1, A2): (R1, R2)), (function(any): H), A1, A2): (true, R1, R2) | (false, H | string)
    type: function(any): string
    setmetatable: function<A>(A, any): A
  end
  global print <const> = Lib.print
  global tostring <const> = Lib.tostring
  global select <const> = Lib.select
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
--- `parsed` is the parse of `source` where the caller has it already.
local function lower(program: Declarations.Program, module: string, source: string, dialect: Ast.Dialect,
                     globals: {string: Scopes.Global}, required?: {string: Programs.Run}, read?: Parser.Parsed): Programs.Run
  local name = module .. (if dialect == "decl" then ".d.tl" else ".tl" end)
  local parsed = read or Parser.parse(Lexer.lex(source, name), name, dialect)
  local scoped = Scopes.build(parsed.chunk, name, globals)
  local input: Declarations.Input = {
    module = module, filename = name, chunk = parsed.chunk, scoped = scoped, dialect = dialect,
  }
  local lowered = program:lower(input)
  local before: mut {string} = {}
  for _, e in ipairs(parsed.errors) do
    before[#before + 1] = e.code
  end
  for _, e in ipairs(scoped.errors) do
    before[#before + 1] = e.code
  end
  for _, e in ipairs(lowered.errors) do
    before[#before + 1] = e.code
  end
  local result: Check.Checked = { errors = {}, vars = {}, literals = {}, narrowed = {}, types = {}, callees = {}, warnings = {} }
  if dialect == "tl" then
    result = Check.check(program, input, lowered)
  end
  return {
    program = program, errors = result.errors, result = result, chunk = parsed.chunk, scoped = scoped,
    lowered = lowered, before = before, required = required,
  }
end

--- The names of `named`, in order.
local function sorted_names<V>(named: {string: V}): {string}
  local names: mut {string} = {}
  for name in pairs(named) do
    names[#names + 1] = name
  end
  table.sort(names)
  return names
end

--- The parse of [`Programs.library`], made once: a runner lowers the library into a program of its own for each program a
--- test checks, and reading its text again each time was most of what that cost. Nothing writes the syntax tree.
local library_read: mut {Parser.Parsed} = {}

local function read_library(): Parser.Parsed
  local held = library_read[1]
  if held == nil then
    held = Parser.parse(Lexer.lex(Programs.library, "std.d.tl"), "std.d.tl", "decl")
    library_read[1] = held
  end
  return held
end

function Programs.runner(): function(source: string, module?: string, modules?: {string: string}, declared?: {string: string}): Programs.Run
  local program = Declarations.new()
  program.external["cosmic.sys"] = true
  local library = read_library()
  local globals = Scopes.declared(library.chunk)
  local _ = lower(program, "std", Programs.library, "decl", {}, nil, library)
  return function(source: string, module?: string, modules?: {string: string}, declared?: {string: string}): Programs.Run
    local files = declared or {}
    for _, name in ipairs(sorted_names(files)) do
      local _ = lower(program, name, assert(files[name]), "decl", globals)
    end
    local sources = modules or {}
    local required: mut {string: Programs.Run} = {}
    for _, name in ipairs(sorted_names(sources)) do
      required[name] = lower(program, name, assert(sources[name]), "tl", globals)
    end
    return lower(program, module or "t", source, "tl", globals, required)
  end
end

function Programs.run(source: string, modules?: {string: string}, declared?: {string: string}): Programs.Run
  return Programs.runner()(source, "t", modules, declared)
end

--- The program the declarations `prelude` and `stdlib` make, with the globals they declare and what lowering each gave.
local function standard_program(prelude: string, stdlib: string, external?: {string}):
    Declarations.Program, {string: Scopes.Global}, Programs.Run, Programs.Run
  local program = Declarations.new()
  for _, name in ipairs(external or { "cosmic.sys" }) do
    program.external[name] = true
  end
  local globals: {string: Scopes.Global} = {}
  local function add(file: string, text: string)
    for name, g in pairs(Scopes.declared(Parser.parse(Lexer.lex(text, file), file, "decl").chunk)) do
      globals[name] = g
    end
  end
  add("lang/prelude.d.tl", prelude)
  add("lang/stdlib.d.tl", stdlib)
  local first = lower(program, "checker.prelude", prelude, "decl", {})
  local second = lower(program, "checker.stdlib", stdlib, "decl", globals)
  return program, globals, first, second
end

function Programs.session(prelude: string, stdlib: string, external?: {string}): function(source: string, module?: string, modules?: {string: string}): Programs.Run
  local program, globals, _, _ = standard_program(prelude, stdlib, external)
  return function(source: string, module?: string, modules?: {string: string}): Programs.Run
    local sources = modules or {}
    for _, name in ipairs(sorted_names(sources)) do
      local _ = lower(program, name, assert(sources[name]), "tl", globals)
    end
    return lower(program, module or "t", source, "tl", globals)
  end
end

function Programs.declared(prelude: string, stdlib: string): {string}
  local _, _, first, second = standard_program(prelude, stdlib)
  local out: mut {string} = {}
  for _, code in ipairs(first.before) do
    out[#out + 1] = "lang/prelude.d.tl: " .. code
  end
  for _, code in ipairs(second.before) do
    out[#out + 1] = "lang/stdlib.d.tl: " .. code
  end
  return out
end

function Programs.dump(prelude: string, stdlib: string): string
  local program, _, _, _ = standard_program(prelude, stdlib)
  local text = ""
  for _, name in ipairs(sorted_names(program.globals)) do
    local decl = assert(program.globals[name]).decl
    if decl == nil then
      text = text .. "global " .. name .. " none\n"
    else
      text = text .. "global " .. name .. " " .. decl.kind .. "\n"
      local body = decl.body
      if body ~= nil then
        for _, f in ipairs(body.fields) do
          text = text .. "  field " .. f.name .. ": " .. Types.display(f.type) .. "\n"
        end
        for _, m in ipairs(body.methods) do
          text = text .. "  method " .. m.name .. ": " .. Types.display(m.type) .. "\n"
        end
      end
    end
  end
  for _, name in ipairs(sorted_names(program.values)) do
    for _, t in ipairs(assert(program.values[name])) do
      text = text .. "value " .. name .. ": " .. Types.display(t) .. "\n"
    end
  end
  return text
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

--- The typed `coroutine` library the declarations of [`lang/stdlib.d.tl`] describe, over Lua's: a body is called
--- with the handle that yields and the value the first `resume` sent, `resume` answers `true` and what was yielded or
--- returned or `false` and the error, and a handle yields only for the coroutine it was made for.
--
-- TODO: drop this library, and run the Lua against the runtime's, once the runtime provides the typed `coroutine`
-- (the TODO above `coroutine` in [`lang/stdlib.d.tl`]).
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
      local ok, value = co.resume(...)
      if not ok then
        error(value, 0)
      end
      return value
    end
  end
  return library
end

--- The values joined by "," in `text`.
local function words_of(text: string): {string}
  local out: mut {string} = {}
  for word in text:gmatch("[^,]+") do
    out[#out + 1] = word
  end
  return out
end

--- The `__fact` that [`Programs.execute`] runs a program with unless it is given another: it raises `fact violated: ...`
--- for a read whose conclusion is false of the value.
local function own_fact(v: any, kinds: string, name: string, strings?: {string}, tables?: {any}, tag?: string,
                        tags?: {string} | string, _at?: string): any
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
      local listed = if tags is string then words_of(tags) else tags end
      if not among(listed, field) then
        fails("a table whose " .. tag .. " is " .. tostring(field) .. ", the checker proved one of " .. table.concat(listed, ","))
      end
    end
  end
  return v
end

--- The Lua of a checked program: the code generator's text, with the classes its literals make and the enums it tests.
local function generated(run: Programs.Run, wraps: {integer: string}, kind_only: boolean?): string
  local classes: mut {integer: string} = {}
  for id, decl in pairs(run.result.literals) do
    classes[id] = decl.name
  end
  return Codegen.generate(run.chunk, run.scoped, nil, classes, if kind_only then {} else Check.enums(run.lowered) end, wraps).text
end

function Programs.lua(run: Programs.Run): string
  return generated(run, {}, nil)
end

function Programs.execute(source: string, facts: boolean, modules?: {string: string}, kind_only?: boolean,
                          hook?: Programs.FactHook, anyway?: boolean): Programs.Execution
  local run = Programs.run(source, modules)
  local done: Programs.Execution = { run = run, ran = false, lua = "", printed = {}, fault = nil }
  if not taken(run) and not (anyway == true and #run.before == 0) then
    return done
  end
  local wraps: {integer: string} = {}
  if facts then
    wraps = FactWraps.of(run.result.narrowed, source, "t", run.chunk)
  end
  done.lua = generated(run, wraps, kind_only)
  local loader: function(name: string): any
  local env: {string: any} = {
    assert = assert, ipairs = ipairs, pairs = pairs, math = math, tostring = tostring, tonumber = tonumber, type = type, error = error, pcall = pcall, xpcall = xpcall,
    string = string, table = table, select = select, setmetatable = setmetatable, getmetatable = getmetatable,
    coroutine = typed_coroutines(),
    require = function(name: string): any
      return loader(name)
    end,
  }
  env.print = function(...: any)
    local parts: mut {string} = {}
    for i = 1, select("#", ...) do
      parts[i] = tostring((select(i, ...)))
    end
    done.printed[#done.printed + 1] = table.concat(parts, "\t")
  end
  env.__fact = hook or own_fact
  local loaded: {string: any} = {}
  loader = function(name: string): any
    local held = loaded[name]
    if held ~= nil then
      return held
    end
    local module = (run.required or {})[name]
    if module == nil or not taken(module) then
      error("module '" .. name .. "' not found, or not taken by the checker", 2)
    end
    local module_chunk, module_why = load(generated(module, {}, kind_only), "=" .. name, "t", env)
    if module_chunk == nil then
      error("the Lua of " .. name .. " does not load: " .. tostring(module_why), 2)
    end
    local value = module_chunk()
    loaded[name] = value
    return value
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
  local out: mut {string} = {}
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
