--- The lexer of the new checker's grammar ([`doc/plans/new-checker-grammar.md`],
--- "the lexical grammar"): Lua 5.5's tokens with the grammar's changes.
---
--- `lex` reads a whole source and answers its tokens and its errors. It
--- never raises and does not stop at a problem: an unterminated string or
--- long comment, a stray byte, a malformed number or a bad escape is a token
--- of kind `$ERR$` with an [`Error`], and lexing goes on, so one run reports
--- several problems. An unterminated short string ends at the end of its
--- line; an unterminated long string or long comment runs to the end of the
--- file, as in Lua, so it is the last problem the run finds. A form the
--- grammar cuts (a `goto`, a label, a `;`, a long comment, a `#!` line, a
--- `_` in a number, a hexadecimal float) is refused the same way. A cut form
--- that has a token of its own meaning (a long comment, a number) keeps that
--- token and gains an error. A cut form that has none (a `goto`, a label, a
--- `;`, a `#!` line) is an `$ERR$` token.
---
--- The tokens and the comments between them hold every byte of the source
--- but whitespace: a token's `offset` and `length` and a comment's say where
--- each byte is, so a file is written back from them. A comment is not a
--- token. It is `--` to the end of the line, without the line break, and is
--- kept on the token after it, in `comments`. The final `$EOF$` token keeps
--- the comments after the last token.
---
--- A line break is `\n`, `\r`, `\r\n` or `\n\r`, each one, as in Lua's own
--- lexer, whether it ends a line, follows a backslash in a short string or
--- stands in a long string (where it is value `\n`). Columns count bytes,
--- from 1. Where a source has no `\r`, a position is the one the fork's `lex`
--- gives, so what reads those reads these.
---
--- Every error has a `code`, a `msg` that says what is wrong and a `fix`
--- that says how to put it right in the program's own terms. [`Code`]
--- catalogues the codes. They are not yet in [`build/compiler.d.tl`]'s
--- `ErrorCode`: that enum belongs to the fork. Once the new checker
--- replaces the fork, the enum is [`Code`] with the parser's and
--- the checker's codes beside it, and a hint in [`build/teal.tl`] reads
--- `fix` as it reads the fork's `msg` today.
---
--- The core never calls `setlocale`, so `%w` in the patterns below is ASCII.
local find, byte, sub, match, concat = string.find, string.byte, string.sub, string.match, table.concat
local tonumber, math_type = tonumber, math.type

