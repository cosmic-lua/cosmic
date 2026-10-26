--- How deep each token of a parsed source sits in blocks: the layer of the Teal formatter that says where a line
--- begins, between [`build.fix.roles`] (the part each token plays on its line) and [`build.fix.layout`] (which
--- writes the lines).
---
--- A body is indented one level past the construct that opens it: the statements of a block, the members of a
--- `record`, `interface` or `class`, the values of an `enum`. The words that end a body are not in it: the `end`,
--- `else`, `elseif`, `until` and `|` that close a block, and the `end` of a record, stand level with the construct
--- (`|` begins an arm of a `match` as `elseif` begins an arm of an `if`). The statements of a chunk are at level
--- 0. A function written in an expression opens a body as a statement does, so `f(function() ... end)` indents its
--- body one level past the line `f` begins; where that line is a continuation of a statement is the layout of
--- continuation lines, which is not laid out here.
---
--- The words that close a body also say how a comment before one is moved: [`Blocks.Levels.anchors`]. The tokens
--- that begin a line by the structure alone, whatever the source did with them, are [`Blocks.Levels.starts`].
local Ast = require("lang.ast")
local Lexer = require("lang.lexer")

local record Blocks
  record Levels
    --- The level of a line that begins with each token, by the index [`Lexer.Tokens`] numbers them with: the
    --- number of bodies the token is in.
    depths: {integer}
    --- For the token that closes a body, the token a comment before the closer is moved with: the first token of
    --- the body's last statement, member or value, or, where it has none, the first token of the statement or
    --- member that holds the body (the `function` of a function written in an expression, which is laid out from
    --- the line it is written on), or 0 for the end of a chunk with no statement. Nil for any other token.
    anchors: {integer: integer}
    --- The tokens that begin a line whatever the source did: the first token of a statement, member or value, the
    --- first `|` of a `match`, and each token that closes a body (those with an anchor).
    starts: {integer: boolean}
  end

  --- The levels of the tokens of `chunk`, a parse without errors.
  of: function(chunk: Ast.Chunk): Levels
end

--- The kinds of node that are members of a `record`, `interface` or `class`, or the values of an `enum`.
local MEMBERS <const>: {string: boolean} = {
  FieldDecl = true, Record = true, Interface = true, Class = true, Enum = true, Alias = true, Import = true,
  Method = true, Userdata = true, Error = true, EnumValue = true,
}

--- The kinds of node with a body of members, closed by their own last token.
local DECLARATIONS <const>: {string: boolean} = { Record = true, Interface = true, Class = true, Enum = true }

function Blocks.of(chunk: Ast.Chunk): Blocks.Levels
  local tokens = chunk.tokens
  local count = Lexer.count(tokens)
  -- The change of level before each token, summed in token order at the end.
  local delta: mut {integer: integer} = {}
  local anchors: mut {integer: integer} = {}
  local starts: mut {integer: boolean} = {}

  --- Raises the level of tokens `first` to `last`.
  local function raise(first: integer, last: integer)
    if first <= last then
      delta[first] = (delta[first] or 0) + 1
      delta[last + 1] = (delta[last + 1] or 0) - 1
    end
  end

  -- Each node waits with the token its body is measured by where it has no statement: that of the statement or
  -- member that holds it.
  local queue: mut {Ast.Node} = { chunk }
  local owners: mut {integer} = { 0 }
  for at, node in ipairs(queue) do
    local owner = owners[at] or 0
    local kids: mut {Ast.Node} = {}
    -- Only a block and a declaration read their children's places; every node's go on the queue.
    local reads = node.kind == "Block" or DECLARATIONS[node.kind] == true
    Ast.children(node, function(child: Ast.Node)
      local kid = child
      if reads then
        kids[#kids + 1] = kid
      end
      queue[#queue + 1] = child
      if node.kind == "Block" or (DECLARATIONS[node.kind] == true and MEMBERS[kid.kind] == true) then
        owners[#owners + 1] = kid.first
      elseif node.kind == "FunctionLit" then
        owners[#owners + 1] = node.first
      else
        owners[#owners + 1] = owner
      end
    end)
    local last_kid = kids[#kids]
    if node.kind == "Block" then
      -- The statements tile the block, so it closes at the token after the last (at its first, with none).
      local close = if last_kid == nil then node.first else last_kid.last + 1 end
      if close <= count then
        -- The statements of the chunk are not in a body.
        local is_chunk = node.first == 1 and close == count
        if not is_chunk then
          raise(node.first, close - 1)
        end
        for _, kid in ipairs(kids) do
          starts[kid.first] = true
        end
        starts[close] = true
        anchors[close] = if last_kid ~= nil then last_kid.first elseif is_chunk then 0 else owner end
      end
    elseif DECLARATIONS[node.kind] == true then
      local last_member: Ast.Node? = nil
      for _, kid in ipairs(kids) do
        if MEMBERS[kid.kind] == true then
          raise(kid.first, kid.last)
          starts[kid.first] = true
          last_member = kid
        end
      end
      starts[node.last] = true
      anchors[node.last] = if last_member ~= nil then last_member.first else owner end
    elseif node.kind == "MatchArm" then
      -- The `|` before the first arm closes nothing; the others close the arm before.
      if node.first > 1 and Lexer.text(tokens, node.first - 1) == "|" then
        starts[node.first - 1] = true
      end
    end
  end

  local depths: mut {integer} = {}
  local level = 0
  for i = 1, count do
    level = level + (delta[i] or 0)
    depths[#depths + 1] = level
  end
  return { depths = depths, anchors = anchors, starts = starts }
end

return Blocks
