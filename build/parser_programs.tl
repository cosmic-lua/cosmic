--- Programs of the new grammar for the properties of the parser ([`lang.parser`]) and of the code that reads its trees: a
--- program drawn from the grammar (the tokens it is written in, or joined by spaces), the same with a few tokens
--- deleted, repeated, swapped or replaced, any run of tokens of the grammar's vocabulary, and any bytes. Every generator
--- draws from a [`Fuzz.Source`], so a failing input shrinks.
local Fuzz = require("build.fuzz")

local record Programs
  --- A program of the grammar, as the tokens it is written in; a token `"\n"` is a line break the grammar needs
  --- (the end of a header, or of a declaration's member).
  program: function(src: Fuzz.Source): {string}
  --- [`Programs.program`] with its tokens joined by spaces.
  valid: function(src: Fuzz.Source): string
  --- A run of tokens that make the parser meet each of its branches, well and ill placed.
  pieces: function(src: Fuzz.Source): string
  --- A program with a few of its tokens deleted, repeated, swapped or replaced.
  mutated: function(src: Fuzz.Source): string
  --- Up to a hundred bytes.
  bytes: function(src: Fuzz.Source): string
end

local NAMES <const>: {string} = { "a", "b", "c", "x", "y", "t", "f", "g", "n", "self" }
local TYPES <const>: {string} = { "string", "integer", "boolean", "any", "T", "Reader", "Stream.Reader" }
local BINARY <const>: {string} = {
  "or", "and", "<", ">", "<=", ">=", "~=", "==", "|", "~", "&", "<<", ">>", "..", "+", "-", "*", "/", "//", "%", "^",
}

--- The productions that call each other.
local record Gen
  exp: function(src: Fuzz.Source, depth: integer, out: mut {string})
  typ: function(src: Fuzz.Source, depth: integer, out: mut {string})
  block: function(src: Fuzz.Source, depth: integer, loop: boolean, out: mut {string})
end

local function name(src: Fuzz.Source): string
  return Fuzz.pick(src, NAMES)
end

local function add(out: mut {string}, ...: string)
  for _, piece in ipairs({ ... }) do
    out[#out + 1] = piece
  end
end

--- Between one and `max` of what `item` writes, separated by `,`.
local function gen_list(src: Fuzz.Source, max: integer, out: mut {string}, item: function(i: integer))
  local n = 0
  while n == 0 or Fuzz.more(src, n, max) do
    if n > 0 then add(out, ",") end
    n = n + 1
    item(n)
  end
end

--- Writes a type that is not a union or an optional. Answers whether `?` and `|` may follow it: a
--- function type takes them into its return list.
local function gen_base_type(src: Fuzz.Source, depth: integer, out: mut {string}): boolean
  local k = src:int(1, if depth > 0 then 9 else 3 end)
  if k <= 3 then
    add(out, Fuzz.pick(src, TYPES))
  elseif k == 4 then
    add(out, Fuzz.pick(src, TYPES), "<")
    gen_list(src, 3, out, function(_: integer) Gen.typ(src, depth - 1, out) end)
    add(out, ">")
  elseif k == 5 then
    add(out, "{")
    Gen.typ(src, depth - 1, out)
    add(out, "}")
  elseif k == 6 then
    add(out, "{", Fuzz.pick(src, TYPES), ":")
    Gen.typ(src, depth - 1, out)
    add(out, "}")
  elseif k == 7 then
    add(out, "mut", "{")
    Gen.typ(src, depth - 1, out)
    add(out, "}")
  elseif k == 8 then
    add(out, "function", "(")
    gen_list(src, 3, out, function(i: integer)
      local form = src:int(1, 4)
      if form == 1 then
        add(out, "p" .. tostring(i), ":")
      elseif form == 2 then
        add(out, "p" .. tostring(i), "?", ":")
      elseif form == 3 and i == 3 then
        add(out, "...", ":")
      end
      Gen.typ(src, depth - 1, out)
    end)
    add(out, ")")
    local rets = src:int(1, 5)
    if rets == 2 then
      add(out, ":")
      Gen.typ(src, depth - 1, out)
    elseif rets == 3 then
      add(out, ":", "(", "true", ",")
      Gen.typ(src, depth - 1, out)
      add(out, ")", "|", "(", "false", ",")
      Gen.typ(src, depth - 1, out)
      add(out, ")")
    elseif rets == 4 then
      add(out, ":", "(")
      gen_list(src, 2, out, function(_: integer) Gen.typ(src, depth - 1, out) end)
      add(out, ")")
    end
    return false
  else
    add(out, "(", Fuzz.pick(src, TYPES), "|", Fuzz.pick(src, TYPES), ")")
  end
  return true
end

function Gen.typ(src: Fuzz.Source, depth: integer, out: mut {string})
  if not gen_base_type(src, depth, out) then
    return
  end
  if src:int(1, 4) == 1 then
    add(out, "?")
  end
  if src:int(1, 5) == 1 then
    add(out, "|")
    gen_base_type(src, depth - 1, out)
  end
end

local function gen_args(src: Fuzz.Source, depth: integer, out: mut {string})
  add(out, "(")
  if src:int(1, 3) > 1 then
    gen_list(src, 3, out, function(_: integer) Gen.exp(src, depth - 1, out) end)
  end
  add(out, ")")
end

function Gen.exp(src: Fuzz.Source, depth: integer, out: mut {string})
  local k = src:int(1, if depth > 0 then 17 else 6 end)
  if k <= 3 then
    add(out, name(src))
  elseif k == 4 then
    add(out, if src:int(1, 2) == 1 then tostring(src:int(0, 999)) else tostring(src:int(0, 99)) .. ".5" end)
  elseif k == 5 then
    add(out, "\"s\\n\"")
  elseif k == 6 then
    add(out, Fuzz.pick(src, { "nil", "true", "false", "..." }))
  elseif k == 7 then
    Gen.exp(src, depth - 1, out)
    add(out, Fuzz.pick(src, BINARY))
    Gen.exp(src, depth - 1, out)
  elseif k == 8 then
    add(out, Fuzz.pick(src, { "not", "#", "-", "~" }))
    Gen.exp(src, depth - 1, out)
  elseif k == 9 then
    add(out, name(src))
    gen_args(src, depth, out)
  elseif k == 10 then
    add(out, name(src), ":", "m")
    gen_args(src, depth, out)
  elseif k == 11 then
    add(out, name(src), if src:int(1, 2) == 1 then "." else "[" end, "k")
    if out[#out - 1] == "[" then add(out, "]") end
  elseif k == 12 then
    add(out, "{")
    gen_list(src, 3, out, function(i: integer)
      local form = src:int(1, 3)
      if form == 1 then
        add(out, "k" .. tostring(i), "=")
      elseif form == 2 then
        add(out, "[", tostring(i), "]", "=")
      end
      Gen.exp(src, depth - 1, out)
    end)
    add(out, "}")
  elseif k == 13 then
    add(out, "function", "(", "a", ")", "\n")
    Gen.block(src, depth - 1, false, out)
    add(out, "end")
  elseif k == 14 then
    add(out, "if")
    Gen.exp(src, depth - 1, out)
    add(out, "then")
    Gen.exp(src, depth - 1, out)
    add(out, "else")
    Gen.exp(src, depth - 1, out)
    add(out, "end")
  elseif k == 15 then
    add(out, "(")
    Gen.exp(src, depth - 1, out)
    add(out, ")")
  elseif k == 16 then
    add(out, "(", name(src), "is")
    gen_base_type(src, depth - 1, out)
    add(out, ")")
  else
    add(out, "(", name(src), "as")
    Gen.typ(src, depth - 1, out)
    add(out, ")")
  end
end

local function gen_declaration(src: Fuzz.Source, depth: integer, out: mut {string})
  local k = src:int(1, 6)
  if k <= 2 then
    add(out, "local", if k == 1 then "record" else "interface" end, "R", if src:int(1, 3) == 1 then "<T>" else "" end, "\n")
    for i = 1, src:int(0, 3) do
      add(out, if src:int(1, 3) == 1 then "mut" else "" end, "f" .. tostring(i), if src:int(1, 3) == 1 then "?" else "" end, ":")
      Gen.typ(src, depth - 1, out)
      add(out, "\n")
    end
    add(out, "end")
  elseif k == 3 then
    add(out, "local", "class", "C", "\n", "mut", "count", ":", "integer", "\n")
    for i = 1, src:int(0, 2) do
      add(out, "function", "m" .. tostring(i), "(", "self", ",", "a", ":", "integer", ")", ":", "integer", "\n")
      Gen.block(src, depth - 1, false, out)
      add(out, "end", "\n")
    end
    add(out, "end")
  elseif k == 4 then
    add(out, "local", "enum", "E", "\"a\"", "\"b\"", "end")
  elseif k == 5 then
    add(out, "local", "type", "A", "=")
    Gen.typ(src, depth - 1, out)
  else
    add(out, "local", "type", "m", "=", "require", "(", "\"mod\"", ")")
  end
end

local function gen_statement(src: Fuzz.Source, depth: integer, loop: boolean, out: mut {string})
  local k = src:int(1, if depth > 0 then 17 else 4 end)
  if k == 1 then
    add(out, "local", name(src))
    if src:int(1, 3) == 1 then
      add(out, ":")
      Gen.typ(src, depth - 1, out)
    end
    add(out, "=")
    Gen.exp(src, depth, out)
  elseif k == 2 then
    add(out, name(src), "=")
    Gen.exp(src, depth, out)
  elseif k == 3 or k == 4 then
    add(out, name(src))
    gen_args(src, depth, out)
  elseif k == 5 then
    add(out, "do", "\n")
    Gen.block(src, depth - 1, loop, out)
    add(out, "end")
  elseif k == 6 then
    add(out, "if")
    Gen.exp(src, depth - 1, out)
    add(out, "then", "\n")
    Gen.block(src, depth - 1, loop, out)
    if src:int(1, 2) == 1 then
      add(out, "elseif")
      Gen.exp(src, depth - 1, out)
      add(out, "then", "\n")
      Gen.block(src, depth - 1, loop, out)
    end
    if src:int(1, 2) == 1 then
      add(out, "else", "\n")
      Gen.block(src, depth - 1, loop, out)
    end
    add(out, "end")
  elseif k == 7 then
    add(out, "while")
    Gen.exp(src, depth - 1, out)
    add(out, "do", "\n")
    Gen.block(src, depth - 1, true, out)
    add(out, "end")
  elseif k == 8 then
    add(out, "for", "i", "=", "1", ",", "n", "do", "\n")
    Gen.block(src, depth - 1, true, out)
    add(out, "end")
  elseif k == 9 then
    add(out, "for", "k", ",", "v", "in", "pairs", "(", "t", ")", "do", "\n")
    Gen.block(src, depth - 1, true, out)
    add(out, "end")
  elseif k == 10 then
    add(out, "repeat", "\n")
    Gen.block(src, depth - 1, false, out)
    add(out, "until")
    Gen.exp(src, depth - 1, out)
  elseif k == 11 then
    add(out, "local", "function", "h", "(", "a", ":", "integer", ",", "...", ":", "any", ")", ":", "integer", "\n")
    Gen.block(src, depth - 1, false, out)
    add(out, "end")
  elseif k == 12 then
    add(out, "function", "R", ".", "m", "(", "a", ")", "\n")
    Gen.block(src, depth - 1, false, out)
    add(out, "end")
  elseif k == 13 then
    add(out, "match", "f", "(", ")", "do", "\n")
    for _ = 1, src:int(1, 2) do
      add(out, "|", "(", "true", ",", "v", ")", "then", "\n")
      Gen.block(src, depth - 1, loop, out)
    end
    add(out, "end")
  elseif k == 14 and loop then
    add(out, if src:int(1, 2) == 1 then "break" else "continue" end)
  else
    gen_declaration(src, depth, out)
  end
  add(out, "\n")
end

function Gen.block(src: Fuzz.Source, depth: integer, loop: boolean, out: mut {string})
  local n = 0
  while Fuzz.more(src, n, 4) do
    n = n + 1
    gen_statement(src, depth, loop, out)
  end
  if src:int(1, 8) == 1 then
    add(out, "return")
    if src:int(1, 2) == 1 then
      Gen.exp(src, depth - 1, out)
    end
    add(out, "\n")
  end
end

--- A program of the grammar, as the tokens it is written in.
function Programs.program(src: Fuzz.Source): {string}
  local out: mut {string} = {}
  Gen.block(src, 3, false, out)
  return out
end

function Programs.valid(src: Fuzz.Source): string
  return table.concat(Programs.program(src), " ")
end

--- Tokens that make the parser meet each of its branches, well and ill placed.
local PIECES <const>: {string} = {
  "local", "function", "end", "if", "then", "else", "elseif", "while", "do", "for", "in", "repeat", "until", "return",
  "break", "continue", "match", "goto", "global", "mut", "is", "as", "userdata", "record", "interface", "class", "enum",
  "type", "require", "x", "y", "self", "T", "1", "2.5", "\"s\"", "[[l]]", "nil", "true", "false", "...", "+", "-", "*",
  "..", "==", "<", ">", ">>", "|", "?", "#", "~", "=", ",", ":", ".", "(", ")", "{", "}", "[", "]", "<const>", "\n",
  "-- c\n", "metamethod", "asserts", ";", "@", "'", "::",
}

function Programs.pieces(src: Fuzz.Source): string
  local out: mut {string} = {}
  while Fuzz.more(src, #out, 60) do
    out[#out + 1] = Fuzz.pick(src, PIECES)
  end
  return table.concat(out, " ")
end

--- A program with a few of its tokens deleted, repeated, swapped or replaced.
function Programs.mutated(src: Fuzz.Source): string
  local tokens: mut {string} = {}
  for _, token in ipairs(Programs.program(src)) do
    tokens[#tokens + 1] = token
  end
  for _ = 1, src:int(1, 3) do
    local n = #tokens
    if n > 0 then
      local at = src:int(1, n)
      local edit = src:int(1, 4)
      if edit == 1 then
        table.remove(tokens, at)
      elseif edit == 2 then
        table.insert(tokens, at, tokens[at] or "")
      elseif edit == 3 and at < n then
        table.insert(tokens, at + 1, table.remove(tokens, at) or "")
      else
        table.remove(tokens, at)
        table.insert(tokens, at, Fuzz.pick(src, PIECES))
      end
    end
  end
  return table.concat(tokens, " ")
end

function Programs.bytes(src: Fuzz.Source): string
  return Fuzz.bytes(src, 100)
end

return Programs
