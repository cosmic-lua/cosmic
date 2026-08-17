--- The lexer half of cosmic.literal: splits literal source into a token
--- stream. A flat `_literal_lex` sibling for the same reason
--- `_literal_format` is one — `literal.tl` sits at the file-length cap.
--- The public surface is cosmic.literal's; this module has no callers
--- outside it.
---
--- This module lexes for itself rather than borrowing `tl.lex`: a
--- stripped artifact keeps `cosmic/**` and drops `tl.lua`, so a shared
--- lexer would make `require("cosmic.literal")` throw in exactly the
--- artifacts whose authors want a config file that cannot do anything.
--- The grammar needs identifiers, strings, numbers and punctuation;
--- that is the lexer below, with no dependency beyond what `cosmic/**`
--- already provides — and here, none at all.

--- One lexical token: its raw text, what it is, and the line it began on.
local record Token
  tk: string
  kind: string
  y: integer
end

--- Lua's reserved words. They lex as `keyword`, never `identifier`, so
--- `return { end = 1 }` is refused as a grammar violation rather than
--- read as a key.
local KEYWORDS: {string: boolean} = {
  ["and"] = true, ["break"] = true, ["do"] = true, ["else"] = true,
  ["elseif"] = true, ["end"] = true, ["false"] = true, ["for"] = true,
  ["function"] = true, ["goto"] = true, ["if"] = true, ["in"] = true,
  ["local"] = true, ["nil"] = true, ["not"] = true, ["or"] = true,
  ["repeat"] = true, ["return"] = true, ["then"] = true, ["true"] = true,
  ["until"] = true, ["while"] = true,
}

--- Index just past the long bracket opening at `i`, or nil if it never
--- closes. The caller has already established that one opens there.
--- @param s string The source
--- @param i integer Index of the opening `[`
--- @return integer|nil The index just past the closing bracket
local function long_bracket_end(s: string, i: integer): integer | nil
  local eq = s:match("^%[(=*)%[", i)
  if not eq then
    return nil
  end
  local close = "]" .. eq .. "]"
  local at = s:find(close, i + #eq + 2, true)
  if not at then
    return nil
  end
  return at + #close
end

--- The Lua numeral starting at `i`, or nil when none does.
--- @param s string The source
--- @param i integer Index of the first character
--- @return string|nil The numeral's text
local function numeral_at(s: string, i: integer): string | nil
  local hex = s:match("^0[xX]%x*%.?%x*", i)
  if hex and #hex > 2 then
    return hex .. (s:match("^[pP][%+%-]?%d+", i + #hex) or "")
  end
  local dec = s:match("^%d*%.?%d*", i)
  if not dec or dec == "" or dec == "." then
    return nil
  end
  return dec .. (s:match("^[eE][%+%-]?%d+", i + #dec) or "")
end

--- Split source into tokens, ending with an `$EOF$` sentinel.
---
--- Deliberately permissive about what a token IS: anything unrecognized
--- becomes a one-character token, and the parser refuses it by name with
--- its line. Only genuinely unfinishable input (an unterminated string,
--- long string, or long comment) fails here, because those have no next
--- token to complain about.
--- @param src string The file's contents
--- @param where string File name, for messages
--- @return {Token}|nil The tokens
--- @return string The error message when the source cannot be lexed
local function lex(src: string, where: string): {Token} | nil, string
  local toks: {Token} = {}
  local n = #src
  local i = 1
  local y = 1
  -- Lua skips a first-line `#!`; so did the borrowed lexer.
  if src:sub(1, 2) == "#!" then
    i = (src:find("\n", 1, true) or n + 1)
  end
  while i <= n do
    local c = src:sub(i, i)
    if c == "\n" then
      y = y + 1
      i = i + 1
    elseif c:match("%s") then
      i = i + 1
    elseif src:sub(i, i + 1) == "--" then
      if src:match("^%[=*%[", i + 2) then
        local e = long_bracket_end(src, i + 2)
        if not e then
          return nil, where .. ":" .. tostring(y) .. ": unterminated long comment"
        end
        local _, breaks = src:sub(i, e - 1):gsub("\n", "")
        y = y + breaks
        i = e
      else
        i = src:find("\n", i, true) or n + 1
      end
    elseif c == "[" and src:match("^%[=*%[", i) then
      local e = long_bracket_end(src, i)
      if not e then
        return nil, where .. ":" .. tostring(y) .. ": unterminated long string"
      end
      toks[#toks + 1] = {tk = src:sub(i, e - 1), kind = "string", y = y}
      local _, breaks = src:sub(i, e - 1):gsub("\n", "")
      y = y + breaks
      i = e
    elseif c == '"' or c == "'" then
      local j = i + 1
      while j <= n and src:sub(j, j) ~= c do
        local d = src:sub(j, j)
        if d == "\n" then
          return nil, where .. ":" .. tostring(y) .. ": unterminated string"
        end
        j = j + (d == "\\" and 2 or 1)
      end
      if j > n then
        return nil, where .. ":" .. tostring(y) .. ": unterminated string"
      end
      toks[#toks + 1] = {tk = src:sub(i, j), kind = "string", y = y}
      i = j + 1
    elseif c:match("%d") or (c == "." and src:sub(i + 1, i + 1):match("%d")) then
      local num = numeral_at(src, i)
      if not num then
        return nil, where .. ":" .. tostring(y) .. ": malformed number"
      end
      toks[#toks + 1] = {tk = num, kind = "number", y = y}
      i = i + #num
    elseif c:match("[%a_]") then
      local word = src:match("^[%a_][%w_]*", i)
      toks[#toks + 1] = {
        tk = word,
        kind = KEYWORDS[word] and "keyword" or "identifier",
        y = y,
      }
      i = i + #word
    else
      toks[#toks + 1] = {tk = c, kind = "op", y = y}
      i = i + 1
    end
  end
  toks[#toks + 1] = {tk = "$EOF$", kind = "eof", y = y}
  return toks
end

local record LiteralLexModule
  type Token = Token
  lex: function(src: string, where: string): {Token} | nil, string
end

local M: LiteralLexModule = {
  lex = lex,
}

return M
