--- Teal source read and written as data: one `return { … }` of literals.
--- Lexed and matched, never loaded and never called; format/format_file
--- write the same shape parse reads.
--- This is the reader behind `*_pin.tl` (`cosmic --make fetch`), and it
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
---     local cfg = literal.parse_file("config.tl")

local fs = require("cosmic.fs")
local lformat = require("cosmic._literal_format")

--- One lexical token: its raw text, what it is, and the line it began on.
---
--- This module lexes for itself rather than borrowing `tl.lex`: a
--- stripped artifact keeps `cosmic/**` and drops `tl.lua`, so a shared
--- lexer would make `require("cosmic.literal")` throw in exactly the
--- artifacts whose authors want a config file that cannot do anything.
--- The grammar needs identifiers, strings, numbers and punctuation;
--- that is the lexer below, with no dependency beyond `cosmic.fs`.
local record Token
  tk: string
  kind: string
  y: integer
end

--- Token kinds the literal grammar admits, beyond punctuation.
local scalar: {string: boolean} = {
  string = true,
  number = true,
  integer = true,
}

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

--- How deep a literal may nest.
---
--- The parser is recursive descent, so nesting depth is stack depth:
--- without a cap, a crafted `{a={a={a=…}}}` overflows the Lua stack and
--- THROWS, in the one module whose entire promise is that reading a
--- file cannot do anything. A library that throws takes the process
--- down with it, and no caller here is protected. 32 is far past any
--- real pin — the deepest in this repo is 2 — so the cap costs nothing
--- a caller would notice and makes a crafted file get the same polite
--- refusal every other malformed pin gets.
local MAX_DEPTH < const > = 32

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
    return string.char(tonumber(hex, 16) as integer), i + 4 -- cast: two hex digits are integral
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
    return utf8.char(cp as integer), after as integer -- cast: bounded above
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
--- The second return is the index on success and the third is the
--- message on failure, rather than one value meaning both: an
--- `integer|string` here made every caller -- the recursive one
--- included -- cast twice to say which branch it was on, six casts
--- annotating one loose union.
--- @param toks {Token} The lexed tokens
--- @param i integer Index of the opening brace
--- @param where string File name, for messages
--- @param noun string What to call the file in errors
--- @param depth integer How many tables enclose this one
--- @return {string: any}|nil The table, or nil on a grammar violation
--- @return integer The index just past the closing brace
--- @return string The error message when the table is not a literal
local function parse_table(toks: {Token}, i: integer, where: string,
    noun: string, depth: integer): {string: any} | nil, integer, string
  if depth > MAX_DEPTH then
    return nil, 0, where .. ":" .. tostring(toks[i] and toks[i].y or 0) ..
    ": a " .. noun .. " nests deeper than " .. MAX_DEPTH .. " tables"
  end
  local out: {string: any} = {}
  local n = #toks
  i = i + 1 -- step over `{`
  while i <= n do
    local t = toks[i]
    if t.tk == "}" then
      return out, i + 1, ""
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
        return nil, 0, where .. ":" .. tostring(toks[i + 1].y) ..
        ": a " .. noun .. " has a malformed string key"
      end
      i = i + 4
    else
      return nil, 0, where .. ":" .. tostring(t.y) ..
      ": a " .. noun .. " is a table of `name = <literal>` entries; found '" ..
      t.tk .. "'"
    end
    -- value: a scalar, a keyword literal, or a nested table
    local v = toks[i]
    if not v then
      return nil, 0, where .. ": unexpected end of " .. noun
    end
    if v.tk == "{" then
      local sub, nexti, serr = parse_table(toks, i, where, noun, depth + 1)
      if not sub then
        return nil, 0, serr
      end
      out[key] = sub
      i = nexti
    elseif v.kind == "string" then
      local decoded = string_value(v.tk)
      if not decoded then
        return nil, 0, where .. ":" .. tostring(v.y) ..
        ": a " .. noun .. " has a malformed string value for '" .. key .. "'"
      end
      out[key] = decoded
      i = i + 1
    elseif scalar[v.kind] then
      -- The lexer's "number" is a SHAPE, not a value: it accepts `0x.`
      -- and `1e`, which `tonumber` reads as nil. Stored unchecked that
      -- silently dropped the key -- a pin whose `sha256` went missing
      -- rather than being refused -- and negated below it threw
      -- arithmetic-on-nil straight out of a module that must not throw.
      local num = tonumber(v.tk)
      if num == nil then
        return nil, 0, where .. ":" .. tostring(v.y) ..
        ": a " .. noun .. " has a malformed number value for '" .. key .. "'"
      end
      out[key] = num
      i = i + 1
    elseif v.tk == "-" and toks[i + 1] and scalar[toks[i + 1].kind]
    and toks[i + 1].kind ~= "string" then
      -- The lexer emits `-` as its own token, so a negative number
      -- looked like an operator and was refused. A config that wants
      -- -1 is not asking the file to compute anything.
      local neg = tonumber(toks[i + 1].tk)
      if neg == nil then
        return nil, 0, where .. ":" .. tostring(v.y) ..
        ": a " .. noun .. " has a malformed number value for '" .. key .. "'"
      end
      out[key] = -neg
      i = i + 2
    elseif v.tk == "true" or v.tk == "false" then
      out[key] = v.tk == "true"
      i = i + 1
    else
      return nil, 0, where .. ":" .. tostring(v.y) ..
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
      return nil, 0, where .. ":" .. tostring(v.y) ..
      ": a " .. noun .. " holds literals only; found '" .. (sep and sep.tk or "<eof>") ..
      "' after a value (no variables, calls or concatenation)"
    end
  end
  return nil, 0, where .. ": unterminated table in " .. noun
