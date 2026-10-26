--- The layout of a Teal source: the third layer of the formatter, which writes the stream of
--- [`build.fix.trivia`] with the gap between neighbours on a line chosen from the roles of
--- [`build.fix.roles`], the start of each line chosen from the levels of [`build.fix.blocks`] and the brackets of
--- [`build.fix.continuation`], and the breaks added by [`build.fix.breaks`].
---
--- What this layer decides, from the role of each token and never from the whitespace the author wrote:
--- - a binary operator has one space each side, a unary operator hugs its operand (`-x`, `#t`; the operator `not`
---   keeps its space, and one before `not` hugs it: `-not a`);
--- - a comma has none before and one after, a `:` none before and one after, a call, an index and a field are
---   closed up;
--- - a table has its entries one space inside its braces (`{ a = 1, 2 }`) and an empty one is `{}`, and a key is
---   `["b"] = 2`, its brackets closed on it unless it begins with a long string (`[ [[x]] ]`);
--- - an attribute has one space before and none inside (`local x <const>`), and sits before the annotation;
--- - a table given to a call without parentheses is closed up to the callee (`Test.policy{ a = 1 }`).
--- A type keeps the author's own spacing, byte for byte, as do the type parameters of a declaration (`<P,Q>`).
---
--- A line that begins a statement or a member is indented two columns for each body it is in, as
--- [`build.fix.blocks`] counts them, and a word that closes a body (`end`, `else`, `elseif`, `until`, the `|` of a
--- `match` arm) stands level with the construct. Any other line is a continuation, which [`build.fix.continuation`]
--- indents from the brackets open where it starts. A type that spans lines keeps the author's spacing: each line
--- after the first begins at the column it began at in the source, moved as the statement that holds the type
--- moved (so a type that begins on a continuation line does not move with that line).
---
--- A comment is laid out by where it stands:
--- - one that follows code on its line stays on that line, a space after the code;
--- - one on a line of its own and lined up with the code after it (the same column in the source) takes that code's
---   indentation;
--- - any other keeps its column, moved as the statement it is in moved, or as the code after it moved where that
---   begins a statement. Before the word that closes a body that code is the last statement of the body (the
---   statement that holds the body, where there is none, and for a function written in an expression the line it
---   begins on), so a comment inside a body does not come out on the side of the closer, and a comment in an
---   empty body does not move unless its statement did;
--- - a column is a count of bytes, a tab one of them, as the lexer counts it;
--- - its bytes are never changed, trailing whitespace included: a comment is the author's text, and the previous
---   formatter wrote it as it found it.
---
--- The line structure is the source's: a break is kept as one `\n`, a run of blank lines is one, the `#!` line and
--- every comment are kept, and the file ends with a single `\n`. No token is changed, and the only tokens added
--- or removed are the comma of a table:
--- - a table whose `}` begins a line ends with a comma after its last entry, and one whose `}` follows its last
---   entry on the line has none (`{ 1, 2, }` is `{ 1, 2 }`);
--- - the comma is not added after an entry that ends in a function type with return types (`x as function(): A`),
---   which a `,` would read on as another return type;
---
--- A binary operator that begins a line goes to the end of the line before, ahead of any comment that line ends in,
--- and the operand after it takes the line (`a\n  and b` is `a and\n  b`). An operator is left where it is when a
--- blank line is before it, or when a comment ends its line and another lies between it and the code before it.
---
--- The line breaks of the source are all kept, and the layout adds a break in two cases, both decided by
--- [`build.fix.breaks`]. A statement that follows another on its line begins a line, and a block is opened to its
--- full form (each body's first statement and each word that ends a body on a line of its own) unless it is to stay
--- on one line. A statement that moves takes its continuation lines with it, as they are indented from the line the
--- statement is on. The layout does not wrap, and removes no break.

local Ast = require("lang.ast")
local Blocks = require("build.fix.blocks")
local Breaks = require("build.fix.breaks")
local Continuation = require("build.fix.continuation")
local Lexer = require("lang.lexer")
local Parser = require("lang.parser")
local Roles = require("build.fix.roles")
local Trivia = require("build.fix.trivia")

local record Layout
  --- `source` laid out and "", or nil and why it is refused: the first lexical or syntax error, worded
  --- `name:line:column: message`. It does not wrap or join lines, and checks nothing of what it writes: the
  --- formatter of a file is [`build.fix.format`]. A declaration file is read as `dialect` "decl" (`tl` by default).
  of: function(source: string, name: string, dialect?: Ast.Dialect): string?, string
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

--- One comment or token to be written, with the breaks before it as this layer places them.
local record Placed
  item: Trivia.Item
  mut newlines: integer
  mut blank: boolean
  --- The column of the source its line is measured from: its own, or for the operand that takes the line of an
  --- operator that moved, that operator's, where the operand takes its place.
  mut from: integer
  --- Whether it is the comma this layer adds to a table, which is no token of the source.
  comma: boolean
end

--- Where the line being written has reached.
local record Writer
  --- The bytes written on it.
  mut col: integer
end

--- The role of what `placed` writes.
local function role_of(placed: Placed, roled: Roles.Roled): Roles.Role
  return if placed.comma then "comma" else Roles.role(roled, placed.item.token) end
end

--- The gap between `before` and `placed`, which follow each other on a line.
local function gap(source: string, before: Placed, placed: Placed, roled: Roles.Roled,
                   plan: Continuation.Plan): string
  local a, b = before.item, placed.item
  if not before.comma and not placed.comma then
    local region = Roles.region(roled, b.token)
    if region ~= 0 and region == Roles.region(roled, a.token) then
      return source:sub(a.offset + #a.text, b.offset - 1)
    end
  end
  if not before.comma and not placed.comma then
    -- The author's spacing inside the type parameters of a declaration; a table given to a call without
    -- parentheses is closed up to the callee.
    if plan.bare[a.token] == true and plan.bare[b.token] == true then
      return source:sub(a.offset + #a.text, b.offset - 1)
    end
    if plan.sugar[b.token] == true then
      return ""
    end
  end
  local tight = TIGHT_AFTER[role_of(before, roled)] == true or TIGHT_BEFORE[role_of(placed, roled)] == true
  if tight and not joins(a.text, b.text) then
    return ""
  end
  return " "
end

--- The items of `stream` in the order they are written: a binary operator that begins a line follows the code
--- before it, ahead of the comments between, and the operand after it begins its line. The operator is left where
--- it is when a blank line is before it, or when a comment ends its line and another lies between it and the code.
local function with_operators(stream: Trivia.Stream, plan: Continuation.Plan): {Placed}
  local items = stream.items
  local out: mut {Placed} = {}
  -- Whether the operand of an operator that moved is yet to be written, and where the operator stood.
  local owed = false
  local owed_x = 0
  for i, item in ipairs(items) do
    local placed: Placed = { item = item, newlines = item.newlines, blank = item.blank, from = item.x, comma = false }
    local moved = false
    if item.kind == "token" and plan.operators[item.token] == true and item.newlines > 0 and not item.blank then
      -- The code the operator follows, and whether a comment lies between it and the operator and one ends the
      -- operator's line: the operator's comment would then follow a comment of a line of its own.
      local at = #out
      while at >= 1 and (out[at] or placed).item.kind == "comment" do
        at = at - 1
      end
      local code = out[at]
      local after = items[i + 1]
      if code ~= nil and code.item.kind == "token" then
        local ends_operator = after ~= nil and after.kind == "comment" and after.trailing
        if not (ends_operator and #out > at) then
          placed.newlines = 0
          table.insert(out, at + 1, placed)
          moved = true
          owed = true
          owed_x = item.x
        end
      end
    elseif owed and item.kind == "token" then
      owed = false
      if placed.newlines == 0 then
        placed.newlines = 1
        placed.blank = false
        placed.from = owed_x
      end
    end
    if not moved then
      out[#out + 1] = placed
    end
  end
  return out
end

--- `placed` with the comma of each table settled: one whose `}` begins a line ends with a comma, and one that
--- does not has none.
local function with_commas(placed: {Placed}, plan: Continuation.Plan): {Placed}
  local at: mut {integer: integer} = {}
  for i, one in ipairs(placed) do
    if one.item.kind == "token" then
      at[one.item.token] = i
    end
  end
  local add: mut {integer: boolean} = {}
  local drop: mut {integer: boolean} = {}
  for _, list in ipairs(plan.tables) do
    local close = at[list.close]
    local closing = if close == nil then nil else placed[close] end
    if close ~= nil and closing ~= nil then
      local p = close - 1
      while p >= 1 and (placed[p] or closing).item.kind == "comment" do
        p = p - 1
      end
      local prev = placed[p]
      if prev ~= nil and prev.item.kind == "token" then
        local own_line = closing.newlines > 0
        if prev.item.text == "," then
          -- A comma that begins its own line is left, as is one a comment parts from the brace.
          if not own_line and prev.newlines == 0 then
            drop[p] = true
          end
        elseif prev.item.token == list.last and own_line and plan.swallows[list.last] ~= true then
          add[p] = true
        end
      end
    end
  end
  local out: mut {Placed} = {}
  for i, one in ipairs(placed) do
    if drop[i] ~= true then
      out[#out + 1] = one
    end
    if add[i] == true then
      local item = one.item
      out[#out + 1] = {
        item = {
          kind = "token", token = item.token, text = ",", offset = item.offset + #item.text, y = item.yend,
          x = item.x + #item.text, yend = item.yend, newlines = 0, blank = false, trailing = false,
        },
        newlines = 0, blank = false, from = item.x + #item.text, comma = true,
      }
    end
  end
  return out
end

--- The text of `placed`, the items of `source` in the order they are written, laid out by `roled` and `cursor`,
--- whose `plan` and levels are those of the tree that `source` parses to, whose tokens are `tokens`.
local function laid_out(source: string, placed: {Placed}, shebang: string?, tokens: Lexer.Tokens, roled: Roles.Roled,
                        cursor: Continuation.Cursor, breaks: Breaks.Plan): string
  local out: mut {string} = {}
  local line: Writer = { col = 0 }
  local function put(text: string)
    out[#out + 1] = text
    local last = text:find("\n[^\n]*$")
    line.col = if last == nil then line.col + #text else #text - last end
  end
  if shebang ~= nil then
    put(shebang .. "\n")
  end

  --- The column a line that begins with token `t` takes: that of the continuation or the structure, or for a token
  --- of a type that began on an earlier line, the column it had in the source moved as the statement that holds
  --- the type moved.
  local function token_column(t: integer, prev_token: integer): integer
    local region = Roles.region(roled, t)
    if region ~= 0 and prev_token ~= 0 and Roles.region(roled, prev_token) == region then
      return math.max(0, Lexer.x(tokens, t) - 1 + cursor.shift)
    end
    return Continuation.column(cursor, t)
  end

  --- The column a comment on a line of its own begins at.
  local function comment_column(item: Trivia.Item, prev_token: integer): integer
    local at = item.token
    local x = Lexer.x(tokens, at)
    -- The end of the file has no code to line up with: its column is where the last line ended.
    if item.x == x and Lexer.kind(tokens, at) ~= "$EOF$" then
      return token_column(at, prev_token)
    end
    local levels = cursor.levels
    local anchor = levels.anchors[at]
    local shift = cursor.shift
    if anchor ~= nil then
      -- A function written in an expression is laid out from its line, any other body from its statement.
      shift = if anchor == 0 then 0 elseif cursor.plan.literal_opens[anchor] == true then
        Continuation.row_shift(cursor, anchor) else cursor.shifts[anchor] or 0 end
    elseif levels.starts[at] == true then
      shift = token_column(at, prev_token) - (x - 1)
    end
    return math.max(0, item.x - 1 + shift)
  end

  -- The tokens a break is due before whether or not the source has one: the statements that share a line, and the
  -- pieces of each block once it is opened.
  local forced: mut {integer: boolean} = {}
  for t, _ in pairs(breaks.parted) do
    forced[t] = true
  end
  local at_index: mut {integer: integer} = {}
  for i, one in ipairs(placed) do
    if one.item.kind == "token" and not one.comma then
      at_index[one.item.token] = i
    end
  end

  --- The column the code from `placed[from]` to `placed[to]` ends at, written on one line after what is written.
  local function flat_end(from: integer, to: integer): integer
    local col = line.col
    for k = from, to do
      local one = placed[k]
      local before = placed[k - 1]
      if one ~= nil and before ~= nil then
        col = col + #gap(source, before, one, roled, cursor.plan) + #one.item.text
      end
    end
    return col
  end

  local before: Placed? = nil
  local prev_token = 0
  for index, one in ipairs(placed) do
    local item = one.item
    if item.kind == "eof" then
      break
    end
    local one_break = one.newlines > 0
    if item.kind == "token" and not one.comma then
      local block = breaks.constructs[item.token]
      if block ~= nil and block.shares then
        local last = at_index[block.last]
        local end_col = if block.bounded and block.inline and block.flat and last ~= nil then
          flat_end(index, last) else 0 end
        if Breaks.opens(block, end_col) then
          for _, piece in ipairs(block.pieces) do
            forced[piece] = true
          end
        end
      end
      one_break = one_break or forced[item.token] == true
    end
    local starts_line = before == nil or one_break
    if before == nil then
      if shebang ~= nil and one.blank then
        put("\n")
      end
    elseif one_break then
      put(if one.blank then "\n\n" else "\n" end)
    elseif before.item.kind == "comment" then
      -- Not reached for a source that lexed: a comment runs to its line's end.
      put("\n")
    elseif item.kind == "comment" then
      put(" ")
    else
      put(gap(source, before, one, roled, cursor.plan))
    end
    if starts_line then
      local column = if item.kind == "comment" then comment_column(item, prev_token) else
        token_column(item.token, prev_token) end
      put((" "):rep(column))
    end
    local at = line.col
    put(item.text)
    if item.kind == "token" and not one.comma then
      -- A token that took a line the source did not give it moves as the line it left moved: it began no line there,
      -- so the column it was at says nothing of how what is measured from it is laid out.
      local from = if one_break and one.newlines == 0 then at - cursor.row + 1 else one.from end
      Continuation.wrote(cursor, item.token, at, from, item.text, starts_line)
      prev_token = item.token
    end
    before = one
  end
  if before ~= nil then
    put("\n")
  end
  return table.concat(out)
end

function Layout.of(source: string, name: string, dialect?: Ast.Dialect): string?, string
  local lexed = Lexer.lex(source, name)
  local parsed = Parser.parse(lexed, name, dialect or "tl")
  local first = parsed.errors[1]
  if first ~= nil then
    return nil, string.format("%s:%d:%d: %s", name, first.y, first.x, first.msg)
  end
  local stream = Trivia.of(source, lexed.tokens)
  local roled = Roles.of(parsed.chunk)
  local levels = Blocks.of(parsed.chunk)
  local plan = Continuation.of(parsed.chunk)
  local placed = with_commas(with_operators(stream, plan), plan)
  local breaks = Breaks.of(parsed.chunk)
  return laid_out(source, placed, stream.shebang, lexed.tokens, roled, Continuation.start(plan, levels), breaks), ""
end

return Layout
