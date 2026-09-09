--- Lexical preservation checks for formatted source.
---
--- Layout may move tokens and normalize comment indentation, but it may
--- not change the ordered token stream or comment text. Keeping this check
--- separate from parsing matters: two different token streams can both be
--- valid programs.

local tl = require("tl")

local record Lexeme
  kind: string
  text: string
end

local function is_long_comment(text: string): boolean
  return text:sub(1, 4) == "--[["
  or (text:sub(1, 3) == "--[" and text:sub(4, 4) == "=")
end

--- Remove only whitespace the formatter deliberately normalizes.
--- Short comments lose trailing whitespace. Continuation lines in long
--- comments are reindented with their containing code, so their leading
--- indentation is not part of the preservation key.
local function comment_key(text: string): string
  if not is_long_comment(text) then
    return text:match("^(.-)%s*$")
  end

  local lines: {string} = {}
  local first = true
  for line in (text .. "\n"):gmatch("(.-)\n") do
    if first then
      lines[#lines + 1] = line
      first = false
    else
      lines[#lines + 1] = line:match("^%s*(.*)$")
    end
  end
  return table.concat(lines, "\n")
end

local function lexemes(tokens: {tl.Token}): {Lexeme}
  local out: {Lexeme} = {}
  for _, token in ipairs(tokens) do
    if token.comments then
      for _, comment in ipairs(token.comments) do
        out[#out + 1] = {kind = "comment", text = comment_key(comment.text)}
      end
    end
    if token.kind ~= "$EOF$" then
      out[#out + 1] = {kind = token.kind, text = token.tk}
    end
  end
  return out
end

--- Compare the meaningful lexical stream before and after formatting.
--- Exact token spellings protect literal values as well as operators;
--- normalized comment keys protect comment contents and ordering.
--- @return boolean Whether the streams are equivalent
--- @return string Explanation when they differ
local function equivalent(before: {tl.Token}, after: {tl.Token}): boolean, string
  local left = lexemes(before)
  local right = lexemes(after)
  if #left ~= #right then
    return false, string.format("item count changed from %d to %d", #left, #right)
  end
  for i, a in ipairs(left) do
    local b = right[i]
    if a.kind ~= b.kind or a.text ~= b.text then
      return false, string.format(
        "item %d changed from %s %q to %s %q",
        i, a.kind, a.text, b.kind, b.text
      )
    end
  end
  return true, ""
end

local record PreserveModule
  equivalent: function(before: {tl.Token}, after: {tl.Token}): boolean, string
end

local M: PreserveModule = {
  equivalent = equivalent,
}

return M
