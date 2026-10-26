--- The layout of a Teal source: the third layer of the formatter, which writes the stream of
--- [`build.fix.trivia`] with the gap between neighbours on a line chosen from the roles of
--- [`build.fix.roles`] and the start of each line chosen from the levels of [`build.fix.blocks`].
---
--- What this layer decides, from the role of each token and never from the whitespace the author wrote:
--- - a binary operator has one space each side, a unary operator hugs its operand (`-x`, `#t`; the operator `not`
---   keeps its space, and one before `not` hugs it: `-not a`);
--- - a comma has none before and one after, a `:` none before and one after, a call, an index and a field are
---   closed up;
--- - a table has its entries one space inside its braces (`{ a = 1, 2 }`) and an empty one is `{}`, and a key is
---   `["b"] = 2`, its brackets closed on it unless it begins with a long string (`[ [[x]] ]`);
--- - an attribute has one space before and none inside (`local x <const>`), and sits before the annotation.
--- A type keeps the author's own spacing, byte for byte.
---
--- A line is indented two columns for each body it is in, as [`build.fix.blocks`] counts them, and a word that
--- closes a body (`end`, `else`, `elseif`, `until`, the `|` of a `match` arm) stands level with the construct. The
--- level is that of the first token of the line, whatever the line is part of.
---
--- A comment is laid out by where it stands:
--- - one that follows code on its line stays on that line, a space after the code;
--- - one on a line of its own and lined up with the code after it (the same column in the source) takes that code's
---   indentation;
--- - any other keeps its column, moved as the code after it moved. Before the word that closes a body that code is the
---   last statement of the body (the line that opened it, where there is none), so a comment inside a body does not
---   come out on the side of the closer;
--- - its bytes are never changed, trailing whitespace included: a comment is the author's text, and the previous
---   formatter wrote it as it found it.
---
--- The line structure is the source's: a break is kept as one `\n`, a run of blank lines is one, the `#!` line and
--- every comment are kept, and the file ends with a single `\n`. No token is added, removed or changed.
---
--- This layer does not wrap or move a break, and it neither adds nor drops a trailing comma.

-- TODO: indent a line that continues a statement by its brackets (entries two columns in from the line that opened
-- them, four in a block header, a closing bracket level with its opener, aligned parameters, a function written
-- on a continuation line opening its body from that line) once this module lays out continuation lines; until then
-- a line begins at the level of its first token, as a statement of that body does.
-- TODO: keep a table's trailing comma only where the table closes on a line of its own, once this module lays out
-- continuation lines; until then `{ 1, 2, }` is kept as written.
-- TODO: move a type that spans lines with its statement, its later lines keeping their column relative to the
-- line that holds its first token, once this module lays out continuation lines; until then each of its lines
-- begins at the level of its first token and the spacing within a line is the author's.
local Blocks = require("build.fix.blocks")
local Lexer = require("lang.lexer")
local Parser = require("lang.parser")
local Roles = require("build.fix.roles")
local Trivia = require("build.fix.trivia")

local record Layout
  --- `source` laid out and "", or nil and why it is refused: the first lexical or syntax error, worded
  --- `name:line:column: message`. It does not break or join lines, so it is no formatter of a file yet.
  of: function(source: string, name: string): string?, string
end

--- The roles after which the next token is closed up to it.
local TIGHT_AFTER <const>: {string: boolean} = {
  call_open = true, group_open = true, unary = true, index_open = true, key_open = true, dot = true,
  method_colon = true, attr_open = true, angle_open = true, empty_open = true,
}

--- The roles before which the token is closed up to the one before.
local TIGHT_BEFORE <const>: {string: boolean} = {
  comma = true, colon = true, question = true, dot = true, method_colon = true, call_open = true,
  paren_close = true, index_open = true, wide_open = true, index_close = true, key_close = true, attr_close = true,
  angle_open = true, angle_close = true, empty_close = true,
}

--- Two characters that, written together, are one token instead of the two: closing up the gap between tokens
--- that end and begin so would change the source.
local JOINS <const>: {string: boolean} = {
  ["--"] = true, [".."] = true, ["=="] = true, ["<="] = true, [">="] = true, ["~="] = true, ["<<"] = true,
  [">>"] = true, ["//"] = true, ["::"] = true, ["[["] = true, ["[="] = true,
}

