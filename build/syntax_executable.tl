--- Which lines of a module's own source could ever run: the denominator of a coverage percentage. It reads the
--- syntax tree, which tells a statement from a blank line, a comment or a bare `end`, where a scan of the text cannot.
--- A parse writes its answer ([`build.syntax_derivation`]), and coverage reads it ([`build.coverage.syntax_lines`]).
local Ast = require("lang.ast")
local Lexer = require("lang.lexer")
local Node = require("build.syntax_node")

local record Executable
  --- The set of executable lines of `chunk`: the line each statement of a block starts on, at any depth (a block
  --- inside a function, an `if` or a loop counts, not only the chunk's own), except a type declaration, which emits
  --- Lua only when its name is used as a value, and the tree does not say that.
  --
  -- TODO: count a record, enum or alias statement whose name is used as a value, once this reads the checker's type
  -- report and not the tree alone: the percentage is deflated until then, never inflated.
  of_chunk: function(chunk: Ast.Chunk): {integer: boolean}

  --- [`Executable.of_chunk`] of `source`, a file named `name`; nil and why where the source does not parse.
  of_source: function(source: string, name: string): {integer: boolean}?, string

  --- `lines` as the `executable` table holds them: ascending, joined by single spaces.
  joined: function(lines: {integer: boolean}): string
end

local function declares_type(stat: Ast.Stat): boolean
  return Node.declared(stat) ~= nil
end

function Executable.of_chunk(chunk: Ast.Chunk): {integer: boolean}
  local out: mut {integer: boolean} = {}
  Node.walk(chunk, function(node: Ast.Node)
    if (node.kind == "Block") then
      for _, stat in ipairs(node.stats) do
        if not declares_type(stat) then
          local base = Node.base(stat)
          local y = assert(chunk.tokens.y[base.first], "every token has a line")
          -- Lua attributes a closure to the line its body ends on, and a `local function` is nothing but that closure:
          -- its own first line never runs. (`function M.f` is pinned to its first line by the assignment Lua fixes
          -- there.)
          if (stat.kind == "LocalFunction") then
            y = Lexer.yend(chunk.tokens, base.last)
          end
          out[y] = true
        end
      end
    end
  end)
  return out
end

function Executable.of_source(source: string, name: string): {integer: boolean}?, string
  local chunk, why = Node.parse(source, name)
  if chunk == nil then
    return nil, why
  end
  return Executable.of_chunk(chunk), ""
end

function Executable.joined(lines: {integer: boolean}): string
  local numbers: mut {integer} = {}
  for line in pairs(lines) do
    numbers[#numbers + 1] = line
  end
  table.sort(numbers)
  local texts: mut {string} = {}
  for i, line in ipairs(numbers) do
    texts[i] = tostring(line)
  end
  return table.concat(texts, " ")
end

return Executable
