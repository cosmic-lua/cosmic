--- Where a line that is not the start of a statement begins: the fourth layer of the Teal formatter, between
--- [`build.fix.blocks`] (the lines that begin a body item or end a body) and [`build.fix.layout`] (which writes
--- them).
---
--- A line that continues a statement is indented from the brackets open where it starts:
--- - a line inside a bracket begins two columns past the line that opened the bracket (four in a block header: the
---   condition of an `if`, `elseif`, `while`, `until` or `match`, the head of a `for`, and the signature of a
---   function), and a line that continues an entry rather than begins the next goes two further;
--- - a bracket that holds one expression, not a list of entries (a parenthesized expression, an index, a key),
---   gives its lines the one indentation;
--- - a closing bracket that begins a line stands level with the line that opened its bracket;
--- - a parameter list whose first parameter follows its `(` lines the rest up under that one;
--- - an `if` expression is a bracket from its `if` to its `end`: the values of its arms are its entries, and its
---   `then`, `elseif`, `else` and `end` stand level with the line the `if` is written on when they begin a line;
--- - outside any bracket a line continues its statement two columns in from the statement, four in a header;
--- - the body of a function written in an expression is indented from the line the `function` is written on, and
---   its `end` returns to that line's indentation, so a function opens wherever its line sits;
--- - a bracket opened in the statement around a function belongs to that statement: the lines of the function's
---   own statements are laid out from the brackets they open.
--- The roles of [`build.fix.roles`] and the tree decide what an entry is; a line break the source did not have is
--- never added.
---
--- A [`Continuation.Cursor`] follows the tokens in the order they are written and answers the column a line beginning
--- with a token takes, from what was written before. It also records how far each token moved from the column it
--- was written at, which a comment that keeps its column moves by.
local Ast = require("lang.ast")
local Blocks = require("build.fix.blocks")
local Lexer = require("lang.lexer")

local record Continuation
  --- A bracket, at the token that opens it.
  record Open
    --- The token that closes it.
    close: integer
    --- Whether it holds one expression and no list of entries.
    single: boolean
    --- Whether it is a parameter list, whose first parameter lines the rest up when it follows the `(`.
    params: boolean
    --- For a parameter list, whether its first parameter is on the line of the `(`.
    inline: boolean
  end

  --- A table with entries, for the comma it ends with.
  record Table
    close: integer
    --- The last token of its last entry.
    last: integer
  end

  record Plan
    --- The brackets, by the token that opens each.
    opens: {integer: Open}
    --- The tokens that close a bracket.
    closes: {integer: boolean}
    --- The tokens that begin an entry of the bracket they are in: an argument, a table entry, a parameter, the
    --- expression of a parenthesis, an index or a key.
    entries: {integer: boolean}
    --- The tokens in a block header.
    header: {integer: boolean}
    --- The first token and the closing token of a block that has a statement: the pair the cursor enters and
    --- leaves.
    block_opens: {integer: boolean}
    block_closes: {integer: boolean}
    --- The `then`, `elseif` and `else` of an `if` expression.
    mids: {integer: boolean}
    --- The `function` and the `end` of a function written in an expression.
    literal_opens: {integer: boolean}
    literal_closes: {integer: boolean}
    --- The tokens that are the operator of a binary expression.
    operators: {integer: boolean}
    --- The first token of the argument of a call written without parentheses (`f{ ... }`), which is closed
    --- up to the callee.
    sugar: {integer: boolean}
    --- The tokens from the `<` to the `>` of the type parameters of a declaration, whose spacing is the author's.
    bare: {integer: boolean}
    --- The tokens that end a function type with return types that are not in parentheses, after which a `,` is
    --- read as another return type.
    swallows: {integer: boolean}
    tables: {Table}
  end

  --- What the cursor knows of a bracket that is open.
  record Frame
    --- The indentation of the line it was opened on.
    indent: integer
    step: integer
    single: boolean
    --- The column a parameter list's first parameter is at, once it follows the `(`.
    mut align: integer?
  end

  --- A function written in an expression that is open.
  record Literal
    depth: integer
    --- The indentation of the line it was opened on.
    base: integer
  end

  record Cursor
    plan: Plan
    levels: Blocks.Levels
    mut brackets: mut {Frame}
    --- The number of brackets that were open when each body was entered: the brackets below belong to the
    --- statement around the body.
    mut floors: mut {integer}
    --- The shift of the statement around each body, to be restored when it ends.
    mut saved: mut {integer}
    mut literals: mut {Literal}
    --- The indentation of the line being written.
    mut indent: integer
    --- How far the statement being written moved from the column it began at.
    mut shift: integer
    --- For each token written, how far it moved from the column it began at.
    mut shifts: mut {integer: integer}
    --- How far the line being written moved: its first token from the column it began at.
    mut row: integer
    --- For each token written, how far the line it was written on moved.
    mut rows: mut {integer: integer}
  end

  --- The plan of `chunk`, a parse without errors, whose levels are `levels`.
  of: function(chunk: Ast.Chunk): Plan

  --- A cursor at the start of the file.
  start: function(plan: Plan, levels: Blocks.Levels): Cursor

  --- The column a line that begins with token `t` takes, given what was written before it.
  column: function(cursor: Cursor, t: integer): integer

  --- Notes that token `t` was written at output column `col`, `x` being the column it began at in the source.
  --- `text` is what was written and `line_start` whether it began its line.
  wrote: function(cursor: Cursor, t: integer, col: integer, x: integer, text: string, line_start: boolean)

  --- How far the line that token `t` was written on moved: its first token from the column it began at, or for the
  --- operand that took the line of an operator that moved, from the column of that operator.
  row_shift: function(cursor: Cursor, t: integer): integer
