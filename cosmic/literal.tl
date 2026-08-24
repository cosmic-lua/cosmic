--- Teal source read and written as data: one `return { … }` of literals.
--- Lexed and matched, never loaded and never called; format/format_file
--- write what parse reads and refuse what parse would refuse.
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
local lit_lex = require("cosmic._literal_lex")

--- One lexical token: its raw text, what it is, and the line it began on.
--- Lexing itself lives in `cosmic._literal_lex` (see that module's
--- header for why this module lexes for itself rather than borrowing
--- `tl.lex`); `Token` and `lex` are re-exposed here because `parse_table`
--- and `parse` are their callers.
local type Token = lit_lex.Token
local lex = lit_lex.lex

--- Token kinds the literal grammar admits, beyond punctuation.
local scalar: {string: boolean} = {
  string = true,
  number = true,
  integer = true,
}

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
    local n = tonumber(digits, 10) as integer -- cast: decimal digits are integral
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

--- One parsed table literal: the value, and the index just past its
--- closing `}` — one record keeps the error in slot 2.
local record Parsed
  value: {string: any}
  next: integer
end

--- Resolves a repeated key: called with the value already stored for it
--- and the newly parsed one for the SAME key in the SAME table. Its
--- return value is stored as-is — a nil return stores nil. The resolver
--- is infallible: it decides between the two values, it does not fail;
--- a duplicate key with no resolver is refused instead, in
--- `parse_table` below.
local type OnDuplicate = function(key: string, first: any, second: any): any

--- Parse a literal table from a token stream, starting at `{`.
--- @param toks {Token} The lexed tokens
--- @param i integer Index of the opening brace
--- @param where string File name, for messages
--- @param noun string What to call the file in errors
--- @param depth integer How many tables enclose this one
--- @param on_duplicate OnDuplicate? Resolves a repeated key; nil refuses it
--- @return Parsed|nil The table and where it ended
--- @return string The error when the table is not a literal
local function parse_table(toks: {Token}, i: integer, where: string,
    noun: string, depth: integer, on_duplicate?: OnDuplicate): Parsed | nil, string
  if depth > MAX_DEPTH then
    return nil, where .. ":" .. tostring(toks[i] and toks[i].y or 0) ..
    ": a " .. noun .. " nests deeper than " .. MAX_DEPTH .. " tables"
  end
  local out: {string: any} = {}
  -- First-seen line per key, PER TABLE: a fresh `seen` for every call, so
  -- the same key in two different nested tables is not a duplicate.
  local seen: {string: integer} = {}
  local n = #toks
  i = i + 1 -- step over `{`
  while i <= n do
    local t = toks[i]
    if t.tk == "}" then
      return {value = out, next = i + 1}
    end
    -- key: `name =` or `["name"] =`
    local key: string = nil
    local key_line: integer = nil
    if t.kind == "identifier" and toks[i + 1] and toks[i + 1].tk == "=" then
      key = t.tk
      key_line = t.y
      i = i + 2
    elseif t.tk == "[" and toks[i + 1] and toks[i + 1].kind == "string"
    and toks[i + 2] and toks[i + 2].tk == "]"
    and toks[i + 3] and toks[i + 3].tk == "=" then
      key = string_value(toks[i + 1].tk)
      if not key then
        return nil, where .. ":" .. tostring(toks[i + 1].y) ..
        ": a " .. noun .. " has a malformed string key"
      end
      key_line = t.y
      i = i + 4
    else
      return nil, where .. ":" .. tostring(t.y) ..
      ": a " .. noun .. " is a table of `name = <literal>` entries; found '" ..
      t.tk .. "'"
    end
    -- value: a scalar, a keyword literal, or a nested table -- computed
    -- into a local so every branch reaches the SAME assignment site
    -- below, the one place the duplicate-key check can live.
    local v = toks[i]
    if not v then
      return nil, where .. ": unexpected end of " .. noun
    end
    local value: any
    if v.tk == "{" then
      local sub, serr = parse_table(toks, i, where, noun, depth + 1, on_duplicate)
      if not sub then
        return nil, serr
      end
      value = sub.value
      i = sub.next
    elseif v.kind == "string" then
      local decoded = string_value(v.tk)
      if not decoded then
        return nil, where .. ":" .. tostring(v.y) ..
        ": a " .. noun .. " has a malformed string value for '" .. key .. "'"
      end
      value = decoded
      i = i + 1
    elseif scalar[v.kind] then
      -- The lexer's "number" is a SHAPE, not a value: it accepts `0x.`
      -- and `1e`, which `tonumber` reads as nil. Stored unchecked that
      -- silently dropped the key -- a pin whose `sha256` went missing
      -- rather than being refused -- and negated below it threw
      -- arithmetic-on-nil straight out of a module that must not throw.
      local num = tonumber(v.tk)
      if num == nil then
        return nil, where .. ":" .. tostring(v.y) ..
        ": a " .. noun .. " has a malformed number value for '" .. key .. "'"
      end
      value = num
      i = i + 1
    elseif v.tk == "-" and toks[i + 1] and scalar[toks[i + 1].kind]
    and toks[i + 1].kind ~= "string" then
      -- The lexer emits `-` as its own token, so a negative number
      -- looked like an operator and was refused. A config that wants
      -- -1 is not asking the file to compute anything.
      local neg = tonumber(toks[i + 1].tk)
      if neg == nil then
        return nil, where .. ":" .. tostring(v.y) ..
        ": a " .. noun .. " has a malformed number value for '" .. key .. "'"
      end
      value = -neg
      i = i + 2
    elseif v.tk == "true" or v.tk == "false" then
      value = v.tk == "true"
      i = i + 1
    else
      return nil, where .. ":" .. tostring(v.y) ..
      ": a " .. noun .. " holds literals only; found '" .. v.tk ..
      "' (no variables, calls or concatenation)"
    end
    -- The one assignment site: a fresh key is recorded and stored; a
    -- repeated one goes to the resolver when there is one, and is
    -- refused by name -- both lines -- when there is not.
    if seen[key] then
      if on_duplicate then
        out[key] = on_duplicate(key, out[key], value)
      else
        return nil, where .. ":" .. tostring(key_line) ..
        ": a " .. noun .. " repeats the key '" .. key .. "' (first at line " ..
        tostring(seen[key]) .. ")"
      end
    else
      seen[key] = key_line
      out[key] = value
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
  --- Resolves a key repeated within one table instead of refusing it.
  --- Default nil: a repeated key is refused, naming both lines.
  on_duplicate: OnDuplicate
