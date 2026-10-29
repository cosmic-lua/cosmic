--- The part of a source's text that the checks of the files that require it read, as a digest: its tokens, where each
--- begins in its line, and whether it begins one, and the lexical errors; and not its comments, nor the numbers of its
--- lines, nor how many blank lines separate its tokens.
---
--- A file's answer from the checks of the tree ([`build.tree_checks`]) is kept under the text of the file itself and
--- of every module it requires. What a check reads of a module it requires is that module's types, which come from its
--- tokens: the parser asks of two tokens only whether they are on one line and, in a recovery from a
--- syntax error, how far each is indented, and no check reads a comment or a line number of another file (an error is
--- always the file's own, at its own place). So an edit to a comment of a module, or to the blank lines between its
--- statements, changes no answer about a file that requires it, and its digest is the same.
---
--- A token is held by its kind, its bytes (a string's quotes and a long string's brackets with it), its column and
--- whether it is the first on its line, so that moving a token on its line, joining two lines or breaking one changes the
--- digest; a lexical error by its code, message and fix, so that a long comment, which the grammar refuses and the check
--- of the lexer counts, is held for what it is.
local Hash = require("cosmic.hash")
local Lexer = require("lang.lexer")

local record ShapeKey
  --- The digest of the source `text` of the file `name`.
  digest: function(text: string, name: string): string
end

function ShapeKey.digest(text: string, name: string): string
  local lexed = Lexer.lex(text, name)
  local tokens = lexed.tokens
  local parts: mut {string} = { "shape 1" }
  -- The last line the previous token is on: a token on a later one begins a line.
  local ended = 0
  for i = 1, Lexer.count(tokens) do
    local y = Lexer.y(tokens, i)
    local bytes = Lexer.text(tokens, i)
    parts[#parts + 1] = Lexer.kind(tokens, i) .. (if y > ended then " n " else " s " end) .. tostring(Lexer.x(tokens, i)) .. " " ..
      tostring(#bytes) .. ":" .. bytes
    ended = Lexer.yend(tokens, i)
  end
  for _, e in ipairs(lexed.errors) do
    parts[#parts + 1] = "error " .. e.code .. "\0" .. e.msg .. "\0" .. e.fix
  end
  return Hash.hex_sha256(table.concat(parts, "\n"))
end

return ShapeKey
