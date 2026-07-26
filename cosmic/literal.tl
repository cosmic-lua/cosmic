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

--- Parse a literal table from a token stream, starting at `{`.
--- Returns the value and the index just past the closing `}`.
--- @param toks {tl.Token} The lexed tokens
--- @param i integer Index of the opening brace
--- @param where string File name, for messages
--- @return {string: any}|nil The table, or nil on a grammar violation
--- @return integer|string Next index, or the error message
local function parse_table(toks: {tl.Token}, i: integer, where: string, noun: string): {string: any} | nil, integer | string
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
      key = toks[i + 1].tk:sub(2, -2)
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
      local sub, nexti = parse_table(toks, i, where, noun)
      if not sub then
        return nil, nexti as string -- cast: the failure branch returns a message
      end
      out[key] = sub
      i = nexti as integer -- cast: the success branch returns an index
    elseif v.kind == "string" then
      out[key] = v.tk:sub(2, -2)
      i = i + 1
    elseif scalar[v.kind] then
      out[key] = tonumber(v.tk)
      i = i + 1
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
  local value, nexti = parse_table(toks, i, where, what)
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
