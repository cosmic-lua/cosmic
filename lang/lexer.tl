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
--- grammar cuts (a label, a `;`, a long comment, a `_` in a
--- number, a hexadecimal float) is refused the same way. A cut form that has
--- a token of its own meaning (a long comment, a number) keeps that token and
--- gains an error. A cut form that has none (a label, a `;`) is
--- an `$ERR$` token. A `#!` first line is skipped, as Lua skips it: it is
--- no token and no error. A `goto` is a `keyword` token like any reserved
--- word, and [`lang.parser`] refuses the statement.
---
--- The tokens and the comments between them hold every byte of the source
--- but whitespace: a token's `offset` and length and a comment's say where
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
--- catalogues the codes, with the parser's and the checker's beside it
--- ([`build.error_catalog`]).
---
--- The core never calls `setlocale`, so `%w` in the patterns below is ASCII.
local find, byte, sub, capture, concat = string.find, string.byte, string.sub, string.match, table.concat
local math_type = math.type

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

  --- What an error is, so that a reader does not parse its `msg`. Every code
  --- is a lexical error and sets the fields of [`Error`].
  enum Code
    -- a label `::name::` (the parser refuses a `goto`)
    "label_or_goto"
    -- a `;`
    "semicolon"
    -- a long comment `--[[ ... ]]`
    "long_comment"
    -- a long comment with no closing bracket: the token runs to the end
    "unterminated_long_comment"
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

  --- One token, as [`Lexer.token`] copies it out of [`Tokens`]. The
  --- positions are those of its first and last byte; for the `$EOF$` token,
  --- which is empty, `xend` is `x - 1`.
  record Token
    kind: Kind
    --- The source bytes of the token, exactly. A string token holds its
    --- quotes and a long string its brackets.
    text: string
    --- A string's contents, escapes decoded and, for a long string, without
    --- the line break after its opening bracket. Nil for any other token.
    value: string?
    --- A number's value. Nil for any other token.
    number: number?
    --- True for a long string; nil for any other token, a short string
    --- among them.
    long: boolean?
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
    comments: {Comment}?
  end

  --- The tokens of a source, in source order, the last an `$EOF$`: parallel
  --- arrays indexed by token number, not a table for each token, because a
  --- tree has millions of tokens. `kind`, `text`, `offset` and `y` hold every
  --- token, and a reader that goes over the tokens reads them as arrays. One
  --- that looks at a token here and there asks [`Lexer.kind`], [`Lexer.text`],
  --- [`Lexer.offset`], [`Lexer.y`] and the functions beside them, which answer
  --- what an array read cannot: a value that is there. A field a token seldom
  --- has is a map from the token number, and is read through the function
  --- that answers its absence ([`Lexer.yend`], [`Lexer.xend`],
  --- [`Lexer.long`]). A column is derived ([`Lexer.x`]). [`Lexer.token`]
  --- copies one token out as a [`Token`].
  record Tokens
    kind: mut {Kind}
    --- The source bytes of the token, exactly. A string token holds its
    --- quotes and a long string its brackets. The length of a token is the
    --- length of its text.
    text: mut {string}
    --- The byte offset of the first byte, from 1.
    offset: mut {integer}
    --- The line, from 1, of the first byte.
    y: mut {integer}
    --- The offset of the first byte of each line, by line number.
    line: mut {integer}
    --- Where the last byte is, for a token whose last byte is not on its line
    --- (`yend`) or not at its column plus the length minus one (`xend`). Use
    --- [`Lexer.yend`] and [`Lexer.xend`].
    yend: mut {integer: integer}
    xend: mut {integer: integer}
    --- A string's contents, escapes decoded and, for a long string, without
    --- the line break after its opening bracket. Absent for any other token.
    value: mut {integer: string}
    --- A number's value. Absent for any other token and for a number Lua
    --- cannot read.
    number: mut {integer: number}
    --- The comments before the token, in source order. Absent where there
    --- are none.
    comments: mut {integer: {Comment}}
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
  --- answers one (build.syntax_contracts).
  record Lexed
    --- Every token in source order, the last an `$EOF$`.
    tokens: Tokens
    --- Every error in source order.
    errors: {Error}
  end

  --- Lexes `source`, which is named `name` in each error. A program and a
  --- declaration file (`.d.tl`) lex alike.
  lex: function(source: string, name: string): Lexed

  --- How many tokens there are, the `$EOF$` among them.
  count: function(tokens: Tokens): integer

  --- The kind of token `i`, which is there: asking for another raises an error.
  kind: function(tokens: Tokens, i: integer): Kind

  --- The source bytes of token `i`, which is there.
  text: function(tokens: Tokens, i: integer): string

  --- The offset of the first byte of token `i`, which is there.
  offset: function(tokens: Tokens, i: integer): integer

  --- The line of the first byte of token `i`, which is there.
  y: function(tokens: Tokens, i: integer): integer

  --- The column, from 1, of the first byte of token `i`, which is there.
  x: function(tokens: Tokens, i: integer): integer

  --- The length in bytes of token `i`, which is there.
  length: function(tokens: Tokens, i: integer): integer

  --- The offset one past the last byte of token `i`, which is there.
  stop: function(tokens: Tokens, i: integer): integer

  --- The line of the last byte of token `i`, which is there.
  yend: function(tokens: Tokens, i: integer): integer

  --- The column of the last byte of token `i`, which is there.
  xend: function(tokens: Tokens, i: integer): integer

  --- Whether token `i` is a long string.
  long: function(tokens: Tokens, i: integer): boolean

  --- Token `i`, which is there, as a table of its own. It costs a table, so a
  --- reader that looks at every token reads the arrays of [`Tokens`] instead.
  token: function(tokens: Tokens, i: integer): Token

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

