--- Helpers for the tests of [`lang.check`]: a source checked the way a project's modules are (lexed, parsed, scoped,
--- lowered, checked) against a small standard library written in the grammar.
local Ast = require("lang.ast")
local Check = require("lang.check")
local Codes = require("lang.check_codes")
local Declarations = require("lang.declarations")
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
  end

  --- The declarations the standard library is: the globals a program may use, as a declaration file.
  library: string

  --- Checks `source` as the module `t`, after lowering the library and the `modules` it requires (by name, in the
  --- order of their names).
  run: function(source: string, modules?: {string: string}): Run

  --- The codes of the errors of `run`, space separated, in order.
  codes: function(run: Run): string

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
  global record coroutine
    create: function(function()): any
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
  local result: Check.Checked = { errors = {}, vars = {} }
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
