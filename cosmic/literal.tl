--- Teal source read as **data**: one `return { … }` of literals, lexed
--- and matched, never loaded and never called.
---
--- This is the reader behind `*.pin.tl` (`cosmic --make fetch`), and it
--- is public because it has callers outside `cosmic/` — this repo's own
--- build tooling reads its dependency pins with it, and any project
--- that wants a config file which *cannot do anything* wants exactly
--- this. A file read this way can declare values and nothing else: no
--- concatenation, no variables, no function calls. Not because those
--- are hard to support, but because "this file cannot do anything" is
--- the property worth having.
---
--- Nested tables and `["key"] =` entries are admitted; everything else
--- is refused by name, with the line it was found on.
---
---     local literal = require("cosmic.literal")
---     local cfg = literal.of_file("config.tl")

local fs = require("cosmic.fs")
local tl = require("tl")

--- Token kinds the literal grammar admits, beyond punctuation.
local scalar: {string: boolean} = {
  string = true,
  number = true,
  integer = true,
}

--- How deep a literal may nest.
---
--- The parser is recursive descent, so nesting depth is stack depth: a
--- crafted `{a={a={a=…}}}` blew the Lua stack and THREW `stack
--- overflow`, in the one module whose entire promise is that reading a
--- file cannot do anything. A library that throws is a library that
--- takes the process down with it, and every caller here is
--- unprotected. 32 is far past any real pin — the deepest in this repo
--- is 2 — so the limit costs nothing a caller would notice and turns a
--- crash into the same polite refusal every other malformed pin gets.
local MAX_DEPTH < const > = 32

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
    return string.char(tonumber(hex, 16) as integer), i + 4 -- cast: two hex digits are integral
  end
  if c == "z" then
    -- `\z` skips the whitespace that follows it, newlines included.
    local rest = s:find("[^%s]", i + 2) or #s + 1
    return "", rest
  end
  if c == "u" then
    local hex, after = s:match("^{(%x+)}()", i + 2)
    if not hex then
      return nil, i
    end
    return utf8.char(tonumber(hex, 16) as integer), (after as integer) + 2 -- cast: hex digits are integral
  end
  local digits = s:match("^%d%d?%d?", i + 1)
  if digits then
    local n = tonumber(digits) as integer -- cast: decimal digits are integral
    if n > 255 then
      return nil, i
    end
    return string.char(n), i + 1 + #digits
  end
  return nil, i
end

--- The value a string token denotes.
---
--- `sub(2, -2)` was wrong twice over: it left `\n` as two characters
--- rather than a newline, and it stripped one character per side from a
--- long bracket, so `[==[x]==]` read as `==[x]==`. Both returned
--- silently wrong data from a module whose contract is "equal to what
--- executing the file would return" — the failure mode a reader like
--- this exists to make impossible.
--- @param tk string The raw string token, delimiters included
--- @return string|nil The value, or nil when the token is malformed
local function string_value(tk: string): string | nil
  local level = tk:match("^%[(=*)%[")
  if level then
    -- A long bracket takes no escapes, and Lua drops a newline
    -- immediately after the opening delimiter.
    local open = #level + 2
    local body = tk:sub(open + 1, -(open + 1))
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

