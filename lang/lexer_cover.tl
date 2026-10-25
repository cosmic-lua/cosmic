--- Whether the tokens of a lexing tile their source: the check that a file
--- is written back from its tokens and comments to the same bytes
--- ([`doc/plans/new-checker-grammar.md`], "the order the grammar lands
--- in"). It holds for any source, whatever errors the lexing found.
---
--- The tokens and the comments before them, in order, hold each byte of the
--- source at the `offset` and `length` they give, with `text` equal to
--- those bytes and `y`, `x`, `yend` and `xend` naming the places of the
--- first and last byte, each a place on a line that exists and within it
--- (the last byte of a token may be one of a line break). The line table
--- holds the offset of each line of the source.
--- Between two of them lies whitespace and nothing else. The `$EOF$` token
--- is empty and at the end. An error lies within the source and carries its
--- code, its message and its fix.
local Lexer = require("lang.lexer")

local find = string.find
local byte: function(string, integer): integer? = string.byte

local record Cover
  --- Whether `lexed` tiles `source`, or `false` and the first place it does
  --- not.
  check: function(source: string, lexed: Lexer.Lexed): boolean, string
end

--- Where the lines of `source` are: the 1-based offset of the first byte of
--- each, and how many columns a place on each may have. A line break is
--- `\n`, `\r`, `\r\n` or `\n\r`, each one, as in Lua. A place may be one past
--- the line's last byte, its break not counted; the last byte of a token
--- may be a byte of the break, which an unterminated long string or comment
--- can end in, so `wide` counts those too.
local record Lines
  starts: {integer}
  columns: {integer}
  wide: {integer}
end

local function lines_of(source: string): Lines
  local starts: mut {integer} = { 1 }
  local columns: mut {integer} = {}
  local wide: mut {integer} = {}
  local n = 1
  local p = 1
  while true do
    local q = find(source, "[\r\n]", p)
    if not q then
      columns[n] = #source - p + 2
      wide[n] = #source - p + 1
      return { starts = starts, columns = columns, wide = wide }
    end
    local c, d = byte(source, q), byte(source, q + 1)
    local next_p = if (d == 10 or d == 13) and d ~= c then q + 2 else q + 1 end
    columns[n] = q - p + 1
    wide[n] = next_p - p
    p = next_p
    n = n + 1
    starts[n] = p
  end
end

local BLANK <const>: {integer: boolean} = { [32] = true, [9] = true, [10] = true, [13] = true, [11] = true, [12] = true }

--- Whether only whitespace lies in `source` from `from` to `to`.
local function blank(source: string, from: integer, to: integer): boolean
  local gap = to - from + 1
  if gap <= 0 then
    return gap == 0
  elseif gap == 1 then
    local b = byte(source, from)
    return b ~= nil and BLANK[b] == true
  end
  local _, e = find(source, "^[ \t\r\n\v\f]*", from)
  return e >= to
end

--- Whether `y`:`x` is a place of `lines` and where in the source it is, or
--- -1. `ending` allows the break bytes.
local function placed(lines: Lines, y: integer, x: integer, ending: boolean): integer
  local start = lines.starts[y]
  if start == nil or x < 1 or x > (ending and lines.wide[y] or lines.columns[y]) then
    return -1
  end
  return start + x - 1
end

function Cover.check(source: string, lexed: Lexer.Lexed): boolean, string
  local lines = lines_of(source)
  local cursor = 1
  local tokens = lexed.tokens
  local count = #tokens.kind
  if #tokens.line ~= #lines.starts then
    return false, "the line table holds " .. tostring(#tokens.line) .. " lines, the source has " .. tostring(#lines.starts)
  end
  for n, start in ipairs(lines.starts) do
    if tokens.line[n] ~= start then
      return false, "line " .. tostring(n) .. " begins at offset " .. tostring(tokens.line[n]) ..
        " in the line table, at " .. tostring(start) .. " in the source"
    end
  end
  for i = 1, count do
    local comments = tokens.comments[i]
    if comments then
      for _, comment in ipairs(comments) do
        if comment.offset < cursor or not blank(source, cursor, comment.offset - 1) then
          return false, "comment at " .. comment.y .. ":" .. comment.x .. " leaves bytes uncovered or overlaps"
        end
        if comment.length ~= #comment.text or find(source, comment.text, comment.offset, true) ~= comment.offset then
          return false, "comment at " .. comment.y .. ":" .. comment.x .. " is not the bytes it names"
        end
        if placed(lines, comment.y, comment.x, false) ~= comment.offset then
          return false, "comment at offset " .. comment.offset .. " is placed at " .. comment.y .. ":" .. comment.x
        end
        cursor = comment.offset + comment.length
      end
    end
    local offset, text, y, x = Lexer.offset(tokens, i), Lexer.text(tokens, i), Lexer.y(tokens, i), Lexer.x(tokens, i)
    local length = #text
    if offset < cursor or not blank(source, cursor, offset - 1) then
      return false, "token at " .. y .. ":" .. x .. " leaves bytes uncovered or overlaps"
    end
    if length > 0 and find(source, text, offset, true) ~= offset then
      return false, "token at " .. y .. ":" .. x .. " is not the bytes it names"
    end
    local start = lines.starts[y]
    if start == nil or x < 1 or x > lines.columns[y] or start + x - 1 ~= offset then
      return false, "token at offset " .. offset .. " is placed at " .. y .. ":" .. x
    end
    if length > 0 then
      local yend, xend = Lexer.yend(tokens, i), Lexer.xend(tokens, i)
      local right = yend == y and offset + length - 1 == start + xend - 1 and xend <= lines.wide[y]
      if not right and placed(lines, yend, xend, true) ~= offset + length - 1 then
        return false, "token at " .. y .. ":" .. x .. " ends at " .. yend .. ":" .. xend
      end
    end
    cursor = offset + length
  end
  if count == 0 or tokens.kind[count] ~= "$EOF$" or Lexer.length(tokens, count) ~= 0 or tokens.offset[count] ~= #source + 1 then
    return false, "the tokens do not end in an empty $EOF$ at the end of the source"
  end
  for _, e in ipairs(lexed.errors) do
    if e.offset < 1 or e.length < 1 or e.offset + e.length - 1 > #source then
      return false, e.code .. " error at " .. e.y .. ":" .. e.x .. " lies outside the source"
    end
    if placed(lines, e.y, e.x, false) ~= e.offset then
      return false, e.code .. " error at offset " .. e.offset .. " is placed at " .. e.y .. ":" .. e.x
    end
    if e.msg == "" or e.fix == "" then
      return false, e.code .. " error at " .. e.y .. ":" .. e.x .. " has no message or no fix"
    end
  end
  return true, ""
end

return Cover
