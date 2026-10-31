--- Helpers for the tests of [`lang.declarations`]: a source lowered the way a project's modules are
--- (lexed, parsed, scoped, lowered), and the sources of the declarations that [`lang.types_programs`]
--- builds by hand, written in the grammar.
local Ast = require("lang.ast")
local Declarations = require("lang.declarations")
local Lexer = require("lang.lexer")
local Parser = require("lang.parser")
local Scopes = require("lang.scopes")

local record Programs
  --- What lowering one source gave, with the errors of the parser and the scope builder that came first.
  record Result
    lowered: Declarations.Lowered
    parse_errors: {Parser.Error}
    scope_errors: {Scopes.Error}
    chunk: Ast.Chunk
    scoped: Scopes.Scoped
  end

  --- Lowers `source` as the module `module` of `program`. A source whose name ends in `.d.tl` is a declaration file.
  lower: function(program: Declarations.Program, module: string, source: string, dialect?: Ast.Dialect): Result

  --- Declares `source` as the module `module` of `program` without lowering it.
  declare: function(program: Declarations.Program, module: string, source: string, dialect?: Ast.Dialect)

  --- The codes of the errors of `lowered`, space separated, in order.
  codes: function(lowered: Declarations.Lowered): string

  --- The sources of the declarations of [`lang.types_programs`]'s fixture: the module "cosmic.stream" and
  --- the declaration file "m".
  stream_source: string
  fixture_source: string
end

function Programs.lower(program: Declarations.Program, module: string, source: string, dialect?: Ast.Dialect): Programs.Result
  local kind: Ast.Dialect = dialect or "tl"
  local name = module .. (if kind == "decl" then ".d.tl" else ".tl" end)
  local parsed = Parser.parse(Lexer.lex(source, name), name, kind)
  local scoped = Scopes.build(parsed.chunk, name, program:scope_globals())
  local lowered = program:lower({
    module = module, filename = name, chunk = parsed.chunk, scoped = scoped, dialect = kind,
  })
  return { lowered = lowered, parse_errors = parsed.errors, scope_errors = scoped.errors, chunk = parsed.chunk, scoped = scoped }
end

function Programs.declare(program: Declarations.Program, module: string, source: string, dialect?: Ast.Dialect)
  local kind: Ast.Dialect = dialect or "tl"
  local name = module .. (if kind == "decl" then ".d.tl" else ".tl" end)
  local parsed = Parser.parse(Lexer.lex(source, name), name, kind)
  local scoped = Scopes.build(parsed.chunk, name, program:scope_globals())
  program:declare({ module = module, filename = name, chunk = parsed.chunk, scoped = scoped, dialect = kind })
end

function Programs.codes(lowered: Declarations.Lowered): string
  local out: mut {string} = {}
  for _, e in ipairs(lowered.errors) do
    out[#out + 1] = e.code
  end
  return table.concat(out, " ")
end

Programs.stream_source = [[
local record Stream
  interface Reader
    read: function(Reader, max_bytes?: integer): string?
  end
end
return Stream
]]

Programs.fixture_source = [[
local type Stream = require("cosmic.stream")
local record Node is {Node}
  name: string
  next?: Node
end
local record Tree
  kids: Forest
end
local record Forest is {Tree}
end
local record List<T>
  items: {T}
  mut size: integer
end
local record Pair<A, B>
  first: A
  second: B
end
local record File is Stream.Reader
  path: string
  mut open: boolean
  read: function(File, max_bytes?: integer): string?
  close: function(File): boolean
end
local enum Color "red" "green" "blue" end
local enum Odd "\255" "ok" "a\"b" end
local record Handle
  userdata
  release: function(Handle)
end
local record T end
local record T_1 end
]]

return Programs