--- Parse a literal table from a token stream, starting at `{`.
--- Returns the value and the index just past the closing `}`.
--- @param toks {tl.Token} The lexed tokens
--- @param i integer Index of the opening brace
--- @param where string File name, for messages
--- @param noun string What to call the file in errors
--- @param depth integer How many tables enclose this one
--- @return {string: any}|nil The table, or nil on a grammar violation
--- @return integer|string Next index, or the error message
local function parse_table(toks: {tl.Token}, i: integer, where: string,
    noun: string, depth: integer): {string: any} | nil, integer | string
  if depth > MAX_DEPTH then
    return nil, where .. ":" .. tostring(toks[i] and toks[i].y or 0) ..
    ": a " .. noun .. " nests deeper than " .. MAX_DEPTH .. " tables"
  end
  local out: {string: any} = {}
  local n = #toks
  i = i + 1 -- step over `{`
  while i <= n do
    local t = toks[i]
    if t.tk == "}" then
      return out, i + 1
    end
    -- key: `name =` or `["name"] =`
    local key: string = nil
    if t.kind == "identifier" and toks[i + 1] and toks[i + 1].tk == "=" then
      key = t.tk
      i = i + 2
    elseif t.tk == "[" and toks[i + 1] and toks[i + 1].kind == "string"
    and toks[i + 2] and toks[i + 2].tk == "]"
    and toks[i + 3] and toks[i + 3].tk == "=" then
      key = string_value(toks[i + 1].tk)
      if not key then
        return nil, where .. ":" .. tostring(toks[i + 1].y) ..
        ": a " .. noun .. " has a malformed string key"
      end
      i = i + 4
    else
      return nil, where .. ":" .. tostring(t.y) ..
      ": a " .. noun .. " is a table of `name = <literal>` entries; found '" ..
      t.tk .. "'"
    end
    -- value: a scalar, a keyword literal, or a nested table
    local v = toks[i]
    if not v then
      return nil, where .. ": unexpected end of " .. noun
    end
    if v.tk == "{" then
      local sub, nexti = parse_table(toks, i, where, noun, depth + 1)
      if not sub then
        return nil, nexti as string -- cast: the failure branch returns a message
      end
      out[key] = sub
      i = nexti as integer -- cast: the success branch returns an index
    elseif v.kind == "string" then
      local decoded = string_value(v.tk)
      if not decoded then
        return nil, where .. ":" .. tostring(v.y) ..
        ": a " .. noun .. " has a malformed string value for '" .. key .. "'"
      end
      out[key] = decoded
      i = i + 1
    elseif scalar[v.kind] then
      out[key] = tonumber(v.tk)
      i = i + 1
    elseif v.tk == "-" and toks[i + 1] and scalar[toks[i + 1].kind]
    and toks[i + 1].kind ~= "string" then
      -- The lexer emits `-` as its own token, so a negative number
      -- looked like an operator and was refused. A config that wants
      -- -1 is not asking the file to compute anything.
      out[key] = -(tonumber(toks[i + 1].tk) as number) -- cast: a number token is numeric
      i = i + 2
    elseif v.tk == "true" or v.tk == "false" then
      out[key] = v.tk == "true"
      i = i + 1
    else
      return nil, where .. ":" .. tostring(v.y) ..
      ": a " .. noun .. " holds literals only; found '" .. v.tk ..
      "' (no variables, calls or concatenation)"
    end
    -- A value is followed by a separator or the closing brace, and
    -- nothing else. Without this an operator after a literal (`"a" ..
    -- "b"`) would be read as the next key, and the complaint would be
    -- about a missing name rather than about the concatenation.
    local sep = toks[i]
    if sep and (sep.tk == "," or sep.tk == ";") then
      i = i + 1
    elseif not sep or sep.tk ~= "}" then
      return nil, where .. ":" .. tostring(v.y) ..
      ": a " .. noun .. " holds literals only; found '" .. (sep and sep.tk or "<eof>") ..
      "' after a value (no variables, calls or concatenation)"
    end
  end
  return nil, where .. ": unterminated table in " .. noun
end

--- Read the literal a file returns, without running it.
--- @param source string The file's contents
--- @param where string File name, for messages
--- @param noun string|nil What to call the file in errors (default "literal")
--- @return {string: any}|nil The declared table
--- @return string The error message when the file is not a literal
local function of_source(source: string, where: string, noun?: string): {string: any} | nil, string
  local what = noun or "literal"
  local toks, lex_errs = tl.lex(source, where)
  if lex_errs and #lex_errs > 0 then
    local e = lex_errs[1]
    return nil, where .. ":" .. tostring(e.y) .. ": " .. tostring(e.msg)
  end
  local i = 1
  -- The lexer emits an `$EOF$` sentinel; everything before the `return`
  -- must be nothing at all.
  if not toks[i] or toks[i].tk ~= "return" then
    return nil, where .. ": a " .. what .. " must be exactly `return { … }`"
  end
  i = i + 1
  if not toks[i] or toks[i].tk ~= "{" then
    return nil, where .. ": a " .. what .. " must return a table literal"
  end
  local value, nexti = parse_table(toks, i, where, what, 1)
  if not value then
    return nil, nexti as string -- cast: the failure branch returns a message
  end
  local after = toks[nexti as integer] -- cast: the success branch returns an index
  if after and after.tk ~= "$EOF$" then
    return nil, where .. ":" .. tostring(after.y) ..
    ": a " .. what .. " ends after its table; found '" .. after.tk .. "'"
  end
  return value
end

--- Read a file as a literal table, without running it.
--- @param path string Path to the file
--- @param noun string|nil What to call the file in errors (default "literal")
--- @return {string: any}|nil The declared table
--- @return string The error message when unreadable or not a literal
local function of_file(path: string, noun?: string): {string: any} | nil, string
  local source, rerr = fs.read(path)
  if not source then
    return nil, "cannot read " .. path .. ": " .. (rerr or "unknown error")
  end
  return of_source(source as string, path, noun) -- cast: scalar narrowing after the guard
end

local record LiteralModule
  of_source: function(source: string, where: string, noun?: string): {string: any} | nil, string
  of_file: function(path: string, noun?: string): {string: any} | nil, string
end

local M: LiteralModule = {
  of_source = of_source,
  of_file = of_file,
}

return M
