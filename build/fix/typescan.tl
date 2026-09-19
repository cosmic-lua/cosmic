--- Where a type ENDS, in the token stream tl already lexed.
---
--- tl's AST carries a type annotation as a semantic type OBJECT rather
--- than as a node: it has a start position and no end, no memory of how
--- the source spelled it, and -- for a record or enum body -- no trace
--- of the comments written between its fields. Re-rendering one from
--- that object would mean reinventing the whole type grammar and losing
--- those comments, so `build.fix` writes type syntax out as the
--- original bytes instead. This module is what says where those bytes
--- stop.
---
--- Two ways to find the end, and the renderer prefers the first
--- wherever it has one: a BOUND, some later position the AST already
--- knows (the next argument's own name, the `)` an argument list
--- records as its `xend`, the first token of a function's body), which
--- makes the answer "the last token before that"; or, where the AST
--- knows no such position -- a cast's type, a declaration's type list
--- with no initialiser after it -- a walk over the tokens themselves
--- following the shape of Teal's type syntax. The walk only has to find
--- the closing token, never to understand the type, so it tracks
--- brackets and the handful of tokens that continue a type rather than
--- parsing one.

local type compiler = require("build.compiler")

local record Scan
  tokens: {compiler.Token}
  --- "y:x" of every token's start, to its index in `tokens`.
  at: {string:integer}
end

--- An index over one parse's tokens, so a type object's start position
--- becomes a token index.
--- @param tokens {compiler.Token} The token stream from the parse being rendered
--- @return Scan
local function new(tokens: {compiler.Token}): Scan
  local at: {string:integer} = {}
  for i, t in ipairs(tokens) do
    at[t.y .. ":" .. t.x] = i
  end
  return { tokens = tokens, at = at }
end

--- The index of the token that starts at exactly (`y`, `x`), or nil
--- when no token does -- a type object whose position the parser
--- synthesized rather than read off the source.
--- @param s Scan
--- @param y integer
--- @param x integer
--- @return integer|nil
local function index_at(s: Scan, y: integer, x: integer): integer | nil
  return s.at[y .. ":" .. x]
end

--- Whether (`ay`, `ax`) comes before (`by`, `bx`) in the source.
local function before(ay: integer, ax: integer, by: integer, bx: integer): boolean
  return ay < by or (ay == by and ax < bx)
end

--- The index of the last token that starts strictly before (`y`, `x`).
--- The stream is in source order, so this is a bisection.
--- @param s Scan
--- @param y integer
--- @param x integer
--- @return integer 0 when every token is at or after that position
local function index_before(s: Scan, y: integer, x: integer): integer
  local lo, hi = 1, #s.tokens
  local found = 0
  while lo <= hi do
    local mid = (lo + hi) // 2
    local t = s.tokens[mid]
    if before(t.y, t.x, y, x) then
      found = mid
      lo = mid + 1
    else
      hi = mid - 1
    end
  end
  return found
end

--- The text of token `i`, or "" past the end of the stream.
local function tk(s: Scan, i: integer): string
  local t = s.tokens[i]
  return t ~= nil and t.tk or ""
end

--- The inclusive last position token `i` occupies.
--- @param s Scan
--- @param i integer
--- @return integer The 1-based line
--- @return integer The 1-based column
local function ends_at(s: Scan, i: integer): integer, integer
  local t = s.tokens[i]
  return t.y, t.x + #t.tk - 1
end

--- Whether `text` is an ordinary identifier, which is all this module
--- needs to know to follow a dotted type name.
local function is_name(text: string): boolean
  return text:match("^[A-Za-z_][A-Za-z0-9_]*$") ~= nil
end

--- The index of the bracket closing the one token `i` opens.
local function closing(s: Scan, i: integer): integer
  local depth = 0
  local j = i
  while j <= #s.tokens do
    local text = tk(s, j)
    if text == "(" or text == "{" or text == "[" then
      depth = depth + 1
    elseif text == ")" or text == "}" or text == "]" then
      depth = depth - 1
      if depth == 0 then
        return j
      end
    end
    j = j + 1
  end
  return #s.tokens
end

--- The index of the `>` closing the type-argument list token `i` opens.
--- `>>` closes two at once, which is how tl's own lexer hands back a
--- nested `T<U<V>>`.
local function closing_angle(s: Scan, i: integer): integer
  local depth = 0
  local j = i
  while j <= #s.tokens do
    local text = tk(s, j)
    if text == "<" then
      depth = depth + 1
    elseif text == ">" then
      depth = depth - 1
      if depth <= 0 then
        return j
      end
    elseif text == ">>" then
      depth = depth - 2
      if depth <= 0 then
        return j
      end
    end
    j = j + 1
  end
  return #s.tokens
end

local type_end: function(Scan, integer): integer
local rets_end: function(Scan, integer): integer

--- The end of one type with no `|` alternatives after it.
local function single_end(s: Scan, i: integer): integer
  local text = tk(s, i)
  if text == "{" or text == "(" then
    return closing(s, i)
  end
  if text == "function" then
    local j = i + 1
    if tk(s, j) == "<" then
      j = closing_angle(s, j) + 1
    end
    if tk(s, j) ~= "(" then
      return j - 1
    end
    j = closing(s, j)
    if tk(s, j + 1) == ":" then
      return rets_end(s, j + 2)
    end
    return j
  end
  local j = i
  while tk(s, j + 1) == "." and is_name(tk(s, j + 2)) do
    j = j + 2
  end
  if tk(s, j + 1) == "<" then
    j = closing_angle(s, j + 1)
  end
  return j
end

--- The index of the last token of the type that starts at token `i`.
--- @param s Scan
--- @param i integer
--- @return integer
type_end = function(s: Scan, i: integer): integer
  local j = single_end(s, i)
  while tk(s, j + 1) == "|" do
    j = single_end(s, j + 2)
  end
  return j
end

--- The index of the last token of a comma-separated list of types
--- starting at token `i`, or of the parenthesized list it opens with.
--- A function's return types and a declaration's type list are both
--- this shape.
--- @param s Scan
--- @param i integer
--- @return integer
rets_end = function(s: Scan, i: integer): integer
  if tk(s, i) == "(" then
    return closing(s, i)
  end
  local j = type_end(s, i)
  while tk(s, j + 1) == "," do
    j = type_end(s, j + 2)
  end
  return j
end

--- The index of the first token spelled `word` at or after `i`, outside
--- any bracket opened after `i`. Used for the keywords the AST records
--- no position for at all -- the `then` closing a condition, the `do`
--- opening a loop's body -- so a source that put one on a line of its
--- own keeps it there.
--- @param s Scan
--- @param i integer
--- @param word string
--- @return integer 0 when no such token follows
local function word_after(s: Scan, i: integer, word: string): integer
  local depth = 0
  local j = i
  while j <= #s.tokens do
    local text = tk(s, j)
    if text == "(" or text == "{" or text == "[" then
      depth = depth + 1
    elseif text == ")" or text == "}" or text == "]" then
      depth = depth - 1
    elseif depth == 0 and text == word then
      return j
    end
    j = j + 1
  end
  return 0
end

--- The last token of a type region that ends before (`y`, `x`), with
--- any separator the bound left behind trimmed off. Used wherever the
--- AST already knows what follows the type.
--- @param s Scan
--- @param y integer The bounding position's line
--- @param x integer The bounding position's column
--- @return integer
local function bounded_end(s: Scan, y: integer, x: integer): integer
  local j = index_before(s, y, x)
  while j > 0 and (tk(s, j) == "," or tk(s, j) == ";") do
    j = j - 1
  end
  return j
end

local record TypescanModule
  type Scan = Scan
  new: function(tokens: {compiler.Token}): Scan
  index_at: function(s: Scan, y: integer, x: integer): integer | nil
  index_before: function(s: Scan, y: integer, x: integer): integer
  bounded_end: function(s: Scan, y: integer, x: integer): integer
  type_end: function(s: Scan, i: integer): integer
  rets_end: function(s: Scan, i: integer): integer
  closing: function(s: Scan, i: integer): integer
  closing_angle: function(s: Scan, i: integer): integer
  word_after: function(s: Scan, i: integer, word: string): integer
  ends_at: function(s: Scan, i: integer): integer, integer
  tk: function(s: Scan, i: integer): string
end

local M: TypescanModule = {
  new = new,
  index_at = index_at,
  index_before = index_before,
  bounded_end = bounded_end,
  type_end = type_end,
  rets_end = rets_end,
  closing = closing,
  closing_angle = closing_angle,
  word_after = word_after,
  ends_at = ends_at,
  tk = tk,
}

return M