end

local type Tokens = Lexer.Tokens

local lua_words: {string} = {
  "and", "break", "do", "else", "elseif", "end", "false", "for", "function",
  "global", "goto", "if", "in", "local", "nil", "not", "or", "repeat",
  "return", "then", "true", "until", "while",
}

local added_words: {string} = { "match", "continue", "mut", "is", "asserts", "userdata", "as" }

local words: mut {string: boolean} = {}
for _, w in ipairs(lua_words) do
  words[w] = true
end
for _, w in ipairs(added_words) do
  words[w] = true
end

local reserved_set: mut {string: boolean} = {}
for w in pairs(words) do
  reserved_set[w] = true
end

-- What a byte begins: a name (1), a blank (2), a line break (3), a token of
-- one byte (4), a digit (5), a quote (6), an operator of one byte or two
-- (7), `-` (8), `.` (9), `:` (10) or `[` (11). Any other byte is looked at
-- singly.
local class: mut {integer: integer} = {}
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
local one_text: mut {integer: string} = {}
local one_kind: mut {integer: Lexer.Kind} = {}
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

local function add_error(errors: mut {Lexer.Error}, name: string, code: Lexer.Code,
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
  local hex: mut {string} = {}
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
--- line before it. The offset of each line that begins in `text` is entered
--- in `tokens.line`. It reads the token's own bytes only, so a long line costs
--- what it holds.
local function advance_lines(tokens: Tokens, text: string, base: integer, line: integer,
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
    tokens.line[#tokens.line + 1] = line_start
  end
end

--- What a token of several lines, whose bytes are `text` from offset `base`
--- and which begins on `line` at `line_start`, leaves the lexer at: the line
--- and the offset of the line that follows it, and the place of its last
--- byte (which is on the line before when it is a line break).
local function span_end(tokens: Tokens, text: string, base: integer, line: integer,
                        line_start: integer): integer, integer, integer, integer
  local yend, yend_start, previous = advance_lines(tokens, text, base, line, line_start)
  local last = base + #text - 1
  if yend_start == last + 1 then
    return yend, yend_start, yend - 1, last - previous + 1
  end
  return yend, yend_start, yend, last - yend_start + 1
end

--- `text` with each line break written `\n`.
local function normalised(text: string): string
  local out: mut {string} = {}
  local p = 1
  while true do
    local q = find(text, "[\r\n]", p)
    if not q then
      local rest = sub(text, p)
      out[#out + 1] = rest
      return concat(out)
    end
    local line = sub(text, p, q - 1)
    out[#out + 1] = line
    out[#out + 1] = "\n"
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

--- The last byte of the run that `pattern` (anchored, and one a run of nothing satisfies) matches at `init` of `source`:
--- `init - 1` for no byte at all, which is also where a match of nothing ends.
local function run_end(source: string, pattern: string, init: integer): integer
  local _, e = find(source, pattern, init)
  if e == nil then
    return init - 1
  end
  return e
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
    return run_end(source, "^[ \t\r\n\v\f]*", s + 2), ""
  elseif c == byte("x") then
    if find(source, "^%x%x", s + 2) then
      return s + 3, ""
    end
    return run_end(source, "^%x?", s + 2), "`\\x` takes exactly two hexadecimal digits: write `\\x41` for `A`"
  elseif c >= 48 and c <= 57 then
    local e = run_end(source, "^%d%d?%d?", s + 1)
    if assert(tonumber(sub(source, s + 1, e))) > 255 then
      return e, "a decimal escape is at most `\\255`: write a character past 255 as `\\u{...}`, as `\\u{100}`"
    end
    return e, ""
  elseif c == byte("u") then
    local _, e, digits = find(source, "^{(%x+)}", s + 2)
    if e ~= nil and digits ~= nil then
      local significant = digits:gsub("^0+", "")
      if #significant <= 8 and (significant == "" or assert(tonumber(significant, 16)) <= 0x7FFFFFFF) then
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
  local pattern = if quote == 34 then "[\"\\\r\n]" else "['\\\r\n]" end
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
  local out: mut {string} = {}
  local i = 1
  while true do
    local s = find(inner, "\\", i, true)
    if not s then
      out[#out + 1] = sub(inner, i)
      break
    end
    if s > i then
      out[#out + 1] = sub(inner, i, s - 1)
    end
    local c = byte(inner, s + 1)
    local text: string
    local e = s + 1
    local plain = simple_escape[c]
    if plain ~= nil then
      text = plain
    elseif c == NEWLINE or c == CARRIAGE_RETURN then
      text = "\n"
      e = s + break_at(inner, s + 1)
    elseif c == byte("z") then
      text = ""
      e = run_end(inner, "^[ \t\r\n\v\f]*", s + 2)
    elseif c == byte("x") then
      text = string.char(assert(math.tointeger(assert(tonumber(sub(inner, s + 2, s + 3), 16)))))
      e = s + 3
    elseif c == byte("u") then
      local _, ue, digits = find(inner, "^{(%x+)}", s + 2)
      assert(ue ~= nil and digits ~= nil, "a good `\\u` escape has braces")
      text = utf8.char(assert(math.tointeger(assert(tonumber(digits, 16)))))
      e = ue
    else
      local de = run_end(inner, "^%d%d?%d?", s + 1)
      text = string.char(assert(math.tointeger(assert(tonumber(sub(inner, s + 1, de))))))
      e = de
    end
    out[#out + 1] = text
    i = e + 1
  end
  return concat(out)
end

--- The last byte of the numeral that begins at `pos`, read as Lua reads one:
--- digits, hexadecimal digits, dots and `_`, an exponent with its sign, and then
--- the letters and `_` that make it malformed.
local function numeral_end(source: string, pos: integer): integer
  local hex = byte(source, pos) == 48 and (byte(source, pos + 1) == 120 or byte(source, pos + 1) == 88)
  local i = if hex then pos + 2 else pos end
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
  return run_end(source, "^[%w_]*", i)
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

local malformed_fix <const> = "write decimal digits with an optional fraction and exponent (`12`, `1.5`, `2e10`) " ..
  "or `0x` and hexadecimal digits (`0xFF`), and put a space between a number and the name or operator after it"

--- Records where the last byte of token `n` is, when that is not where its
--- line and length put it: a token that spans lines, or ends in a line break.
local function mark_end(tokens: Tokens, n: integer, y: integer, x: integer, length: integer,
                        end_y: integer, end_x: integer)
  if end_y ~= y then
    tokens.yend[n] = end_y
  end
  if end_x ~= x + length - 1 then
    tokens.xend[n] = end_x
  end
end

function Lexer.lex(source: string, name: string): Lexer.Lexed
  local tokens: Tokens = {
    kind = {}, text = {}, offset = {}, y = {}, line = {}, yend = {}, xend = {}, value = {}, number = {}, comments = {},
  }
  local kinds, texts, offsets, ys = tokens.kind, tokens.text, tokens.offset, tokens.y
  local line_offsets, values, comments_at = tokens.line, tokens.value, tokens.comments
  tokens.line[#tokens.line + 1] = 1
  local errors: {Lexer.Error} = {}
  local n = 0
  local len = #source
  local pos = 1
  local line = 1
  local line_start = 1
  local pending: {Lexer.Comment}? = nil

  -- A `#!` first line is the shell's, for a script run by its own name (`#!/usr/bin/env cosmic`), as Lua skips it: it is no
  -- token and no comment, and its line break is read as any other, so every later token keeps its line.
  if sub(source, 1, 2) == "#!" then
    pos = (find(source, "[\r\n]", 3) or len + 1)
  end
  -- A byte order mark is refused (`stray_byte`) and is a token of its own, as anywhere; where a `#!` line follows it,
  -- that line is skipped too, as Lua's loader skips a mark and then the line, so the one error is not followed by a
  -- cascade for the line's bytes. `shebang_after` is the offset the mark's token ends before.
  local shebang_after = if sub(source, 1, 5) == "\239\187\191#!" then 4 else 0 end

  -- Each branch that reads a token gives its `kind`, its `text` and the offset `e` of its last byte, and the foot of
  -- the loop makes the token. What only some tokens carry is entered here, under the number of the token to come.
  while pos <= len do
    local b = byte(source, pos)
    local c = class[b]
    local first_line = line
    local kind: Lexer.Kind? = nil
    local text = ""
    local e = pos
    if c == 1 then
      local word = capture(source, "^[%a_][%w_]*", pos)
      assert(word ~= nil, "an identifier begins at a byte of class 1")
      text = word
      e = pos + #text - 1
      kind = if words[text] == true then "keyword" else "identifier" end
    elseif c == 2 then
      pos = pos + 1
      if class[byte(source, pos)] == 2 then
        pos = find(source, "[^ \t\v\f]", pos + 1) or len + 1
      end
    elseif c == 4 then
      kind = one_kind[b]
      local fixed = one_text[b]
      if fixed ~= nil then
        text = fixed
      end
    elseif c == 3 then
      line = line + 1
      pos = pos + break_at(source, pos)
      line_start = pos
      line_offsets[#line_offsets + 1] = pos
    elseif c == 7 then
      kind = "op"
      local follows = second[b]
      if follows ~= nil and follows[byte(source, pos + 1)] == true then
        e = pos + 1
        text = sub(source, pos, e)
      else
        local fixed = one_text[b]
        if fixed ~= nil then
          text = fixed
        end
      end
    elseif c == 8 and byte(source, pos + 1) ~= 45 then
      kind = "op"
      text = "-"
    elseif c == 8 then
      -- `--`: a line comment, or a long one the grammar cuts.
      local x = pos - line_start + 1
      local _, open_end, level = find(source, "^%[(=*)%[", pos + 2)
      if open_end ~= nil and level ~= nil then
        local close = "]" .. level .. "]"
        local cs, ce = find(source, close, open_end + 1, true)
        if cs == nil or ce == nil then
          local text_to_end = sub(source, pos)
          local yend, yend_start, end_y, end_x = span_end(tokens, text_to_end, pos, line, line_start)
          kind = "$ERR$"
          text = text_to_end
          e = len
          mark_end(tokens, n + 1, line, x, len - pos + 1, end_y, end_x)
          add_error(errors, name, "unterminated_long_comment", "unfinished long comment",
            "write line comments, which begin each line with `--`; a long comment is not in the grammar" ..
              " and this one has no closing `" .. close .. "`", pos, len - pos + 1, line, x)
          line, line_start = yend, yend_start
        else
          local comment_text = sub(source, pos, ce)
          local comments = pending or {}
          comments[#comments + 1] = {
            text = comment_text, offset = pos, length = ce - pos + 1, y = line, x = x,
          }
          pending = comments
          add_error(errors, name, "long_comment", "long comments are not in the grammar",
            "write line comments: begin each line of the comment with `--`", pos, ce - pos + 1, line, x)
          line, line_start = advance_lines(tokens, comment_text, pos, line, line_start)
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
      local s = find(source, if b == 34 then "[\"\\\r\n]" else "['\\\r\n]" end, pos + 1)
      if s and byte(source, s) == b then
        -- No escape and no line break: the common string, on one line.
        kind = "string"
        text = sub(source, pos, s)
        e = s
        tokens.value[n + 1] = sub(source, pos + 1, s - 1)
      else
        local close, stop, bad_at, bad_length, bad_fix = read_string(source, pos, b)
        local token_text = sub(source, pos, stop)
        local value: string? = nil
        if close > 0 and bad_at == 0 then
          value = decode(sub(source, pos + 1, close - 1))
        end
        local yend, yend_start, end_y, end_x = span_end(tokens, token_text, pos, line, line_start)
        kind = if close > 0 and bad_at == 0 then "string" else "$ERR$" end
        text = token_text
        e = stop
        if value ~= nil then
          values[n + 1] = value
        end
        mark_end(tokens, n + 1, line, x, stop - pos + 1, end_y, end_x)
        if close == 0 then
          local quote = if b == 34 then "\"" else "'" end
          add_error(errors, name, "unterminated_string", "unterminated string",
            "close the string with a matching `" .. quote .. "` before the end of its line; to carry it onto the" ..
              " next line end this line with `\\`, or write a long string `[[ ... ]]`",
            pos, stop - pos + 1, line, x)
        elseif bad_at > 0 then
          -- The lines the token has are entered by now: the one the bad escape is on is the last that begins before it.
          local bad_line, bad_start = line, line_start
          while true do
            local following = line_offsets[bad_line + 1]
            if following == nil or following > bad_at then
              break
            end
            bad_line, bad_start = bad_line + 1, following
          end
          add_error(errors, name, "bad_escape",
            "invalid escape `\\" .. shown(sub(source, bad_at + 1, bad_at + bad_length - 1)) .. "`",
            bad_fix, bad_at, bad_length, bad_line, bad_at - bad_start + 1)
        end
        line, line_start = yend, yend_start
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
        if plain ~= nil and find(number_text, "_", 1, true) ~= nil then
          number_kind = if math_type(plain) == "integer" then "integer" else "number" end
          value = plain
          add_error(errors, name, "digit_separator", "`_` in a number is not in the grammar",
            "write the number without `_`: `" .. stripped .. "`", pos, ne - pos + 1, line, x)
        else
          add_error(errors, name, "malformed_number", "malformed number `" .. number_text .. "`", malformed_fix,
            pos, ne - pos + 1, line, x)
        end
      else
        number_kind = if math_type(value) == "integer" then "integer" else "number" end
        if find(number_text, "^0[xX]") and find(number_text, "[%.pP]") then
          add_error(errors, name, "hex_float", "a hexadecimal float is not in the grammar",
            hex_float_fix(value), pos, ne - pos + 1, line, x)
        end
      end
      kind = number_kind
      text = number_text
      e = ne
      if value ~= nil then
        tokens.number[n + 1] = value
      end
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
          if label then "the label `" .. text .. "` is not in the grammar" else "`::` is not in the grammar" end,
          "delete the label, and write `continue` where a `goto" .. (if label then " " .. label else "" end) ..
            "` skipped the rest of a pass of a loop; restructure any other jump with an `if` around the code to" ..
            " skip, or move the code into a function and `return` from it", pos, e - pos + 1, line, x)
      end
    elseif c == 11 then
      local _, open_end, level = find(source, "^%[(=*)%[", pos)
      if open_end == nil or level == nil then
        kind = "["
        text = "["
      else
        local x = pos - line_start + 1
        local close = "]" .. level .. "]"
        local cs, ce = find(source, close, open_end + 1, true)
        local last = ce or len
        local token_text = sub(source, pos, last)
        local yend, yend_start, end_y, end_x = span_end(tokens, token_text, pos, line, line_start)
        local value: string? = nil
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
        kind = if cs then "string" else "$ERR$" end
        text = token_text
        e = last
        if value ~= nil then
          values[n + 1] = value
        end
        mark_end(tokens, n + 1, line, x, last - pos + 1, end_y, end_x)
        line, line_start = yend, yend_start
      end
    else
      -- A cut `;`, or a byte that begins no token.
      if b >= 128 then
        e = run_end(source, "^[\128-\255]+", pos)
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
          fix = if byte(source, pos + 1) == 61 then "write `~=` for \"not equal\"" else "write `not` for negation" end
        elseif b >= 128 then
          if text == "\239\187\191" then
            fix = if pos == 1 then "delete the byte order mark at the start of the file" else
              "delete the byte order mark; one marks the start of a file and is no part of a program" end
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
      kinds[#kinds + 1], texts[#texts + 1], offsets[#offsets + 1], ys[#ys + 1] = kind, text, pos, first_line
      if pending ~= nil then
        comments_at[n] = pending
        pending = nil
      end
      pos = e + 1
      if pos == shebang_after then
        pos = (find(source, "[\r\n]", pos + 2) or len + 1)
      end
    end
  end

  n = n + 1
  tokens.kind[#tokens.kind + 1], tokens.text[#tokens.text + 1] = "$EOF$", ""
  tokens.offset[#tokens.offset + 1], tokens.y[#tokens.y + 1] = pos, line
  if pending ~= nil then
    tokens.comments[n] = pending
  end
  return { tokens = tokens, errors = errors }
end

function Lexer.count(tokens: Lexer.Tokens): integer
  return #tokens.kind
end

function Lexer.kind(tokens: Lexer.Tokens, i: integer): Lexer.Kind
  local kind = tokens.kind[i]
  if kind == nil then
    error("there is no token " .. tostring(i), 2)
  end
  return kind
end

function Lexer.text(tokens: Lexer.Tokens, i: integer): string
  local text = tokens.text[i]
  if text == nil then
    error("there is no token " .. tostring(i), 2)
  end
  return text
end

function Lexer.offset(tokens: Lexer.Tokens, i: integer): integer
  local offset = tokens.offset[i]
  if offset == nil then
    error("there is no token " .. tostring(i), 2)
  end
  return offset
end

function Lexer.y(tokens: Lexer.Tokens, i: integer): integer
  local y = tokens.y[i]
  if y == nil then
    error("there is no token " .. tostring(i), 2)
  end
  return y
end

function Lexer.x(tokens: Lexer.Tokens, i: integer): integer
  local offset, y = tokens.offset[i], tokens.y[i]
  if offset == nil or y == nil then
    error("there is no token " .. tostring(i), 2)
  end
  local first = tokens.line[y]
  if first == nil then
    error("there is no line " .. tostring(y), 2)
  end
  return offset - first + 1
end

function Lexer.length(tokens: Lexer.Tokens, i: integer): integer
  local text = tokens.text[i]
  if text == nil then
    error("there is no token " .. tostring(i), 2)
  end
  return #text
end

function Lexer.stop(tokens: Lexer.Tokens, i: integer): integer
  local offset, text = tokens.offset[i], tokens.text[i]
  if offset == nil or text == nil then
    error("there is no token " .. tostring(i), 2)
  end
  return offset + #text
end

function Lexer.yend(tokens: Lexer.Tokens, i: integer): integer
  local y = tokens.y[i]
  if y == nil then
    error("there is no token " .. tostring(i), 2)
  end
  return tokens.yend[i] or y
end

function Lexer.xend(tokens: Lexer.Tokens, i: integer): integer
  local offset, y, text = tokens.offset[i], tokens.y[i], tokens.text[i]
  if offset == nil or y == nil or text == nil then
    error("there is no token " .. tostring(i), 2)
  end
  local first = tokens.line[y]
  if first == nil then
    error("there is no line " .. tostring(y), 2)
  end
  return tokens.xend[i] or offset - first + #text
end

function Lexer.long(tokens: Lexer.Tokens, i: integer): boolean
  local kind, text = tokens.kind[i], tokens.text[i]
  if kind == nil or text == nil then
    error("there is no token " .. tostring(i), 2)
  end
  -- A long string begins with a bracket and a short one with a quote, which sorts before it.
  return kind == "string" and text >= "["
end

function Lexer.token(tokens: Lexer.Tokens, i: integer): Lexer.Token
  local kind, text, offset, y = tokens.kind[i], tokens.text[i], tokens.offset[i], tokens.y[i]
  if kind == nil or text == nil or offset == nil or y == nil then
    error("there is no token " .. tostring(i), 2)
  end
  local first = tokens.line[y]
  if first == nil then
    error("there is no line " .. tostring(y), 2)
  end
  local x = offset - first + 1
  local long: boolean? = nil
  if kind == "string" and text >= "[" then
    long = true
  end
  return {
    kind = kind, text = text, value = tokens.value[i], number = tokens.number[i], long = long, offset = offset,
    length = #text, y = y, x = x, yend = tokens.yend[i] or y, xend = tokens.xend[i] or x + #text - 1,
    comments = tokens.comments[i],
  }
end

Lexer.reserved = reserved_set
Lexer.codes = {
  "label_or_goto", "semicolon", "long_comment", "unterminated_long_comment",
  "digit_separator", "hex_float", "malformed_number", "unterminated_string",
  "unterminated_long_string", "bad_escape", "stray_byte",
}
Lexer.added = added_words
Lexer.declaration_words = { "record", "interface", "class", "enum", "type" }

return Lexer
