--- The part of a source's text that the checks of the files that require it read, as a digest: its tokens, where each
--- begins in its line, and whether it begins one, and the lexical errors; and not its comments, nor the numbers of its
--- lines, nor how many blank lines separate its tokens, nor the tokens of the body of any of its functions; but the
--- modules it requires, in order, a body's too.
---
--- A file's result from the checks of the tree ([`build.tree_checks`]) is kept under the text of the file itself and
--- of every module it requires. What a check reads of a module it requires is that module's types, which come from its
--- tokens: the parser asks of two tokens only whether they are on one line and, in a recovery from a
--- syntax error, how far each is indented, and no check reads a comment or a line number of another file (an error is
--- always the file's own, at its own place). So an edit to a comment of a module, or to the blank lines between its
--- statements, changes no result for a file that requires it, and its digest is the same. Nor does an edit inside the
--- body of a function: what another module reads of a module is what lowering it declared, which a body never adds to
--- ([`in_bodies`]). So an edit to a body low in the tree checks that file again, and not every file above it.
---
--- A token is held by its kind, its bytes (a string's quotes and a long string's brackets with it), its column and
--- whether it is the first on its line, so that moving a token on its line, joining two lines or breaking one changes the
--- digest; a lexical error by its code, message and fix, so that a long comment, which the grammar refuses and the check
--- of the lexer counts, is held for what it is.
local Ast = require("lang.ast")
local Hash = require("cosmic.hash")
local Lexer = require("lang.lexer")
local Parser = require("lang.parser")

local record ShapeKey
  --- The digest of the source `text` of the file `name`.
  digest: function(text: string, name: string): string
end

--- The tokens of `chunk` inside a function's body, each by its index, or nil where the source did not parse: what the files
--- that require a module read of it is what lowering it declares ([`lang.declarations`]), its declarations and the
--- annotations outside the bodies of its functions, and never a body; a driver keeps a module's declarations and drops
--- its syntax ([`build.driver`]), so no check of another module reaches a statement in one. A body's own types (`local
--- record` inside a function) are declared under a name no other module can write.
local function in_bodies(chunk: Ast.Chunk): {integer: boolean}
  local inside: mut {integer: boolean} = {}
  local pending: mut {Ast.Node} = { chunk }
  while #pending > 0 do
    local node = assert(pending[#pending])
    pending[#pending] = nil
    if (node.kind == "Fn") then
      local body = node.body
      for i = body.first, body.last do inside[i] = true end
      -- Its parameters and returns are read; its body is not, nor anything nested in it.
      for _, p in ipairs(node.params) do pending[#pending + 1] = p end
      local rets = node.rets
      if rets ~= nil then pending[#pending + 1] = rets end
    else
      Ast.children(node, function(child: Ast.Node) pending[#pending + 1] = child end)
    end
  end
  return inside
end

function ShapeKey.digest(text: string, name: string): string
  local lexed = Lexer.lex(text, name)
  local tokens = lexed.tokens
  local parsed = Parser.parse(lexed, name, "tl")
  -- A source that does not parse is held by every token: which of them a body holds is not known.
  local skipped: {integer: boolean} = if #parsed.errors == 0 then in_bodies(parsed.chunk) else {} end
  local parts: mut {string} = { "shape 2" }
  -- The last line the previous token is on: a token on a later one begins a line.
  local ended = 0
  for i = 1, Lexer.count(tokens) do
    local y = Lexer.y(tokens, i)
    if skipped[i] ~= true then
      local bytes = Lexer.text(tokens, i)
      parts[#parts + 1] = Lexer.kind(tokens, i) .. (if y > ended then " n " else " s " end) .. tostring(Lexer.x(tokens, i)) ..
        " " .. tostring(#bytes) .. ":" .. bytes
    end
    ended = Lexer.yend(tokens, i)
  end
  -- Every module it requires, in order, a body's too: the driver lowers what a module requires in that order, which
  -- decides the order a cycle of requires is lowered in.
  for _, r in ipairs(parsed.chunk.requires) do
    parts[#parts + 1] = "requires " .. r.module
  end
  for _, e in ipairs(lexed.errors) do
    parts[#parts + 1] = "error " .. e.code .. "\0" .. e.msg .. "\0" .. e.fix
  end
  return Hash.hex_sha256(table.concat(parts, "\n"))
end

return ShapeKey