local record Lexer
  --- The kind of a token. A bracket, `,`, `:`, `.`, `?` and `...` are their
  --- own kind. `op` is every other operator and punctuator (`=` and `|`
  --- among them) and `keyword` every reserved word, with the text in `text`.
  --- `integer` is a number Lua reads as an integer and `number` one it reads
  --- as a float, so a decimal integer too big for 64 bits is a `number`.
  --- `$ERR$` is a form that is no token of the grammar, which has an
  --- [`Error`].
  enum Kind
    "identifier"
    "keyword"
    "op"
    "string"
    "integer"
    "number"
    "("
    ")"
    "{"
    "}"
    "["
    "]"
    ","
    ":"
    "."
    "?"
    "..."
    "$ERR$"
    "$EOF$"
  end

  -- TODO: add these codes to the `ErrorCode` of build/compiler.d.tl and have
  -- build/teal.tl show `fix`, once the new checker replaces the fork's
  -- compiler in the tree (doc/plans/new-checker-grammar.md, "the interface").

  --- What an error is, so that a reader does not parse its `msg`. Every code
  --- is a lexical error and sets the fields of [`Error`].
  enum Code
    -- `goto`, with its label if one follows, or a label `::name::`
    "label_or_goto"
    -- a `;`
    "semicolon"
    -- a long comment `--[[ ... ]]`
    "long_comment"
    -- a long comment with no closing bracket: the token runs to the end
    "unterminated_long_comment"
    -- a `#!` first line
    "hashbang"
    -- a `_` between digits: the token is the number without it
    "digit_separator"
    -- a hexadecimal float: the token is the number
    "hex_float"
    -- a numeral Lua reads as one token and cannot convert
    "malformed_number"
    -- a short string with no closing quote before the end of its line
    "unterminated_string"
    -- a long string with no closing bracket: the token runs to the end
    "unterminated_long_string"
    -- a backslash in a short string that is no escape, or a malformed one
    "bad_escape"
    -- a byte, or a run of non-ASCII bytes, that begins no token
    "stray_byte"
  end

  --- A comment, `--` to the end of its line. It is kept on the token that
  --- follows it.
  record Comment
    --- The comment's bytes, `--` included, without the line break.
    text: string
    --- The byte offset of its first byte, from 1.
    offset: integer
    --- Its length in bytes.
    length: integer
    --- Its line, from 1.
    y: integer
    --- Its column, from 1.
    x: integer
  end

  --- A token. The positions are those of its first and last byte; for the
  --- `$EOF$` token, which is empty, `xend` is `x - 1`.
  record Token
    kind: Kind
    --- The source bytes of the token, exactly. A string token holds its
    --- quotes and a long string its brackets.
    text: string
    --- A string's contents, escapes decoded and, for a long string, without
    --- the line break after its opening bracket. Nil for any other token.
    value: string | nil
    --- A number's value. Nil for any other token.
    number: number | nil
    --- True for a long string; nil for any other token, a short string
    --- among them.
    long: boolean | nil
    --- The byte offset of the first byte, from 1.
    offset: integer
    --- The length in bytes.
    length: integer
    y: integer
    x: integer
    yend: integer
    xend: integer
    --- The comments before the token, in source order. Nil where there are
    --- none.
    comments: {Comment} | nil
  end

  --- A lexical error. `y`, `x`, `offset` and `length` place the bytes at
  --- fault.
  record Error
    filename: string
    code: Code
    --- What is wrong, in one line.
    msg: string
    --- How to put it right, written against the program's own text.
    fix: string
    y: integer
    x: integer
    offset: integer
    length: integer
  end

  --- What `lex` answers. A record, not two results: an exported function
  --- answers one ([`build.contracts`]).
  record Lexed
    --- Every token in source order, the last an `$EOF$`.
    tokens: {Token}
    --- Every error in source order.
    errors: {Error}
  end

  --- Lexes `source`, which is named `name` in each error. A program and a
  --- declaration file (`.d.tl`) lex alike.
  lex: function(source: string, name: string): Lexed

  --- Every reserved word, as `keyword` tokens.
  reserved: {string: boolean}

  --- Every [`Code`], in the order the enum lists them.
  codes: {Code}

  --- The words the grammar reserves that Lua does not.
  added: {string}

  --- The words that stay names and are read as keywords by the parser where
  --- a declaration begins: `type` is a Lua function and `record` binds 49
  --- times in the tree, so the lexer gives each an `identifier`.
  declaration_words: {string}

  --- Whether `token` may stand where a field name does (after `.` or `:`,
  --- as a table key before `=`, or in a member position before `:`): a
  --- name or any reserved word.
  field_word: function(token: Token): boolean
end

local lua_words: {string} = {
  "and", "break", "do", "else", "elseif", "end", "false", "for", "function",
  "global", "goto", "if", "in", "local", "nil", "not", "or", "repeat",
  "return", "then", "true", "until", "while",
}

local added_words: {string} = { "match", "continue", "mut", "is", "asserts", "userdata", "as" }

