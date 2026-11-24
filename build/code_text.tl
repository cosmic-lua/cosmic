--- The code of a source without its comments or its layout: its tokens ([`lang.lexer`]), and where each begins a line,
--- which the parser reads too. Two sources with the same code text lex to the same tokens on the same breaks of line, so
--- they parse, compile and run alike, but for the lines a message or a traceback names. The identities of the code that
--- compiles ([`build.identity`], [`build.code_identity`]) hash it rather than the source, so that an edit to a comment of
--- the checker or of the build, a doc link fixed, moves none of them.

local Lexer = require("lang.lexer")

local record code_text
end

--- The code text of `source`, named `name` in the lexer's errors: `code` and each token's bytes, each after a line
--- break where it begins a line below the end of the token before it, and after a space where it does not. A source
--- the lexer finds an error in is `source` and the source whole, so that what the lexer cannot read is never taken for
--- code it read.
function code_text.of(source: string, name: string): string
  local lexed = Lexer.lex(source, name)
  if #lexed.errors > 0 then return "source\n" .. source end
  local tokens = lexed.tokens
  local out: mut {string} = { "code" }
  local last = 0
  for i = 1, Lexer.count(tokens) do
    -- The end of the source is a token with no bytes, on whatever line the last break leaves it.
    local text = Lexer.text(tokens, i)
    if text ~= "" then
      out[#out + 1] = if Lexer.y(tokens, i) > last then "\n" else " " end
      out[#out + 1] = text
      last = Lexer.yend(tokens, i)
    end
  end
  return table.concat(out)
end

return code_text
