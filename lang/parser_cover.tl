--- Whether a parse is well formed, whatever the source and the errors found
--- in it: the check that the syntax tree is a tree over the tokens
--- ([`doc/plans/new-checker-grammar.md`], "the syntax tree"), as
--- [`lang.lexer_cover`] checks the tokens tile the source.
---
--- Each node names tokens that exist: `first` to `last`, or an empty range
--- (`first` one past `last`) where a failed production skipped nothing. A
--- child lies within its parent and the children of one node come in source
--- order, none beginning before its elder sibling ends. The statements of a
--- block tile it: the first begins where the block does, each begins at the
--- token after the one before it ends, and the last is followed by the
--- terminator that ends the block, which is the block's `last` and `close`, or
--- just after its `last` where the construct around the block did not close. The
--- chunk spans every token. Ids are 1 for the chunk and count up in a
--- pre-order walk, and every require names a node. Every error has a code, a
--- message and a fix, lies within the source and comes in source order.
local Ast = require("lang.ast")
local Lexer = require("lang.lexer")
local Parser = require("lang.parser")

local record Cover
  --- Whether `parsed`, the parse of `source`, is well formed, or `false` and
  --- the first way it is not.
  check: function(source: string, parsed: Parser.Parsed): boolean, string
end

local TERMINATORS <const>: {string: boolean} = { ["end"] = true, ["else"] = true, ["elseif"] = true, ["until"] = true, ["|"] = true, [""] = true }

local record Walk
  chunk: Ast.Chunk
  mut count: integer
  mut problem: string
  ids: mut {integer: boolean}
end

local function base_of(node: Ast.Node): Ast.Base
  return node
end

--- Records the first problem of the node `node` and of what is below it.
local function walk(node: Ast.Node, parent: Ast.Node, state: Walk)
  if state.problem ~= "" then
    return
  end
  local b = base_of(node)
  local at = node.kind .. " at tokens " .. tostring(b.first) .. " to " .. tostring(b.last)
  state.count = state.count + 1
  if b.id ~= state.count then
    state.problem = at .. " has id " .. tostring(b.id) .. ", not " .. tostring(state.count)
    return
  end
  state.ids[state.count] = true
  local tokens = state.chunk.tokens
  if b.first < 1 or b.last > #tokens.kind or b.first > b.last + 1 then
    state.problem = at .. " names tokens outside the chunk or backwards"
    return
  end
  if b.first < parent.first or b.last > parent.last then
    state.problem = at .. " is not within its parent, " .. parent.kind .. " at tokens " .. tostring(parent.first) .. " to " .. tostring(parent.last)
    return
  end
  local previous: {integer} = { parent.first - 1 }
  Ast.children(node, function(child: Ast.Node)
    local c = base_of(child)
    if c.first <= previous[1] and state.problem == "" then
      state.problem = at .. " has a child, " .. child.kind .. " at tokens " .. tostring(c.first) .. " to " .. tostring(c.last) .. ", that begins before its elder sibling ends"
    end
    walk(child, node, state)
    previous[1] = math.max(previous[1], c.last)
  end)
  if (node.kind == "Block") then
    local expected = node.first
    for _, stat in ipairs(node.stats) do
      local s = base_of(stat)
      if s.first ~= expected and state.problem == "" then
        state.problem = at .. " does not tile: " .. stat.kind .. " begins at token " .. tostring(s.first) .. ", not " .. tostring(expected)
      end
      expected = s.last + 1
    end
    -- The terminator is the block's own, unless the construct around the block did not consume it.
    if state.problem == "" and (expected ~= node.close or (node.last ~= node.close and node.last ~= node.close - 1) or
        not TERMINATORS[Lexer.text(tokens, node.close)]) then
      state.problem = at .. " does not end at its terminator: its statements end at token " .. tostring(expected - 1) .. ", it closes at " .. tostring(node.close)
    end
  end
end

function Cover.check(source: string, parsed: Parser.Parsed): boolean, string
  local chunk = parsed.chunk
  if chunk.first ~= 1 or chunk.last ~= #chunk.tokens.kind or chunk.id ~= 1 then
    return false, "the chunk does not span the tokens or is not node 1"
  end
  local state: Walk = { chunk = chunk, count = 1, problem = "", ids = { true } }
  Ast.children(chunk, function(child: Ast.Node)
    walk(child, chunk, state)
  end)
  if state.problem ~= "" then
    return false, state.problem
  end
  for _, r in ipairs(chunk.requires) do
    if not state.ids[r.node] then
      return false, "the require of " .. r.module .. " names node " .. tostring(r.node) .. ", which does not exist"
    end
  end
  local at = 0
  for _, e in ipairs(parsed.errors) do
    if e.offset < 1 or e.length < 0 or e.offset + e.length - 1 > #source or e.offset < at then
      return false, e.code .. " error at offset " .. tostring(e.offset) .. " lies outside the source or out of order"
    end
    if e.msg == "" or e.fix == "" then
      return false, e.code .. " error at " .. tostring(e.y) .. ":" .. tostring(e.x) .. " has no message or no fix"
    end
    at = e.offset
  end
  return true, ""
end

return Cover