end

--- The columns a level is indented, and a line that continues is.
local STEP <const>: integer = 2

--- The indentation a line in a block header is further than the statement.
local HEADER <const>: integer = 4

--- The kinds of node whose tokens are a block header (the tokens after the keyword up to the `then` or `do` that
--- opens the body).
local HEADED <const>: {string: boolean} = { While = true, ForNum = true, ForIn = true }

--- The token that closes each bracket.
local CLOSERS <const>: {string: string} = { ["("] = ")", ["["] = "]", ["{"] = "}", ["if"] = "end" }

local function base_of(node: Ast.Node): Ast.Base
  return node
end

--- The children of `kids` from the `from`th on.
local function rest(kids: {Ast.Base}, from: integer): {Ast.Base}
  local found: mut {Ast.Base} = {}
  for i = from, #kids do
    local kid = kids[i]
    if kid ~= nil then
      found[#found + 1] = kid
    end
  end
  return found
end

function Continuation.of(chunk: Ast.Chunk): Continuation.Plan
  local tokens = chunk.tokens
  local count = Lexer.count(tokens)
  local opens: mut {integer: Continuation.Open} = {}
  local closes: mut {integer: boolean} = {}
  local entries: mut {integer: boolean} = {}
  local header: mut {integer: boolean} = {}
  local block_opens: mut {integer: boolean} = {}
  local block_closes: mut {integer: boolean} = {}
  local literal_opens: mut {integer: boolean} = {}
  local literal_closes: mut {integer: boolean} = {}
  local operators: mut {integer: boolean} = {}
  local sugar: mut {integer: boolean} = {}
  local bare: mut {integer: boolean} = {}
  local mids: mut {integer: boolean} = {}
  local swallows: mut {integer: boolean} = {}
  local tables: mut {Continuation.Table} = {}

  --- Whether token `i` is the token `text`.
  local function spells(i: integer, text: string): boolean
    return i >= 1 and i <= count and Lexer.text(tokens, i) == text
  end

  --- Marks the tokens `first` to `last` as in a header, or as not.
  local function mark(first: integer, last: integer, value: boolean)
    for i = first, last do
      if value then
        header[i] = true
      else
        header[i] = nil
      end
    end
  end

  --- Records the bracket from `open`, the token `text`, to `close`, whose entries begin with `items`: nothing is
  --- recorded where the tokens are not the ones the bracket is spelled with (a call written `f{}` or `f""` has
  --- none).
  local function bracket(open: integer, close: integer, text: string, items: {Ast.Base}, single: boolean,
                         params: boolean)
    if not spells(open, text) or not spells(close, CLOSERS[text] or "") or close < open then
      return
    end
    local first = items[1]
    opens[open] = {
      close = close, single = single, params = params,
      inline = first ~= nil and Lexer.y(tokens, first.first) == Lexer.y(tokens, open),
    }
    closes[close] = true
    for _, item in ipairs(items) do
      entries[item.first] = true
    end
  end

  --- The children of `kids` whose kind is `kind`.
  local function of_kind(kids: {Ast.Base}, kind: string): {Ast.Base}
    local found: mut {Ast.Base} = {}
    for _, kid in ipairs(kids) do
      if kid.kind == kind then
        found[#found + 1] = kid
      end
    end
    return found
  end

  --- The body block among `kids`, if there is one.
  local function body_of(kids: {Ast.Base}): Ast.Base?
    return of_kind(kids, "Block")[1]
  end

  --- Notes what the tree says of the node `base`, whose children are `kids`.
  local function note(base: Ast.Base, kids: {Ast.Base})
    local kind = base.kind
    local head = kids[1]
    local generics = of_kind(kids, "TypeParam")
    local first_param, last_param = generics[1], generics[#generics]
    if first_param ~= nil and last_param ~= nil and spells(first_param.first - 1, "<") and
        spells(last_param.last + 1, ">") then
      for i = first_param.first - 1, last_param.last + 1 do
        bare[i] = true
      end
    end
    if (kind == "Call" or kind == "MethodCall") and kids[2] ~= nil then
      local callee_end = (head or base).last + (if kind == "Call" then 1 else 3 end)
      if not spells(callee_end, "(") then
        sugar[callee_end] = true
      end
    end
    if kind == "Block" then
      if #kids > 0 then
        block_opens[base.first] = true
        block_closes[base.last] = true
        -- A body entered inside a header is a statement again, not part of the header.
        if header[base.first] == true then
          mark(base.first, base.last - 1, false)
        end
      end
    elseif kind == "Call" and head ~= nil then
      bracket(head.last + 1, base.last, "(", rest(kids, 2), false, false)
    elseif kind == "MethodCall" and head ~= nil then
      bracket(head.last + 3, base.last, "(", rest(kids, 2), false, false)
    elseif kind == "Table" then
      bracket(base.first, base.last, "{", kids, false, false)
      local last = kids[#kids]
      if last ~= nil then
        tables[#tables + 1] = { close = base.last, last = last.last }
      end
    elseif kind == "Keyed" and head ~= nil then
      bracket(base.first, head.last + 1, "[", { head }, true, false)
    elseif kind == "Index" and head ~= nil then
      local key = kids[2]
      if key ~= nil then
        bracket(head.last + 1, base.last, "[", { key }, true, false)
      end
    elseif kind == "Paren" and head ~= nil then
      bracket(base.first, base.last, "(", { head }, true, false)
    elseif kind == "Fn" or kind == "Method" then
      local params = of_kind(kids, "Param")
      local open = if kind == "Fn" then base.first elseif head ~= nil then head.last + 1 else base.first end
      local last = params[#params]
      bracket(open, if last ~= nil then last.last + 1 else open + 1 end, "(", params, false, true)
      local body = body_of(kids)
      if body ~= nil then
        mark(base.first, body.first - 1, true)
      end
    elseif kind == "MatchArm" then
      local pats: mut {Ast.Base} = {}
      for _, kid in ipairs(kids) do
        if kid.kind == "PatBool" or kid.kind == "PatBind" then
          pats[#pats + 1] = kid
        end
      end
      local last = pats[#pats]
      if last ~= nil then
        bracket(base.first, last.last + 1, "(", pats, false, false)
      end
      local body = body_of(kids)
      if body ~= nil then
        mark(base.first, body.first - 1, true)
      end
    elseif kind == "IfExp" then
      -- The arms after the first begin with an `elseif`, and the value after them with an `else`.
      local last = kids[#kids]
      for i, kid in ipairs(kids) do
        if i > 1 then
          mids[kid.first - 1] = true
        end
      end
      bracket(base.first, base.last, "if", if last ~= nil then { last } else {} end, false, false)
    elseif kind == "ExpArm" then
      if head ~= nil and spells(head.last + 1, "then") then
        mids[head.last + 1] = true
      end
      local value = kids[2]
      if value ~= nil then
        entries[value.first] = true
      end
    elseif kind == "TypeFunction" then
      -- A return list in parentheses ends at its `)`; one without reads on through a `,`.
      local rets = of_kind(kids, "Rets")[1]
      if rets ~= nil and not spells(rets.first, "(") then
        swallows[base.last] = true
      end
    elseif kind == "FunctionLit" then
      literal_opens[base.first] = true
      literal_closes[base.last] = true
    elseif kind == "Binary" and head ~= nil then
      operators[head.last + 1] = true
    elseif kind == "Arm" then
      local body = body_of(kids)
      if body ~= nil then
        mark(base.first, body.first - 1, true)
      end
    elseif HEADED[kind] == true then
      local body = body_of(kids)
      if body ~= nil then
        mark(base.first + 1, body.first - 1, true)
      end
    elseif kind == "Repeat" then
      local body = body_of(kids)
      if body ~= nil then
        mark(body.last + 1, base.last, true)
      end
    elseif kind == "Match" and head ~= nil then
      mark(base.first + 1, head.last + 1, true)
    elseif (kind == "LocalFunction" or kind == "Function") and head ~= nil then
      local fn = kids[#kids]
      if fn ~= nil then
        mark(base.first, fn.first - 1, true)
      end
    end
  end

  -- A node is read before its children, so a body nested in a header unmarks its own tokens after the header
  -- marked them.
  local queue: mut {Ast.Node} = { chunk }
  for _, node in ipairs(queue) do
    local kids: mut {Ast.Base} = {}
    Ast.children(node, function(child: Ast.Node)
      kids[#kids + 1] = base_of(child)
      queue[#queue + 1] = child
    end)
    note(base_of(node), kids)
  end

  return {
    opens = opens, closes = closes, entries = entries, header = header, block_opens = block_opens,
    block_closes = block_closes, literal_opens = literal_opens, literal_closes = literal_closes,
    operators = operators, sugar = sugar, bare = bare, swallows = swallows, tables = tables, mids = mids,
  }
end

function Continuation.start(plan: Continuation.Plan, levels: Blocks.Levels): Continuation.Cursor
  return {
    plan = plan, levels = levels, brackets = {}, floors = {}, saved = {}, literals = {}, indent = 0, shift = 0,
    shifts = {}, row = 0, rows = {},
  }
end

--- The column of a statement `depth` bodies in: two for each body, counted from the line of the innermost function
--- written in an expression that is open.
local function margin(cursor: Continuation.Cursor, depth: integer): integer
  for i = #cursor.literals, 1, -1 do
    local literal = cursor.literals[i]
    if literal ~= nil and depth > literal.depth then
      return literal.base + STEP * (depth - literal.depth)
    end
  end
  return STEP * depth
end

function Continuation.column(cursor: Continuation.Cursor, t: integer): integer
  local plan, levels = cursor.plan, cursor.levels
  local depth = levels.depths[t] or 0
  if levels.starts[t] == true then
    if plan.literal_closes[t] == true then
      local literal = cursor.literals[#cursor.literals]
      if literal ~= nil then
        return literal.base
      end
    end
    return margin(cursor, depth)
  end
  local top = cursor.brackets[#cursor.brackets]
  if top == nil or #cursor.brackets <= (cursor.floors[#cursor.floors] or 0) then
    return margin(cursor, depth) + (if plan.header[t] == true then HEADER else STEP end)
  end
  if plan.closes[t] == true or plan.mids[t] == true then
    return top.indent
  end
  local base = top.align or top.indent + top.step
  if plan.entries[t] == true or top.single then
    return base
  end
  return base + STEP
end

function Continuation.wrote(cursor: Continuation.Cursor, t: integer, col: integer, x: integer, text: string,
                            line_start: boolean)
  local plan, levels = cursor.plan, cursor.levels
  if line_start then
    cursor.indent = col
    cursor.row = col - (x - 1)
  end
  cursor.shifts[t] = col - (x - 1)
  cursor.rows[t] = cursor.row
  -- A token with a line break in it (a long string) leaves the line it ends on, whose bytes are the source's and
  -- whose indentation is its own.
  local last_line = text:match("\n([^\n]*)$")
  if last_line ~= nil then
    cursor.indent = #(last_line:match("^[ \t]*") or "")
    cursor.row = 0
  end
  if plan.block_closes[t] == true then
    local floor = table.remove(cursor.floors)
    local shift = table.remove(cursor.saved)
    if floor ~= nil and shift ~= nil then
      cursor.shift = shift
    end
  end
  if plan.literal_closes[t] == true then
    table.remove(cursor.literals)
  end
  if plan.closes[t] == true then
    table.remove(cursor.brackets)
  end
  if plan.block_opens[t] == true then
    cursor.floors[#cursor.floors + 1] = #cursor.brackets
    cursor.saved[#cursor.saved + 1] = cursor.shift
  end
  if levels.starts[t] == true and levels.anchors[t] == nil then
    cursor.shift = col - (x - 1)
  end
  local open = plan.opens[t]
  if open ~= nil then
    local frame: Continuation.Frame = {
      indent = cursor.indent, step = if plan.header[t] == true then HEADER else STEP end, single = open.single,
      align = nil,
    }
    if open.params and open.inline then
      frame.align = col + #text
    end
    cursor.brackets[#cursor.brackets + 1] = frame
  end
  if plan.literal_opens[t] == true then
    cursor.literals[#cursor.literals + 1] = { depth = levels.depths[t] or 0, base = cursor.indent }
  end
end

function Continuation.row_shift(cursor: Continuation.Cursor, t: integer): integer
  return cursor.rows[t] or 0
end

return Continuation