--- Whether tokens `left` and `right` written with nothing between would lex as something else.
local function joins(left: string, right: string): boolean
  local a, b = left:sub(-1), right:sub(1, 1)
  if a:find("^[%w_]$") ~= nil and b:find("^[%w_]$") ~= nil then
    return true
  end
  return JOINS[a .. b] == true
end

--- The gap between the tokens `before` and `item`, which follow each other on a line.
local function gap(source: string, before: Trivia.Item, item: Trivia.Item, roled: Roles.Roled): string
  local region = Roles.region(roled, item.token)
  if region ~= 0 and region == Roles.region(roled, before.token) then
    return source:sub(before.offset + #before.text, item.offset - 1)
  end
  local tight = TIGHT_AFTER[Roles.role(roled, before.token)] == true or
    TIGHT_BEFORE[Roles.role(roled, item.token)] == true
  if tight and not joins(before.text, item.text) then
    return ""
  end
  return " "
end

--- The columns a level is indented.
local STEP <const> = 2

--- The column a comment on a line of its own begins at. `shifts` holds, for the lines written so far, how far
--- each moved from the column it began at.
local function comment_column(item: Trivia.Item, tokens: Lexer.Tokens, levels: Blocks.Levels,
                              shifts: {integer: integer}): integer
  local at = item.token
  local target = STEP * (levels.depths[at] or 0)
  local x = Lexer.x(tokens, at)
  -- The end of the file has no code to line up with: its column is where the last line ended.
  if item.x == x and Lexer.kind(tokens, at) ~= "$EOF$" then
    return target
  end
  local anchor = levels.anchors[at]
  local shift = target - (x - 1)
  if anchor ~= nil then
    shift = if anchor == 0 then 0 else shifts[Lexer.y(tokens, anchor)] or 0 end
  end
  return math.max(0, item.x - 1 + shift)
end

--- The text of `stream`, the items of `source` laid out by `roled` and `levels`, which are the roles and the
--- levels of the tree that `source` parses to, whose tokens are `tokens`.
local function laid_out(source: string, stream: Trivia.Stream, tokens: Lexer.Tokens, roled: Roles.Roled,
                        levels: Blocks.Levels): string
  local out: mut {string} = {}
  local shebang = stream.shebang
  if shebang ~= nil then
    out[#out + 1] = shebang .. "\n"
  end
  -- For the line a token begins, the columns it moved: how far its line's indentation is from the source's.
  local shifts: mut {integer: integer} = {}
  local before: Trivia.Item? = nil
  for _, item in ipairs(stream.items) do
    if item.kind == "eof" then
      break
    end
    local starts_line = before == nil or item.newlines > 0
    if before == nil then
      if shebang ~= nil and item.blank then
        out[#out + 1] = "\n"
      end
    elseif item.newlines > 0 then
      out[#out + 1] = if item.blank then "\n\n" else "\n" end
    elseif before.kind == "comment" then
      -- Not reached for a source that lexed: a comment runs to its line's end.
      out[#out + 1] = "\n"
    elseif item.kind == "comment" then
      out[#out + 1] = " "
    else
      out[#out + 1] = gap(source, before, item, roled)
    end
    if starts_line then
      local column = if item.kind == "comment" then comment_column(item, tokens, levels, shifts) else
        STEP * (levels.depths[item.token] or 0) end
      if item.kind == "token" then
        shifts[item.y] = column - (item.x - 1)
      end
      out[#out + 1] = (" "):rep(column)
    end
    out[#out + 1] = item.text
    before = item
  end
  if before ~= nil then
    out[#out + 1] = "\n"
  end
  return table.concat(out)
end

function Layout.of(source: string, name: string): string?, string
  local lexed = Lexer.lex(source, name)
  local parsed = Parser.parse(lexed, name, "tl")
  local first = parsed.errors[1]
  if first ~= nil then
    return nil, string.format("%s:%d:%d: %s", name, first.y, first.x, first.msg)
  end
  local stream = Trivia.of(source, lexed.tokens)
  return laid_out(source, stream, lexed.tokens, Roles.of(parsed.chunk), Blocks.of(parsed.chunk)), ""
end

return Layout