end

--- Read the literal a file returns, without running it.
--- @param source string The file's contents
--- @param opts Options? file: name for messages; noun: file kind in
--- errors; on_duplicate: resolves a repeated key instead of refusing it
--- @return {string: any}|nil The declared table
--- @return string The error message when the file is not a literal
local function parse(source: string, opts?: Options): {string: any} | nil, string
  local where = (opts and opts.file) or "literal"
  local what = (opts and opts.noun) or "literal"
  local on_duplicate = opts and opts.on_duplicate
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
  local parsed, perr = parse_table(toks, i, where, what, 1, on_duplicate)
  if not parsed then
    return nil, perr
  end
  local after = toks[parsed.next]
  if after and after.tk ~= "$EOF$" then
    return nil, where .. ":" .. tostring(after.y) ..
    ": a " .. what .. " ends after its table; found '" .. after.tk .. "'"
  end
  return parsed.value
end

--- Read a file as a literal table, without running it.
--- @param path string Path to the file
--- @param opts Options? noun: file kind in errors; file: message label
--- (defaults to the path); on_duplicate: resolves a repeated key
--- @return {string: any}|nil The declared table
--- @return string The error message when unreadable or not a literal
local function parse_file(path: string, opts?: Options): {string: any} | nil, string
  local source, rerr = fs.read(path)
  if not source then
    return nil, "cannot read " .. path .. ": " .. (rerr or "unknown error")
  end
  local noun = opts and opts.noun
  local label = (opts and opts.file) or path
  local on_duplicate = opts and opts.on_duplicate
  return parse(source, {file = label, noun = noun, on_duplicate = on_duplicate})
end

--- How `format` lays its output out. Both layouts admit exactly the
--- same values and refuse the same ones by the same key path; what
--- differs is the bytes and what they cost to produce.
local record FormatOptions
  --- `"pin"`, the default, or `"compact"`.
  layout: string
end

--- Serialize a value as a literal file's source.
---
--- The default `"pin"` layout is the one a committed file wants: one
--- entry per line, keys sorted and bracketed, and a `cosmic --check
--- fmt` fixpoint, so the file this writes is the file the formatting
--- gate accepts. `"compact"` is the bulk layout for data read back by
--- machine and never formatted: the same domain and the same
--- refusals, on one line, encoded in C — several times faster and
--- smaller, with no fixpoint promise. `"compact"` asks for smaller
--- output rather than promising it: the few values the C encoder
--- cannot spell as literals (a reserved word as a key,
--- `math.mininteger`) come back in the `"pin"` layout instead, so what
--- this returns is always something `parse` reads back.
--- @param value any The value to serialize
--- @param opts FormatOptions? layout: "pin" (default) or "compact"
--- @return string | nil The literal source, or nil when the value is outside the domain
--- @return string? Error message on failure, naming the key path refused
local function format(value: any, opts?: FormatOptions): string | nil, string
  local layout = (opts and opts.layout) or "pin"
  if layout == "pin" then
    return lformat.format(value)
  end
  if layout == "compact" then
    return lformat.format_compact(value)
  end
  return nil, "a layout is \"pin\" or \"compact\", not \"" .. layout .. "\""
end

local record LiteralModule
  type Options = Options
  type FormatOptions = FormatOptions
  parse: function(source: string, opts?: Options): {string: any} | nil, string
  parse_file: function(path: string, opts?: Options): {string: any} | nil, string
  --- The format half: parse(format(v)) round-trips and a value outside
  --- the domain is refused, in either layout — "pin" (the default) is a
  --- fmt fixpoint, "compact" is the faster bulk form; see
  --- _literal_format.
  format: function(value: any, opts?: FormatOptions): string | nil, string
  format_file: function(path: string, value: any): boolean, string
end

local M: LiteralModule = {
  parse = parse,
  parse_file = parse_file,
  format = format,
  format_file = lformat.format_file,
}

return M