end

--- Options for parse/parse_file: how errors talk about the file.
--- (The field is `file`, not `where`, which Teal reserves.)
local record Options
  --- File name to prefix messages with. Default "literal" for parse;
  --- parse_file defaults it to the path it read.
  file: string
  --- What to call the file in errors — `cosmic --make` reads pins with
  --- noun "pin", so the same grammar complains about "a pin". Default
  --- "literal".
  noun: string
end

--- Read the literal a file returns, without running it.
--- @param source string The file's contents
--- @param opts Options? file: name for messages; noun: file kind in errors
--- @return {string: any}|nil The declared table
--- @return string The error message when the file is not a literal
local function parse(source: string, opts?: Options): {string: any} | nil, string
  local where = (opts and opts.file) or "literal"
  local what = (opts and opts.noun) or "literal"
  local lexed, lex_err = lex(source, where)
  if not lexed then
    return nil, lex_err
  end
  local toks = lexed
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
  local value, nexti, perr = parse_table(toks, i, where, what, 1)
  if not value then
    return nil, perr
  end
  local after = toks[nexti]
  if after and after.tk ~= "$EOF$" then
    return nil, where .. ":" .. tostring(after.y) ..
    ": a " .. what .. " ends after its table; found '" .. after.tk .. "'"
  end
  return value
end

--- Read a file as a literal table, without running it.
--- @param path string Path to the file
--- @param opts Options? noun: file kind in errors; file: message label
--- (defaults to the path)
--- @return {string: any}|nil The declared table
--- @return string The error message when unreadable or not a literal
local function parse_file(path: string, opts?: Options): {string: any} | nil, string
  local source, rerr = fs.read(path)
  if not source then
    return nil, "cannot read " .. path .. ": " .. (rerr or "unknown error")
  end
  local noun = opts and opts.noun
  local label = (opts and opts.file) or path
  return parse(source, {file = label, noun = noun})
end

local record LiteralModule
  type Options = Options
  parse: function(source: string, opts?: Options): {string: any} | nil, string
  parse_file: function(path: string, opts?: Options): {string: any} | nil, string
  --- The format half (#1001): parse(format(v)) round-trips
  --- literal-domain values; contract in cosmic._literal_format.
  format: function(value: any): string | nil, string
  format_file: function(path: string, value: any): boolean, string
end

local M: LiteralModule = {
  parse = parse,
  parse_file = parse_file,
  format = lformat.format,
  format_file = lformat.format_file,
}

return M
