--- The lexer half of cosmic.literal: splits literal source into a token
--- stream, and decodes a string token to the value it denotes
--- (`string_value` — the token grammar and its meaning live together).
--- A flat `_literal_lex` sibling for the same reason
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
        if d == "\\" and src:sub(j + 1, j + 1) == "z" then
          -- `\z` skips the whitespace that follows it, newlines
          -- included — that is what the escape is FOR, and `load`
          -- accepts it — so the scan walks past them here; a raw
          -- newline anywhere else still ends the string above.
          j = j + 2
          while j <= n and src:sub(j, j):match("^%s") do
            j = j + 1
          end
        else
          j = j + (d == "\\" and 2 or 1)
        end
      end
      if j > n then
        return nil, where .. ":" .. tostring(y) .. ": unterminated string"
      end
      toks[#toks + 1] = {tk = src:sub(i, j), kind = "string", y = y}
      -- A short string spans lines through `\z` (and `\<newline>`), and
      -- later refusals report line numbers: count what the token
      -- crossed, like the long-bracket branches above.
      local _, breaks = src:sub(i, j):gsub("\n", "")
      y = y + breaks
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

--- The largest code point `\u{...}` may name, which is what `utf8.char`
--- accepts and what the Lua manual specifies for the escape: 2^31 - 1.
local MAX_CODEPOINT < const > = 0x7FFFFFFF

--- Lua's single-character escapes, by the character that follows `\`.
local ESCAPES: {string: string} = {
  a = "\a", b = "\b", f = "\f", n = "\n", r = "\r", t = "\t",
  v = "\v", ["\\"] = "\\", ['"'] = '"', ["'"] = "'", ["\n"] = "\n",
}

--- Decode one `\` escape starting at `i` (the backslash).
--- @param s string The string token's body
--- @param i integer Index of the backslash
--- @return string|nil The decoded text, or nil when the escape is bad
--- @return integer The index just past the escape
local function escape_at(s: string, i: integer): string | nil, integer
  local c = s:sub(i + 1, i + 1)
  local simple = ESCAPES[c]
  if simple then
    return simple, i + 2
  end
  if c == "x" then
    local hex = s:match("^%x%x", i + 2)
    if not hex then
      return nil, i
    end
    return string.char(tonumber(hex, 16)), i + 4
  end
  if c == "z" then
    -- `\z` skips the whitespace that follows it, newlines included.
    local rest = s:find("[^%s]", i + 2) or #s + 1
    return "", rest
  end
  if c == "u" then
    -- A position capture is ABSOLUTE: `after` already indexes just past
    -- the closing `}`, whatever `init` was. Adding to it resumed the
    -- decode two characters late, so every `\u{…}` silently swallowed
    -- the two characters behind it -- invisible only when the escape
    -- ended the string, which was the one shape the test covered.
    local hex, after = s:match("^{(%x+)}()", i + 2)
    if not hex then
      return nil, i
    end
    -- BOUNDED, because `%x+` has no length limit and this file is
    -- attacker-shaped: it is what reads a pin. `\u{FFFFFFFFFF}` parses
    -- fine, exceeds what `utf8.char` accepts, and threw out of a module
    -- whose whole contract is that it returns errors -- so a malformed
    -- pin crashed `--make fetch` with a traceback instead of naming the
    -- file. Above 2^31 `tonumber` also stops being integral, which the
    -- cast below would have quietly asserted otherwise.
    local cp = tonumber(hex, 16)
    if cp == nil or cp ~= math.floor(cp) or cp < 0 or cp > MAX_CODEPOINT then
      return nil, i
    end
    return utf8.char(cp), after
  end
  local digits = s:match("^%d%d?%d?", i + 1)
  if digits then
    local n = tonumber(digits, 10)
    if n > 255 then
      return nil, i
    end
    return string.char(n), i + 1 + #digits
  end
  return nil, i
end

--- The value a string token denotes.
---
--- Delimiters vary and escapes must be decoded: a short string may
--- carry `\n`, `\x41` or `\u{...}`, while a long bracket carries none
--- and its delimiter is as many `=` as were written. Both matter
--- because the module's contract is "equal to what executing the file
--- would return", and a reader that quietly returns different data is
--- the failure this exists to make impossible.
--- @param tk string The raw string token, delimiters included
--- @return string|nil The value, or nil when the token is malformed
local function string_value(tk: string): string | nil
  local level = tk:match("^%[(=*)%[")
  if level then
    -- A long bracket takes no escapes. Lua's lexer folds each line
    -- break -- \n, \r, \r\n or \n\r -- to one \n while reading the
    -- body (a same-char pair is two breaks, a mixed pair is one) and
    -- drops one such break right after the opening delimiter, so this
    -- copy does the same or a CRLF checkout reads differently than it
    -- executes.
    local open = #level + 2
    local body = tk:sub(open + 1, -(open + 1))
    if body:find("\r", 1, true) then
      -- The scan is sequential, like Lua's inclinenumber: a break is
      -- one \r or \n plus the OPPOSITE character when it follows, so
      -- "\r\r\n" is two breaks (\r, then \r\n), never three.
      local parts: {string} = {}
      local i = 1
      while i <= #body do
        local brk = body:find("[\r\n]", i)
        if not brk then
          parts[#parts + 1] = body:sub(i)
          break
        end
        parts[#parts + 1] = body:sub(i, brk - 1)
        parts[#parts + 1] = "\n"
        local c = body:sub(brk, brk)
        local nxt = body:sub(brk + 1, brk + 1)
        if (nxt == "\r" or nxt == "\n") and nxt ~= c then
          brk = brk + 1
        end
        i = brk + 1
      end
      body = table.concat(parts)
    end
    if body:sub(1, 1) == "\n" then
      body = body:sub(2)
    end
    return body
  end
  local quote = tk:sub(1, 1)
  if quote ~= '"' and quote ~= "'" then
    return nil
  end
  local body = tk:sub(2, -2)
  if not body:find("\\", 1, true) then
    return body
  end
  local parts: {string} = {}
  local i = 1
  while i <= #body do
    local slash = body:find("\\", i, true)
    if not slash then
      parts[#parts + 1] = body:sub(i)
      break
    end
    parts[#parts + 1] = body:sub(i, slash - 1)
    local decoded, nexti = escape_at(body, slash)
    if not decoded then
      return nil
    end
    parts[#parts + 1] = decoded
    i = nexti
  end
  return table.concat(parts)
end

local record LiteralLexModule
  type Token = Token
  lex: function(src: string, where: string): {Token} | nil, string
  string_value: function(tk: string): string | nil
end

local M: LiteralLexModule = {
  lex = lex,
  string_value = string_value,
}

return M