-- 1 is a plain reserved word; 2 is `goto`, which is refused unless it stands
-- where a field name does.
--
-- TODO: take the test of where a field name stands out of the lexer, which
-- guesses it from the bytes around `goto` (after `.` or `:`, before `=` or
-- `:`), once the parser exists and refuses a `goto` statement itself with
-- the code `label_or_goto` (doc/plans/new-checker-grammar.md, "the lexical
-- grammar").
local words: {string: integer} = {}
for _, w in ipairs(lua_words) do
  words[w] = w == "goto" and 2 or 1
end
for _, w in ipairs(added_words) do
  words[w] = 1
end

local reserved_set: {string: boolean} = {}
for w in pairs(words) do
  reserved_set[w] = true
end

-- What a byte begins: a name (1), a blank (2), a line break (3), a token of
-- one byte (4), a digit (5), a quote (6), an operator of one byte or two
-- (7), `-` (8), `.` (9), `:` (10) or `[` (11). Any other byte is looked at
-- singly.
local class: {integer: integer} = {}
for c = byte("a"), byte("z") do class[c] = 1 end
for c = byte("A"), byte("Z") do class[c] = 1 end
class[byte("_")] = 1
for _, c in ipairs({ 32, 9, 11, 12 }) do class[c] = 2 end
class[10] = 3
class[13] = 3
for c = byte("0"), byte("9") do class[c] = 5 end
class[34] = 6
class[39] = 6

-- The bytes that begin an operator of one byte or two, with the bytes that
-- may follow to make it two.
local second: {integer: {integer: boolean}} = {
  [byte("=")] = { [byte("=")] = true },
  [byte("~")] = { [byte("=")] = true },
  [byte("<")] = { [byte("=")] = true, [byte("<")] = true },
  [byte(">")] = { [byte("=")] = true, [byte(">")] = true },
  [byte("/")] = { [byte("/")] = true },
}
for c in pairs(second) do class[c] = 7 end
class[byte("-")] = 8
class[byte(".")] = 9
class[byte(":")] = 10
class[byte("[")] = 11

local bracket_kinds: {string: Lexer.Kind} = {
  ["("] = "(", [")"] = ")", ["{"] = "{", ["}"] = "}", ["]"] = "]", [","] = ",", ["?"] = "?",
  ["#"] = "op", ["+"] = "op", ["*"] = "op", ["%"] = "op", ["^"] = "op", ["&"] = "op", ["|"] = "op",
}
local one_text: {integer: string} = {}
local one_kind: {integer: Lexer.Kind} = {}
for text, kind in pairs(bracket_kinds) do
  one_text[byte(text)] = text
  one_kind[byte(text)] = kind
  class[byte(text)] = 4
end
for _, text in ipairs({ "=", "~", "<", ">", "/" }) do
  one_text[byte(text)] = text
end

local simple_escape: {integer: string} = {
  [byte("a")] = "\a", [byte("b")] = "\b", [byte("f")] = "\f", [byte("n")] = "\n",
  [byte("r")] = "\r", [byte("t")] = "\t", [byte("v")] = "\v", [byte("\\")] = "\\",
  [byte("\"")] = "\"", [byte("'")] = "'",
}

local NEWLINE <const> = 10
local CARRIAGE_RETURN <const> = 13

local function add_error(errors: {Lexer.Error}, name: string, code: Lexer.Code,
                         msg: string, fix: string, offset: integer, length: integer,
                         y: integer, x: integer)
  errors[#errors + 1] = {
    filename = name, code = code, msg = msg, fix = fix,
    offset = offset, length = length, y = y, x = x,
  }
end

--- A byte or character as the messages show it: itself when it is printable
--- ASCII or a whole UTF-8 character, else each of its bytes as `\xNN`.
local function shown(text: string): string
  local b = byte(text)
  if #text == 1 and b >= 32 and b < 127 then
    return text
  end
  if #text > 1 and utf8.len(text) ~= nil and not find(text, "[%c]") then
    return text
  end
  local hex: {string} = {}
  for i = 1, #text do
    hex[i] = string.format("\\x%02X", byte(text, i))
  end
  return concat(hex)
end

--- The length of the line break that begins at `i` of `text`, 0 where none
--- does. As in Lua, `\n`, `\r`, `\r\n` and `\n\r` are each one.
local function break_at(text: string, i: integer): integer
  local c = byte(text, i)
  if c ~= NEWLINE and c ~= CARRIAGE_RETURN then
    return 0
  end
  local d = byte(text, i + 1)
  if (d == NEWLINE or d == CARRIAGE_RETURN) and d ~= c then
    return 2
  end
  return 1
end

--- The line and the offset of its first byte after the line breaks in
--- `text`, which holds the source from offset `base`, and the offset of the
--- line before it. It reads the token's own bytes only, so a long line costs
--- what it holds.
local function advance_lines(text: string, base: integer, line: integer,
                             line_start: integer): integer, integer, integer
  local p = 1
  local previous = line_start
  while true do
    local q = find(text, "[\r\n]", p)
    if not q then
      return line, line_start, previous
    end
    line = line + 1
    p = q + break_at(text, q)
    previous = line_start
    line_start = base + p - 1
  end
end

--- What a token of several lines, whose bytes are `text` from offset `base`
--- and which begins on `line` at `line_start`, leaves the lexer at: the line
--- and the offset of the line that follows it, and the place of its last
--- byte (which is on the line before when it is a line break).
local function span_end(text: string, base: integer, line: integer,
                        line_start: integer): integer, integer, integer, integer
  local yend, yend_start, previous = advance_lines(text, base, line, line_start)
  local last = base + #text - 1
  if yend_start == last + 1 then
    return yend, yend_start, yend - 1, last - previous + 1
  end
  return yend, yend_start, yend, last - yend_start + 1
end

--- `text` with each line break written `\n`.
local function normalised(text: string): string
  local out: {string} = {}
  local n = 0
  local p = 1
  while true do
    local q = find(text, "[\r\n]", p)
    if not q then
      out[n + 1] = sub(text, p)
      return concat(out)
    end
    out[n + 1] = sub(text, p, q - 1)
    out[n + 2] = "\n"
    n = n + 2
    p = q + break_at(text, q)
  end
end

--- The fix for the escape `\` and `bad`, a character of the source.
local function escape_fix(bad: string): string
  local shown_bad = shown(bad)
  return "write `\\\\" .. shown_bad .. "` for a backslash followed by `" .. shown_bad ..
    "`, or `" .. shown_bad .. "` alone. The escapes are `\\a \\b \\f \\n \\r \\t \\v \\\\ \\\" \\' \\z`," ..
    " `\\xNN`, `\\ddd` up to 255, `\\u{NNN}` and a backslash before a line break"
end

--- Where the escape that begins at the backslash `s` of `source` ends, and
--- what is wrong with it: "" for a good escape, else the fix for it.
local function check_escape(source: string, s: integer): integer, string
  local c = byte(source, s + 1)
  if c == nil then
    return s, ""
  end
  if simple_escape[c] then
    return s + 1, ""
  elseif c == NEWLINE or c == CARRIAGE_RETURN then
    return s + break_at(source, s + 1), ""
  elseif c == byte("z") then
    local _, e = find(source, "^[ \t\r\n\v\f]*", s + 2)
    return e, ""
  elseif c == byte("x") then
    if find(source, "^%x%x", s + 2) then
      return s + 3, ""
    end
    local _, e = find(source, "^%x?", s + 2)
    return e, "`\\x` takes exactly two hexadecimal digits: write `\\x41` for `A`"
  elseif c >= 48 and c <= 57 then
    local _, e = find(source, "^%d%d?%d?", s + 1)
    if tonumber(sub(source, s + 1, e)) > 255 then
      return e, "a decimal escape is at most `\\255`: write a character past 255 as `\\u{...}`, as `\\u{100}`"
    end
    return e, ""
  elseif c == byte("u") then
    local _, e, digits = find(source, "^{(%x+)}", s + 2)
    if e then
      local significant = digits:gsub("^0+", "")
      if #significant <= 8 and (significant == "" or tonumber(significant, 16) <= 0x7FFFFFFF) then
        return e, ""
      end
      return e, "a code point in `\\u{...}` is at most `7FFFFFFF`: write `\\u{20AC}` for the euro sign"
    end
    return s + 1, "`\\u` takes hexadecimal digits in braces: write `\\u{20AC}` for the euro sign"
  end
  -- The whole character, so that a message never shows half of one.
  local _, e = find(source, "^[\192-\255][\128-\191]*", s + 1)
  e = e or s + 1
  return e, escape_fix(sub(source, s + 1, e))
end

--- Reads a short string that is not a plain run of bytes between its quotes.
--- Answers where its closing quote is (0 when the line ends first), the
--- last byte the token holds, and the place of its first bad escape (0 when
--- every one is good), its length and what to do about it.
local function read_string(source: string, pos: integer, quote: integer
): integer, integer, integer, integer, string
  local pattern = quote == 34 and "[\"\\\r\n]" or "['\\\r\n]"
  local i = pos + 1
  local bad_at, bad_length = 0, 0
  local bad_fix = ""
  while true do
    local s = find(source, pattern, i)
    if not s then
      return 0, #source, bad_at, bad_length, bad_fix
    end
    local c = byte(source, s)
    if c == quote then
      return s, s, bad_at, bad_length, bad_fix
    elseif c == NEWLINE or c == CARRIAGE_RETURN then
      return 0, s - 1, bad_at, bad_length, bad_fix
    end
    if byte(source, s + 1) == nil then
      return 0, s, bad_at, bad_length, bad_fix
    end
    local e, fix = check_escape(source, s)
    if fix ~= "" and bad_at == 0 then
      bad_at, bad_length, bad_fix = s, e - s + 1, fix
    end
    i = e + 1
  end
end

--- The contents of a short string's source (`inner`, without its quotes) with
--- every escape decoded. `inner` holds only good escapes.
local function decode(inner: string): string
  local out: {string} = {}
  local n = 0
  local i = 1
  while true do
    local s = find(inner, "\\", i, true)
    if not s then
      n = n + 1
      out[n] = sub(inner, i)
      break
    end
    if s > i then
      n = n + 1
      out[n] = sub(inner, i, s - 1)
    end
    local c = byte(inner, s + 1)
    local text: string
    local e = s + 1
    if simple_escape[c] then
      text = simple_escape[c]
    elseif c == NEWLINE or c == CARRIAGE_RETURN then
      text = "\n"
      e = s + break_at(inner, s + 1)
    elseif c == byte("z") then
      local _, ze = find(inner, "^[ \t\r\n\v\f]*", s + 2)
      text = ""
      e = ze
    elseif c == byte("x") then
      text = string.char(math.tointeger(tonumber(sub(inner, s + 2, s + 3), 16)))
      e = s + 3
    elseif c == byte("u") then
      local _, ue, digits = find(inner, "^{(%x+)}", s + 2)
      text = utf8.char(math.tointeger(tonumber(digits, 16)))
      e = ue
    else
      local _, de = find(inner, "^%d%d?%d?", s + 1)
      text = string.char(math.tointeger(tonumber(sub(inner, s + 1, de))))
      e = de
    end
    n = n + 1
    out[n] = text
    i = e + 1
  end
  return concat(out)
end

--- The last byte of the numeral that begins at `pos`, read as Lua reads one:
--- digits, hexadecimal digits, dots and `_`, an exponent with its sign, and then
--- the letters and `_` that make it malformed.
local function numeral_end(source: string, pos: integer): integer
  local hex = byte(source, pos) == 48 and (byte(source, pos + 1) == 120 or byte(source, pos + 1) == 88)
  local i = hex and pos + 2 or pos
  while true do
    local c = byte(source, i)
    if c == nil then
      break
    end
    if hex and (c == 80 or c == 112) or not hex and (c == 69 or c == 101) then
      i = i + 1
      local sign = byte(source, i)
      if sign == 43 or sign == 45 then
        i = i + 1
      end
    elseif (c >= 48 and c <= 57) or (c >= 65 and c <= 70) or (c >= 97 and c <= 102) or c == 46 or c == 95 then
      i = i + 1
    else
      break
    end
  end
  local _, e = find(source, "^[%w_]*", i)
  return e
end

--- The fix for a hexadecimal float of this finite or infinite `value`: it
--- written in decimal, which reads back as the same float.
local function hex_float_fix(value: number): string
  if value ~= value or value == math.huge or value == -math.huge then
    return "the value is out of range for a float: write a value a float holds, in decimal"
  end
  local text = string.format("%.17g", value)
  if not find(text, "[%.eE]") then
    text = text .. ".0"
  end
  return "write the value in decimal: `" .. text .. "`"
end

function Lexer.field_word(token: Lexer.Token): boolean
  return token.kind == "identifier" or token.kind == "keyword"
end

--- The fix for a `goto`, whose label is `label` where one follows.
local function goto_fix(label: string | nil): string
  if label == "continue" then
    return "write `continue`"
  end
  return "write `continue` to skip the rest of a pass of the loop around it; restructure any other jump with an" ..
    " `if` around the code to skip, or move the code into a function and `return` from it"
end

--- The offset of the first byte at or after `i` that is not whitespace and
--- not in a comment; one past the end of `source` where none is.
local function significant(source: string, i: integer): integer
  while true do
    local s = find(source, "[^ \t\r\n\v\f]", i)
    if not s then
      return #source + 1
    end
    if byte(source, s) ~= 45 or byte(source, s + 1) ~= 45 then
      return s
    end
    local _, open_end, level = find(source, "^%[(=*)%[", s + 2)
    if open_end then
      local _, close_end = find(source, "]" .. level .. "]", open_end + 1, true)
      if not close_end then
        return #source + 1
      end
      i = close_end + 1
    else
      local line_end = find(source, "[\r\n]", s + 2)
      if not line_end then
        return #source + 1
      end
      i = line_end
    end
  end
end

--- Whether the `goto` that ends at `e` stands where a field name does: after
--- `.` or `:`, as a table key before `=`, or as a member before `:` or `?:`.
local function names_a_field(source: string, e: integer, previous: Lexer.Token | nil): boolean
  if previous ~= nil and (previous.kind == "." or previous.kind == ":") then
    return true
  end
  local at = significant(source, e + 1)
  local c = byte(source, at)
  if c == 61 then
    return byte(source, at + 1) ~= 61
  elseif c == 58 then
    return byte(source, at + 1) ~= 58
  elseif c == 63 then
    return byte(source, significant(source, at + 1)) == 58
  end
  return false
end

local malformed_fix <const> = "write decimal digits with an optional fraction and exponent (`12`, `1.5`, `2e10`) " ..
  "or `0x` and hexadecimal digits (`0xFF`), and put a space between a number and the name or operator after it"

function Lexer.lex(source: string, name: string): Lexer.Lexed
  local tokens: {Lexer.Token} = {}
  local errors: {Lexer.Error} = {}
  local n = 0
  local len = #source
  local pos = 1
  local line = 1
  local line_start = 1
  local pending: {Lexer.Comment} | nil = nil

  if sub(source, 1, 2) == "#!" then
    local e = (find(source, "[\r\n]", 3) or len + 1) - 1
    n = 1
    tokens[1] = {
      kind = "$ERR$", text = sub(source, 1, e), offset = 1, length = e, y = 1, x = 1, yend = 1, xend = e,
    }
    add_error(errors, name, "hashbang", "a `#!` first line is not in the grammar",
      "delete the line; run the file with `cosmic " .. name .. "`", 1, e, 1, 1)
    pos = e + 1
  end

  -- A token of one line and of nothing but its kind and text is made at the
  -- foot of the loop: eight fields, which a table holds in half the space of
  -- nine. Tokens that carry more are made where they are read.
  while pos <= len do
    local b = byte(source, pos)
    local c = class[b]
    local kind: Lexer.Kind | nil = nil
    local text = ""
    local e = pos
    if c == 1 then
      text = match(source, "^[%a_][%w_]*", pos)
      e = pos + #text - 1
      local word = words[text]
      if word == nil then
        kind = "identifier"
      elseif word == 1 then
        kind = "keyword"
      else
        kind = "keyword"
        if not names_a_field(source, e, tokens[n]) then
          kind = "$ERR$"
          local _, le, label = find(source, "^[ \t]+([%a_][%w_]*)", e + 1)
          if le then
            e = le
            text = sub(source, pos, e)
          end
          add_error(errors, name, "label_or_goto", "`" .. text .. "` is not in the grammar", goto_fix(label),
            pos, e - pos + 1, line, pos - line_start + 1)
        end
      end
    elseif c == 2 then
      pos = pos + 1
      if class[byte(source, pos)] == 2 then
        pos = find(source, "[^ \t\v\f]", pos + 1) or len + 1
      end
    elseif c == 4 then
      kind = one_kind[b]
      text = one_text[b]
    elseif c == 3 then
      line = line + 1
      pos = pos + break_at(source, pos)
      line_start = pos
    elseif c == 7 then
      kind = "op"
      if second[b][byte(source, pos + 1)] then
        e = pos + 1
        text = sub(source, pos, e)
      else
        text = one_text[b]
      end
    elseif c == 8 and byte(source, pos + 1) ~= 45 then
      kind = "op"
      text = "-"
    elseif c == 8 then
      -- `--`: a line comment, or a long one the grammar cuts.
      local x = pos - line_start + 1
      local _, open_end, level = find(source, "^%[(=*)%[", pos + 2)
      if open_end then
        local close = "]" .. level .. "]"
        local cs, ce = find(source, close, open_end + 1, true)
        if not cs then
          local text_to_end = sub(source, pos)
          local yend, yend_start, end_y, end_x = span_end(text_to_end, pos, line, line_start)
          n = n + 1
          tokens[n] = {
            kind = "$ERR$", text = text_to_end, offset = pos, length = len - pos + 1,
            y = line, x = x, yend = end_y, xend = end_x, comments = pending,
          }
          pending = nil
          add_error(errors, name, "unterminated_long_comment", "unfinished long comment",
            "write line comments, which begin each line with `--`; a long comment is not in the grammar" ..
              " and this one has no closing `" .. close .. "`", pos, len - pos + 1, line, x)
          line, line_start = yend, yend_start
          pos = len + 1
        else
          local comment_text = sub(source, pos, ce)
          local comments = pending or {}
          comments[#comments + 1] = {
            text = comment_text, offset = pos, length = ce - pos + 1, y = line, x = x,
          }
          pending = comments
          add_error(errors, name, "long_comment", "long comments are not in the grammar",
            "write line comments: begin each line of the comment with `--`", pos, ce - pos + 1, line, x)
          line, line_start = advance_lines(comment_text, pos, line, line_start)
          pos = ce + 1
        end
      else
        local ce = (find(source, "[\r\n]", pos + 2) or len + 1) - 1
        local comments = pending or {}
        comments[#comments + 1] = {
          text = sub(source, pos, ce), offset = pos, length = ce - pos + 1, y = line, x = x,
        }
        pending = comments
        pos = ce + 1
      end
    elseif c == 6 then
      local x = pos - line_start + 1
      local s = find(source, b == 34 and "[\"\\\r\n]" or "['\\\r\n]", pos + 1)
      if s and byte(source, s) == b then
        -- No escape and no line break: the common string, on one line.
        n = n + 1
        tokens[n] = {
          kind = "string", text = sub(source, pos, s), value = sub(source, pos + 1, s - 1),
          offset = pos, length = s - pos + 1, y = line, x = x, yend = line, xend = x + s - pos,
          comments = pending,
        }
        pending = nil
        pos = s + 1
      else
        local close, stop, bad_at, bad_length, bad_fix = read_string(source, pos, b)
        local token_text = sub(source, pos, stop)
        local value: string | nil = nil
        if close > 0 and bad_at == 0 then
          value = decode(sub(source, pos + 1, close - 1))
        end
        local yend, yend_start, end_y, end_x = span_end(token_text, pos, line, line_start)
        n = n + 1
        tokens[n] = {
          kind = close > 0 and bad_at == 0 and "string" or "$ERR$", text = token_text, value = value,
          offset = pos, length = stop - pos + 1, y = line, x = x, yend = end_y, xend = end_x,
          comments = pending,
        }
        pending = nil
        if close == 0 then
          local quote = b == 34 and "\"" or "'"
          add_error(errors, name, "unterminated_string", "unterminated string",
            "close the string with a matching `" .. quote .. "` before the end of its line; to carry it onto the" ..
              " next line end this line with `\\`, or write a long string `[[ ... ]]`",
            pos, stop - pos + 1, line, x)
        elseif bad_at > 0 then
          local bad_line, bad_start = advance_lines(sub(source, pos, bad_at - 1), pos, line, line_start)
          add_error(errors, name, "bad_escape",
            "invalid escape `\\" .. shown(sub(source, bad_at + 1, bad_at + bad_length - 1)) .. "`",
            bad_fix, bad_at, bad_length, bad_line, bad_at - bad_start + 1)
        end
        line, line_start = yend, yend_start
        pos = stop + 1
      end
    elseif c == 5 or (c == 9 and (byte(source, pos + 1) or 0) >= 48 and (byte(source, pos + 1) or 0) <= 57) then
      local ne = numeral_end(source, pos)
      local number_text = sub(source, pos, ne)
      local x = pos - line_start + 1
      local number_kind: Lexer.Kind = "integer"
      local value = tonumber(number_text)
      if value == nil then
        number_kind = "$ERR$"
        local stripped = number_text:gsub("_", "")
        local plain = tonumber(stripped)
        if plain ~= nil and find(number_text, "_", 1, true) then
          number_kind = math_type(plain) == "integer" and "integer" or "number"
          value = plain
          add_error(errors, name, "digit_separator", "`_` in a number is not in the grammar",
            "write the number without `_`: `" .. stripped .. "`", pos, ne - pos + 1, line, x)
        else
          add_error(errors, name, "malformed_number", "malformed number `" .. number_text .. "`", malformed_fix,
            pos, ne - pos + 1, line, x)
        end
      else
        number_kind = math_type(value) == "integer" and "integer" or "number"
        if find(number_text, "^0[xX]") and find(number_text, "[%.pP]") then
          add_error(errors, name, "hex_float", "a hexadecimal float is not in the grammar",
            hex_float_fix(value), pos, ne - pos + 1, line, x)
        end
      end
      n = n + 1
      tokens[n] = {
        kind = number_kind, text = number_text, number = value, offset = pos, length = ne - pos + 1,
        y = line, x = x, yend = line, xend = x + ne - pos, comments = pending,
      }
      pending = nil
      pos = ne + 1
    elseif c == 9 then
      if byte(source, pos + 1) == 46 then
        kind = "op"
        e = pos + 1
        if byte(source, pos + 2) == 46 then
          kind = "..."
          e = pos + 2
        end
        text = sub(source, pos, e)
      else
        kind = "."
        text = "."
      end
    elseif c == 10 then
      if byte(source, pos + 1) ~= 58 then
        kind = ":"
        text = ":"
      else
        local x = pos - line_start + 1
        local _, le, label = find(source, "^::[ \t]*([%a_][%w_]*)[ \t]*::", pos)
        e = le or pos + 1
        kind = "$ERR$"
        text = sub(source, pos, e)
        add_error(errors, name, "label_or_goto",
          label and "the label `" .. text .. "` is not in the grammar" or "`::` is not in the grammar",
          "delete the label, and write `continue` where a `goto" .. (label and " " .. label or "") ..
            "` skipped the rest of a pass of a loop; restructure any other jump with an `if` around the code to" ..
            " skip, or move the code into a function and `return` from it", pos, e - pos + 1, line, x)
      end
    elseif c == 11 then
      local _, open_end, level = find(source, "^%[(=*)%[", pos)
      if not open_end then
        kind = "["
        text = "["
      else
        local x = pos - line_start + 1
        local close = "]" .. level .. "]"
        local cs, ce = find(source, close, open_end + 1, true)
        local last = ce or len
        local token_text = sub(source, pos, last)
        local yend, yend_start, end_y, end_x = span_end(token_text, pos, line, line_start)
        local value: string | nil = nil
        if cs then
          local contents = sub(source, open_end + 1 + break_at(source, open_end + 1), cs - 1)
          if find(contents, "\r", 1, true) then
            contents = normalised(contents)
          end
          value = contents
        else
          add_error(errors, name, "unterminated_long_string", "unterminated long string",
            "close the string with `" .. close .. "`", pos, last - pos + 1, line, x)
        end
        n = n + 1
        tokens[n] = {
          kind = cs and "string" or "$ERR$", text = token_text, value = value, long = cs and true or nil,
          offset = pos, length = last - pos + 1, y = line, x = x, yend = end_y, xend = end_x,
          comments = pending,
        }
        pending = nil
        line, line_start = yend, yend_start
        pos = last + 1
      end
    else
      -- A cut `;`, or a byte that begins no token.
      if b >= 128 then
        local _, he = find(source, "^[\128-\255]+", pos)
        e = he
      end
      kind = "$ERR$"
      text = sub(source, pos, e)
      local x = pos - line_start + 1
      if b == 59 then
        add_error(errors, name, "semicolon", "`;` is not in the grammar",
          "delete the `;`: a statement needs no terminator and the fields of a table are separated by `,`",
          pos, 1, line, x)
      else
        local fix = "delete it; a character outside Lua's syntax can stand only inside a string or a comment"
        if b == 33 then
          fix = byte(source, pos + 1) == 61 and "write `~=` for \"not equal\"" or "write `not` for negation"
        elseif b >= 128 then
          if text == "\239\187\191" then
            fix = pos == 1 and "delete the byte order mark at the start of the file" or
              "delete the byte order mark; one marks the start of a file and is no part of a program"
          else
            fix = "names are ASCII letters, digits and `_`; a character like this can stand only inside a " ..
              "string or a comment"
          end
        end
        local what = "`" .. shown(text) .. "`"
        if text == "`" then
          what = "backtick"
        elseif text == "\239\187\191" then
          what = "byte order mark"
        end
        add_error(errors, name, "stray_byte", "stray " .. what, fix, pos, e - pos + 1, line, x)
      end
    end
    if kind ~= nil then
      n = n + 1
      local x = pos - line_start + 1
      local token: Lexer.Token = {
        kind = kind, text = text, offset = pos, length = e - pos + 1,
        y = line, x = x, yend = line, xend = x + e - pos,
      }
      if pending then
        token.comments = pending
        pending = nil
      end
      tokens[n] = token
      pos = e + 1
    end
  end

  local x = pos - line_start + 1
  tokens[n + 1] = {
    kind = "$EOF$", text = "", offset = pos, length = 0, y = line, x = x, yend = line, xend = x - 1,
    comments = pending,
  }
  return { tokens = tokens, errors = errors }
end

Lexer.reserved = reserved_set
Lexer.codes = {
  "label_or_goto", "semicolon", "long_comment", "unterminated_long_comment", "hashbang",
  "digit_separator", "hex_float", "malformed_number", "unterminated_string",
  "unterminated_long_string", "bad_escape", "stray_byte",
}
Lexer.added = added_words
Lexer.declaration_words = { "record", "interface", "class", "enum", "type" }

return Lexer
