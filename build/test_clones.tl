--- The top-level helpers of a file as the check for a copied test helper ([`build.tree_checks`]'s `test_clones`)
--- compares them: each `local function` that is no test, cut out of the text, and its tokens.
---
--- A helper is cut out of the text where `bin/cosmic fix` lays a file out ([`build.fix.format`]): it begins on a line
--- of `local function` at the left margin and ends on the first line that is `end` alone. Lexing every one of the
--- tree's thousands of helpers costs more than the check may, so a cut carries a `key`, the text with its comments
--- and the runs of white space taken out, and only cuts that share a key are lexed ([`lang.lexer`]) for the answer.
--- A comment and the layout of a line are not in the tokens; a name, a literal and the order of the tokens are, so two
--- helpers are the same where they are written alike token for token, and a copy whose names were changed is not found.
local Lexer = require("lang.lexer")

local record TestClones
  --- A helper cut out of a file.
  record Cut
    name: string
    line: integer
    --- Its text from `(` to `end`.
    text: string
    --- That text without comments, and with each run of white space as one space: equal for two copies.
    key: string
  end

  --- Each top-level `local function` of `text` that is no test and is at least `least` bytes long, in source order.
  cuts: function(text: string, least: integer): {Cut}

  --- The text of each token of `text`, a cut's; nil where the lexer refuses it (an `end` line in a long string
  --- ends the cut early).
  tokens: function(text: string, file: string): {string}?
end

function TestClones.cuts(text: string, least: integer): {TestClones.Cut}
  local out: mut {TestClones.Cut} = {}
  -- The line break in front lets the first line begin a helper.
  text = "\n" .. text
  local from = 1
  local line = 0
  local counted = 1
  while true do
    local at, after, found = text:find("\nlocal function ([%w_]+)", from)
    if at == nil or after == nil or found == nil then break end
    local name: string = found
    from = after + 1
    if name:match("^test_") == nil then
      local close = text:find("\nend\n", after, true) or text:find("\nend$", after)
      if close ~= nil and close + 4 - after >= least then
        local body = text:sub(after + 1, close + 4)
        -- The line is counted on from the helper before it.
        local _, breaks = text:sub(counted, at):gsub("\n", "")
        line = line + breaks
        counted = at + 1
        local key = body:gsub("%-%-[^\n]*", ""):gsub("%s+", " ")
        out[#out + 1] = { name = name, line = line, text = body, key = key }
      end
    end
  end
  return out
end

function TestClones.tokens(text: string, file: string): {string}?
  local lexed = Lexer.lex(text, file)
  if #lexed.errors > 0 then return nil end
  local words: mut {string} = {}
  for _, word in ipairs(lexed.tokens.text) do words[#words + 1] = word end
  words[#words] = nil
  return words
end

return TestClones
