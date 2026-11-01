--- The `global` declarations a source holds, read off its syntax tree where it is parsed ([`build.derivation`]), so a
--- build refuses them ([`build.plans`]'s `refuse_globals`) from rows kept by the source's hash and not by reading
--- every source again.
---
--- Only a declaration file (`.d.tl`) may declare a global: the parser refuses a `global` in a program, and refuses a
--- `function f()` that assigns no local, so a source that parses declares none unless it is a declaration file. The
--- fork read both as declarations and the build refused them here.
local Ast = require("lang.ast")
local Lexer = require("lang.lexer")
local Node = require("build.syntax_node")

local record Globals
  --- Where a declaration starts.
  record Place
    line: integer
    column: integer
  end

  --- Where each global `chunk` declares starts, in source order: its `global` keyword.
  found: function(chunk: Ast.Chunk): {Place}
end

--- Whether the tokens hold the word `global`. A source without one has none to find, and its tree is not walked.
local function has_candidate(chunk: Ast.Chunk): boolean
  local tokens = chunk.tokens
  for i, text in ipairs(tokens.text) do
    if text == "global" and tokens.kind[i] == "keyword" then
      return true
    end
  end
  return false
end

function Globals.found(chunk: Ast.Chunk): {Globals.Place}
  local found: mut {Globals.Place} = {}
  if not has_candidate(chunk) then
    return found
  end
  Node.walk(chunk, function(node: Ast.Node)
    local declared = Node.declared(node)
    local scope: Ast.Scope? = nil
    if node.kind == "Local" then
      scope = node.scope
    elseif declared ~= nil then
      scope = declared.scope
    end
    if scope == "global" then
      local first = Node.base(node).first
      table.insert(found, { line = Lexer.y(chunk.tokens, first), column = Lexer.x(chunk.tokens, first) })
    end
  end)
  table.sort(found, function(a: Globals.Place, b: Globals.Place): boolean
    return a.line < b.line or (a.line == b.line and a.column < b.column)
  end)
  return found
end

return Globals
