--- The line breaks of a Teal source that the layout adds: the fifth layer of the Teal formatter, which reads the syntax
--- tree and says where a line must begin that the source began no line at. [`build.fix.layout`] writes the lines and
--- asks this layer when it reaches a block.
---
--- Every break the source has is kept. A break is added only before a token of this plan, in these two cases:
--- - a statement that follows another on the same line begins a line of its own (`a = 1 b = 2`);
--- - a block is opened to its full form, each of its bodies' first statement and each word that ends a body (`elseif`,
---   `else`, `end`, `until`) beginning a line, unless it is to stay on one line. The blocks are the bodies of `if`,
---   `while`, `for`, `do`, `repeat`, a named function, a function written in an expression and a method.
---
--- A block that has any of those on a line with the code before it is judged where the layout reaches its first
--- statement (so after the statement around it has moved, and an inner block is judged where it lands). It stays as
--- it is when all of the following hold, and is otherwise opened:
--- - the whole of it from the first statement on is on one line in the source (and each piece shares that line);
--- - each body holds at most one statement, that statement is no block (an `if`, loop, `do`, `repeat`, function,
---   `match` or declaration), and an `if` has at most two branches;
--- - every block inside it, a function written in an expression, holds to the same;
--- - the layout writes it to end by column 100 (bytes).
--- The arm of a `match` is opened when it holds more than one statement or a block, and is otherwise left as the
--- source has it, as are the `if` expression and the members of a declaration: no width is applied to them.
local Ast = require("lang.ast")
local Lexer = require("lang.lexer")

-- TODO: the members of a record, interface, class or enum that share a line (`local record R x: integer y: string
-- end`) keep that line. Part them one to a line once the style of a declaration written on one line is decided.

local record Breaks
  --- A block, at the first of its pieces.
  record Construct
    --- The tokens that begin a line when it is opened, in order: the first statement of each body that has one and
    --- the token that ends each body.
    pieces: {integer}
    --- The last token of the construct.
    last: integer
    --- Whether any piece is on the line of the code before it in the source.
    shares: boolean
    --- Whether every piece is, and the construct from its first piece to its last token is on one line.
    inline: boolean
    --- Whether its bodies and the blocks inside it hold to the shape a block on one line has.
    mut flat: boolean
    --- Whether it stays on one line only if it ends by the width. An arm of a `match` is not bounded.
    bounded: boolean
  end

  record Plan
    --- The statements that follow another on their line: a break is due before each.
    parted: {integer: boolean}
    --- The blocks, by the index of their first piece.
    constructs: {integer: Construct}
  end

  --- The plan of `chunk`, a parse without errors.
  of: function(chunk: Ast.Chunk): Plan

  --- Whether `construct` is opened, given the column `end_col` a layout writing it on one line ends at (read only
  --- where the construct is bounded, inline and flat). Only a construct with a piece that shares its line is
  --- opened.
  opens: function(construct: Construct, end_col: integer): boolean

  --- The tokens a break may be added before, whatever the layout decides: the statements that follow another on
  --- their line and the pieces of every block.
  candidates: function(plan: Plan): {integer: boolean}
end

--- The column by which a block on one line ends, counted in bytes.
local WIDTH <const>: integer = 100

--- The kinds of statement that are a block of their own, or a declaration with a body: a block that holds one is
--- opened.
local BLOCK_STATEMENTS <const>: {string: boolean} = {
  If = true, While = true, Repeat = true, Do = true, ForNum = true, ForIn = true, LocalFunction = true,
  Function = true, Match = true, Record = true, Interface = true, Class = true, Enum = true,
}

local function base_of(node: Ast.Node): Ast.Base
  return node
end

