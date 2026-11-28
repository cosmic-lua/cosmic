--- The code of a source without its comments or its layout: its tokens ([`lang.lexer`]), and where each begins a line,
--- which the parser reads too. Two sources with the same code text lex to the same tokens on the same breaks of line, so
--- they parse, compile and run alike, but for the lines a message or a traceback names. The identities of the code that
--- compiles ([`build.identity`], [`build.code_identity`]) hash it rather than the source, so that an edit to a comment of
--- the checker or of the build, a doc link fixed, moves none of them.

local Lexer = require("lang.lexer")

local record code_text
end

--- The code text of each source this process lexed, by the source: a build hashes the same modules' code text for
--- several identities ([`build.identity`], [`build.code_identity`], [`build.importer`]'s analyzer), and lexes each once.
--- It is let go once its sources and code texts come to `MEMO_BYTES`, so a long-lived process keeps no more than that.
local memo: mut {string:string} = {}
local memo_bytes = 0
local MEMO_BYTES <const> = 64 * 1024 * 1024

--- What [`code_text.of`] answers, lexed again each time.
local function lexed(source: string, name: string): string
  local result = Lexer.lex(source, name)
  if #result.errors > 0 then return "source\n" .. source end
  local tokens = result.tokens
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

--- The code text of `source`, named `name` in the lexer's errors: `code` and each token's bytes, each after a line
--- break where it begins a line below the end of the token before it, and after a space where it does not. A source
--- the lexer finds an error in is `source` and the source whole, so that what the lexer cannot read is never taken for
--- code it read.
function code_text.of(source: string, name: string): string
  local kept = memo[source]
  if kept ~= nil then return kept end
  local made = lexed(source, name)
  -- The memo holds each source and its code text both.
  local size = #source + #made
  if size > MEMO_BYTES then return made end
  if memo_bytes + size > MEMO_BYTES then
    memo, memo_bytes = {}, 0
  end
  memo[source], memo_bytes = made, memo_bytes + size
  return made
end

return code_text
