--- Generic, cycle-guarded traversal of a [`build.ast.node`] [`Node`] tree,
--- plus span computation over it: a node's start and end position as
--- the whole subtree actually occupies, not just wherever the parser
--- happened to stamp its own `y`/`x`.
---
--- `walk` and the span functions read a Node's child-shaped fields
--- (`e1`, `e2`, `if_blocks`, `exp`, `body`, `exps`, and the array part
--- of every "statements"/"expression_list" node) generically, through
--- the table itself rather than by name, so a tl node kind this module
--- does not know still gets walked.
---
--- A named field holds either a real node or a bare array of nodes
--- with no position of its own (`if_blocks`; a "statements" node's
--- array part, reached through another node's named field). Testing
--- `is {any: any}` cannot tell them apart, because Teal's generic map
--- type also matches an array at runtime, so an `is {any}` fallback
--- placed after it never runs and `if_blocks` would never be entered.
--- `classify` checks the `kind` field instead. Every real [`Node`] has a
--- string `kind`, and nothing else reachable this way does. That
--- includes the "op" node's `OpInfo` payload ([`build/ast/node.tl`]),
--- which the parser stamps with `y`/`x` but not `kind`. Taking it for a
--- node would break `walk`'s "once per node reached" contract, though
--- span computation would not notice, since [`OpInfo.y`]/`.x` repeat the
--- "op" node's own position.
local type compiler = require("build.compiler")
local node_mod = require("build.ast.node")

local type Node = node_mod.Node

--- `node`'s array part, viewed generically for `ipairs`: the elements
--- of a "statements" or "expression_list" node, in source order.
--- @param node Node
--- @return {any} The same table, viewed as an array
local function array_of(node: Node): {any}
  return node
end

--- `node`'s table, viewed generically for `pairs`, which walks named
--- fields and array part alike.
--- @param node Node
--- @return {any: any} The same table, viewed as a generic map
local function map_of(node: Node): {any: any}
  return node as {any: any} -- cast: map view of a declared value
end

--- Classify one value found while reflecting over a Node's fields.
--- @param value any A field value, or an array element
--- @return Node|nil The value itself, when it is a real node (its own `kind` is a string)
--- @return {any}|nil Its elements, when it is a bare array of nodes instead
local function classify(value: any): Node | nil, {any} | nil
  if not (value is Node) then
    return nil, nil
  end
  local kind = value.kind
  if kind is string then
    return value, nil
  end
  return nil, value
end

--- Call `consider` once for every child value in `node`'s fields, array
--- part first and then the named fields. `walk` and [`span_end`] are
--- each a fold over it; [`span_start`] writes the same step out.
--- @param node Node
--- @param consider function(any) Called once per array element and per named field
local function each_child(node: Node, consider: function(any))
  for _, v in ipairs(array_of(node)) do
    consider(v)
  end
  for k, v in pairs(map_of(node)) do
    if not (k is integer) then
      consider(v)
    end
  end
end

--- Adds `v` to `into`: itself when it is a node, its nodes when it is
--- a bare array of them.
local function add(into: {Node}, v: any)
  local child, rest = classify(v)
  if child then
    into[#into + 1] = child
  elseif rest then
    for _, e in ipairs(rest) do
      local grandchild = classify(e)
      if grandchild then
        into[#into + 1] = grandchild
      end
    end
  end
end

--- Every node `node` holds directly: a field that is a node, and each
--- node of a field that is a bare array of them -- its array part's
--- included. A field `skipped` names (one pointing back up the tree,
--- such as `if_parent`) is passed by. When `passed` is given, what
--- `walk` would reach from `node` that this does not is added to it:
--- the nodes of a field `skipped` names, and of a bare array in the
--- array part, so the two lists together are `walk`'s step.
--- @param node Node
--- @param skipped? {string: boolean} Field names not followed
--- @param passed? {Node} Filled with the nodes passed by
--- @return {Node} The children, in no promised order
local function children(node: Node, skipped?: {string: boolean}, passed?: {Node}): {Node}
  local out: {Node} = {}
  for _, v in ipairs(array_of(node)) do
    local child, rest = classify(v)
    if child then
      out[#out + 1] = child
    elseif rest and passed ~= nil then
      add(passed, v)
    end
  end
  for k, v in pairs(map_of(node)) do
    if not (k is integer) then
      if k is string and skipped ~= nil and skipped[k] == true then
        if passed ~= nil then add(passed, v) end
      else
        add(out, v)
      end
    end
  end
  return out
end

--- Calls `visit` on each node [`children`] lists for `node` and
--- `skipped`, in the same order, without making the list: a walk that
--- descends through every node of a file saves a table for each.
--- `visit` must not change `node`.
--- @param node Node
--- @param skipped? {string: boolean} Field names not followed
--- @param visit function(Node) Called once per child
local function each_child_node(node: Node, skipped: {string: boolean} | nil, visit: function(Node))
  for _, v in ipairs(array_of(node)) do
    local child = classify(v)
    if child then visit(child) end
  end
  for k, v in pairs(map_of(node)) do
    if not (k is integer) and not (k is string and skipped ~= nil and skipped[k] == true) then
      local child, rest = classify(v)
      if child then
        visit(child)
      elseif rest then
        for _, e in ipairs(rest) do
          local grandchild = classify(e)
          if grandchild then visit(grandchild) end
        end
      end
    end
  end
end

--- Walk `node`'s subtree in depth-first order, calling `visit` once on
--- every node reached, `node` itself first. A guard by identity stops
--- the cycle through an "if_block" node's `if_parent`, which points
--- back at its enclosing "if" statement.
--- @param node Node The subtree root
--- @param visit function(Node) Called once per node, in depth-first order
local function walk(node: Node, visit: function(Node))
  local seen: {Node: boolean} = {}
  local function go(n: Node)
    if seen[n] then
      return
    end
    seen[n] = true
    visit(n)
    each_child(n, function(value: any)
      local child, rest = classify(value)
      if child then
        go(child)
      elseif rest then
        for _, e in ipairs(rest) do
          local gc = classify(e)
          if gc then
            go(gc)
          end
        end
      end
    end)
  end
  go(node)
end

--- The start of `node`'s span: the minimum position over the subtree,
--- not just `node.y`/`node.x`. tl's parser stamps a compound node's
--- `y`/`x` where it finished building the node, often mid-expression:
--- the "@funcall" op node of `os.execute(cmd)` records the position
--- after `(`, not the column of `os`.
---
--- `memo`, when given, keeps every subtree's start as it is found and
--- is read first, so one table shared across calls over a tree walks
--- each subtree once. A start found while walking up a link back to an
--- ancestor (an `if_block`'s `if_parent`) counts that ancestor at its
--- own position, which is its subtree's start: an `if` opens on its
--- keyword.
--- @param node Node
--- @param memo? {Node: {integer}} Starts already found, and where to keep new ones
--- @return integer The 1-based line
--- @return integer The 1-based column
local function span_start(node: Node, memo?: {Node: {integer}}): integer, integer
  local seen: {Node: boolean} = {}
  local compute: function(Node): integer, integer
  -- The earlier of (`by`, `bx`) and where child field `value` starts.
  -- It is [`each_child`]'s step written out, with no closure made per
  -- node: this runs once for every node a renderer asks about.
  local function fold(value: any, by: integer, bx: integer): integer, integer
    local child, rest = classify(value)
    if child then
      local cy, cx = compute(child)
      if cy < by or (cy == by and cx < bx) then
        return cy, cx
      end
    elseif rest then
      for _, e in ipairs(rest) do
        local gc = classify(e)
        if gc then
          local cy, cx = compute(gc)
          if cy < by or (cy == by and cx < bx) then
            by, bx = cy, cx
          end
        end
      end
    end
    return by, bx
  end
  compute = function(n: Node): integer, integer
    local known = memo ~= nil and memo[n] or nil
    if known ~= nil then
      return known[1], known[2]
    end
    local by, bx = n.y, n.x
    if seen[n] then
      return by, bx
    end
    seen[n] = true
    for _, v in ipairs(array_of(n)) do
      by, bx = fold(v, by, bx)
    end
    for k, v in pairs(map_of(n)) do
      if not (k is integer) then
        by, bx = fold(v, by, bx)
      end
    end
    if memo ~= nil then
      memo[n] = { by, bx }
    end
    return by, bx
  end
  return compute(node)
end

--- Is there a close-bracket token, `)`, `]` or `}`, at 1-based (`y`, `x`)?
--- `t.x` is a token's first column and the `xend` compared with it
--- (see `trusted_end`) is the inclusive last column. They coincide only
--- for a one-character token, which every close bracket is, so
--- comparing (`y`, `x`) suffices here and would not for a longer token.
--- @param tokens {compiler.Token} The token stream from the SAME parse as the node
--- @param y integer
--- @param x integer
--- @return boolean
local function is_close_bracket_at(tokens: {compiler.Token},
                                   y: integer, x: integer): boolean
  for _, t in ipairs(tokens) do
    if t.y == y and t.x == x then
      return t.tk == ")" or t.tk == "]" or t.tk == "}"
    end
  end
  return false
end

--- The end of `node`'s span: the inclusive last column of the last
--- token in the subtree.
---
--- Where the parser stamped a `yend`/`xend`, it is trusted in two
--- cases. A "statements" (block) node's is its true end: the
--- terminator that stopped it (`end`, `else`, `until`) is the only
--- place an empty or short block's close lives. Any other kind's comes
--- from the generic list parser. It is right when the node owns its
--- terminator (a call's `)`), but a list with none of its own, like the
--- `expression_list` of `return a + b`, ends at the enclosing block's
--- `end`, which may be lines later. Both cases have the same kind, so
--- the token at the reported position decides: it is trusted only
--- when it is a close bracket. Otherwise the end is that of the last
--- descendant.
--- @param node Node
--- @param tokens {compiler.Token} The token stream from the same parse
---   ([`Parsed.tokens`]), for the bracket check
--- @return integer The 1-based line
--- @return integer The 1-based column
local function span_end(node: Node, tokens: {compiler.Token}): integer, integer
  local function trusted_end(n: Node, by: integer, bx: integer): integer, integer
    local yend, xend = n.yend, n.xend
    if yend is integer and xend is integer then
      if n.kind == "statements" or is_close_bracket_at(tokens, yend, xend) then
        if yend > by or (yend == by and xend > bx) then
          return yend, xend
        end
      end
    end
    return by, bx
  end
  local function compute(n: Node, seen: {Node: boolean}): integer, integer
    local by, bx = n.y, n.x
    local tk = n.tk
    if tk is string then
      bx = bx + #tk - 1
    end
    by, bx = trusted_end(n, by, bx)
    if seen[n] then
      return by, bx
    end
    seen[n] = true
    each_child(n, function(value: any)
      local child, rest = classify(value)
      if child then
        local cy, cx = compute(child, seen)
        if cy > by or (cy == by and cx > bx) then
          by, bx = cy, cx
        end
      elseif rest then
        for _, e in ipairs(rest) do
          local gc = classify(e)
          if gc then
            local cy, cx = compute(gc, seen)
            if cy > by or (cy == by and cx > bx) then
              by, bx = cy, cx
            end
          end
        end
      end
    end)
    return by, bx
  end
  return compute(node, {})
end

local record WalkModule
  --- A place in the source: 1-based line and column.
  record Position
    y: integer
    x: integer
  end
  walk: function(node: Node, visit: function(Node))
  children: function(node: Node, skipped?: {string: boolean}, passed?: {Node}): {Node}
  each_child_node: function(node: Node, skipped: {string: boolean} | nil, visit: function(Node))
  span_start: function(node: Node, memo?: {Node: {integer}}): Position
  span_end: function(node: Node, tokens: {compiler.Token}): Position
end

local M: WalkModule = {
  walk = walk,
  children = children,
  each_child_node = each_child_node,
  span_start = function(node: Node, memo?: {Node: {integer}}): WalkModule.Position
    local y, x = span_start(node, memo)
    return { y = y, x = x }
  end,
  span_end = function(node: Node, tokens: {compiler.Token}): WalkModule.Position
    local y, x = span_end(node, tokens)
    return { y = y, x = x }
  end,
}

return M