--- The children of `node`.
local function kids_of(node: Ast.Node): {Ast.Node}
  local kids: mut {Ast.Node} = {}
  Ast.children(node, function(child: Ast.Node)
    kids[#kids + 1] = child
  end)
  return kids
end

--- The block among the children of `node`, if it has one.
local function body_of(node: Ast.Node): Ast.Node?
  for _, kid in ipairs(kids_of(node)) do
    if base_of(kid).kind == "Block" then
      return kid
    end
  end
  return nil
end

function Breaks.of(chunk: Ast.Chunk): Breaks.Plan
  local tokens = chunk.tokens
  local parted: mut {integer: boolean} = {}
  local constructs: mut {integer: Breaks.Construct} = {}

  --- Whether token `t` is on the line where the token before it ends.
  local function shares(t: integer): boolean
    return t > 1 and Lexer.y(tokens, t) == Lexer.yend(tokens, t - 1)
  end

  -- Breadth first, so that the children of a node come after it; the blocks' `flat` is settled walking back.
  local queue: mut {Ast.Node} = { chunk }
  local parents: mut {integer} = { 0 }
  -- By place in the queue: the construct a node is, and whether it or a block inside it is not flat.
  local made: mut {integer: Breaks.Construct} = {}
  local spoilt: mut {integer: boolean} = {}

  --- Notes the block `body` of the node at `at`, whose statements and end are those of the construct.
  --- `bodies` are all its bodies; `last` is its last token.
  local function construct(at: integer, bodies: {Ast.Node}, last: integer, branches: integer, bounded: boolean)
    local pieces: mut {integer} = {}
    local shaped = branches <= 2
    for _, body in ipairs(bodies) do
      local stats = kids_of(body)
      local first = stats[1]
      if first ~= nil then
        pieces[#pieces + 1] = base_of(first).first
        if #stats > 1 or BLOCK_STATEMENTS[base_of(first).kind] == true then
          shaped = false
        end
      end
      if bounded then
        pieces[#pieces + 1] = base_of(body).last
      end
    end
    local head = pieces[1]
    if head == nil then
      return
    end
    local sharing = 0
    for _, piece in ipairs(pieces) do
      if shares(piece) then
        sharing = sharing + 1
      end
    end
    made[at] = {
      pieces = pieces, last = last, shares = sharing > 0,
      inline = sharing == #pieces and Lexer.y(tokens, head) == Lexer.yend(tokens, last), flat = shaped,
      bounded = bounded,
    }
    if bounded and not shaped then
      spoilt[at] = true
    end
  end

  for at, node in ipairs(queue) do
    local base = base_of(node)
    local kids = kids_of(node)
    for _, kid in ipairs(kids) do
      queue[#queue + 1] = kid
      parents[#parents + 1] = at
    end
    local kind = base.kind
    if kind == "Block" then
      for i = 2, #kids do
        local stat = kids[i]
        local first = if stat == nil then 0 else base_of(stat).first end
        if first > 0 and shares(first) then
          parted[first] = true
        end
      end
    elseif kind == "If" then
      local bodies: mut {Ast.Node} = {}
      for _, kid in ipairs(kids) do
        local arm = base_of(kid)
        local body = if arm.kind == "Arm" then body_of(kid) elseif arm.kind == "Block" then kid else nil end
        if body ~= nil then
          bodies[#bodies + 1] = body
        end
      end
      construct(at, bodies, base.last, #bodies, true)
    elseif kind == "While" or kind == "ForNum" or kind == "ForIn" or kind == "Do" or kind == "Repeat" or
        kind == "Method" then
      local body = body_of(node)
      if body ~= nil then
        construct(at, { body }, base.last, 1, true)
      end
    elseif kind == "LocalFunction" or kind == "Function" or kind == "FunctionLit" then
      for _, kid in ipairs(kids) do
        local body = if base_of(kid).kind == "Fn" then body_of(kid) else nil end
        if body ~= nil then
          construct(at, { body }, base.last, 1, true)
        end
      end
    elseif kind == "MatchArm" then
      local body = body_of(node)
      if body ~= nil then
        construct(at, { body }, base.last, 1, false)
      end
    end
  end

  -- A construct is not flat if it or a block inside it is not; an arm answers for itself alone.
  local bad: mut {integer: boolean} = {}
  for at = #queue, 1, -1 do
    if spoilt[at] == true then
      bad[at] = true
    end
    local parent = parents[at] or 0
    if bad[at] == true and parent > 0 then
      bad[parent] = true
    end
    local one = made[at]
    if one ~= nil then
      if one.bounded then
        one.flat = bad[at] ~= true
      end
      constructs[one.pieces[1] or 0] = one
    end
  end
  return { parted = parted, constructs = constructs }
end

function Breaks.opens(construct: Breaks.Construct, end_col: integer): boolean
  if not construct.shares then
    return false
  end
  if not construct.bounded then
    return not construct.flat
  end
  return not (construct.inline and construct.flat and end_col <= WIDTH)
end

function Breaks.candidates(plan: Breaks.Plan): {integer: boolean}
  local found: mut {integer: boolean} = {}
  for t, _ in pairs(plan.parted) do
    found[t] = true
  end
  for _, one in pairs(plan.constructs) do
    for _, piece in ipairs(one.pieces) do
      found[piece] = true
    end
  end
  return found
end

return Breaks
