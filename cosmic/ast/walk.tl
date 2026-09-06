--- Generic, cycle-guarded traversal of a `cosmic.ast.node` `Node` tree,
--- plus span computation over it: a node's start and end position as
--- the whole subtree actually occupies, not just wherever the parser
--- happened to stamp its own `y`/`x`.
---
--- `walk` and the span functions share the same reflection: a Node's
--- CHILD-shaped fields (`e1`, `e2`, `if_blocks`, `exp`, `body`, `exps`,
--- and the array part every "statements"/"expression_list" node
--- carries) are read generically, through the table itself, rather
--- than named one by one -- so a tl node kind this module has never
--- heard of still gets walked correctly, the same way
--- `docs/design/ast-rewrite/tlgrep.tl`'s own generic match does.
---
--- The one place that reflection needs care: a NAMED field can hold
--- either a real node (its own `y` is set) or a BARE array of nodes
--- with no position of its own (`if_blocks`; a "statements" node's own
--- array part, reached again through a DIFFERENT node's named field).
--- Checking `is {any: any}` cannot tell the two apart -- Teal's generic
--- map type structurally covers an array too, so it matches EITHER
--- shape at runtime. That was exactly the first version of this walk's
--- bug: an `elseif v is {any} then ...` fallback placed after an
--- `is {any: any}` branch never ran, so `if_blocks` was silently never
--- descended into at all. `classify` below checks the actual `y` field
--- instead, confirmed against a real "if" fixture rather than assumed
--- from reading tl's grammar alone.
local tl = require("tl")
local node_mod = require("cosmic.ast.node")

local type Node = node_mod.Node

--- `node`'s own array part, viewed generically for `ipairs` -- every
--- "statements"/"expression_list" node's own elements, in source
--- order.
--- @param node Node
--- @return {any} The same table, viewed as an array
local function array_of(node: Node): {any}
  return node as {any} -- cast: map view of a declared value
end

--- `node`'s own table, viewed generically for `pairs` -- named fields
--- and array part alike, since Lua's `pairs` walks every key
--- regardless of how Teal typed them.
--- @param node Node
--- @return {any: any} The same table, viewed as a generic map
local function map_of(node: Node): {any: any}
  return node as {any: any} -- cast: map view of a declared value
end

--- Classify one value found while reflecting over a Node's fields.
--- @param value any A field value, or an array element
--- @return Node|nil The value itself, when it is a real node (its own `y` is set)
--- @return {any}|nil Its elements, when it is a bare array of nodes instead
local function classify(value: any): Node | nil, {any} | nil
  if not (value is {any: any}) then
    return nil, nil
  end
  local vt = value as {any: any} -- cast: map view of a declared value
  local vy = vt["y"]
  if vy is integer then
    return vt as Node, nil -- cast: map view of a declared value
  end
  return nil, vt
end

--- Call `consider` once for every child value reachable from `node`'s
--- own fields, in array-part-then-named-field order -- the shared
--- reflection `walk`, `span_start` and `span_end` each fold over.
--- @param node Node
--- @param consider function(any) Called once per array element and per named field's value
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

--- Walk `node`'s subtree in depth-first order, calling `visit` once on
--- every node reached, `node` itself first. Cycle-guarded by identity:
--- an "if_block" node's `if_parent` points back at its own enclosing
--- "if" statement, a real cycle rather than a copy, so a plain
--- recursive descent would loop forever without one.
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

--- The start position of `node`'s own SPAN: the minimum position over
--- the whole subtree, not just `node.y`/`node.x`. tl's parser stamps a
--- compound node's `y`/`x` where it FINISHED constructing the node,
--- which for a call or a binary op is often mid-expression -- e.g.
--- `os.execute(cmd)`'s "@funcall" op node records the position right
--- after `(`, not `os`'s own leftmost column.
--- @param node Node
--- @return integer, integer 1-based line, column
local function span_start(node: Node): integer, integer
  local function compute(n: Node, seen: {Node: boolean}): integer, integer
    local by, bx = n.y, n.x
    if seen[n] then
      return by, bx
    end
    seen[n] = true
    each_child(n, function(value: any)
        local child, rest = classify(value)
        if child then
          local cy, cx = compute(child, seen)
          if cy < by or (cy == by and cx < bx) then
            by, bx = cy, cx
          end
        elseif rest then
          for _, e in ipairs(rest) do
            local gc = classify(e)
            if gc then
              local cy, cx = compute(gc, seen)
              if cy < by or (cy == by and cx < bx) then
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

--- Is there a real close-bracket token -- `)`, `]`, or `}` -- at
--- 1-based (`y`, `x`)? A single-character token, so its own position
--- IS the position to match against.
--- @param tokens {tl.Token} The token stream from the SAME parse as the node
--- @param y integer
--- @param x integer
--- @return boolean
local function is_close_bracket_at(tokens: {tl.Token}, y: integer, x: integer): boolean
  for _, t in ipairs(tokens) do
    if t.y == y and t.x == x then
      return t.tk == ")" or t.tk == "]" or t.tk == "}"
    end
  end
  return false
end

--- The end position of `node`'s own SPAN: the inclusive last column of
--- its own last token, over the whole subtree.
---
--- `yend`/`xend`, where the parser stamped one at all, need a two-way
--- gate: a "statements" (block) node's own `yend`/`xend` IS its true
--- end -- the terminator that stopped it (`end`/`else`/`until`) is the
--- ONLY place a block's true close lives, since an empty or short
--- block has no descendant token that reaches it. Every OTHER kind's
--- `yend`/`xend` comes from the same generic list parser, correct when
--- the terminator is a real delimiter belonging to the node itself (a
--- call's `)`), but for a list with none of its own (`return a + b`'s
--- `expression_list`, stopped only by the ENCLOSING block's `end`
--- three lines later) it points at someone else's token -- the same
--- `kind` (`expression_list`) either way, so the kind alone cannot
--- tell the two apart. This checks the actual token at the reported
--- position instead: trust it only when it is a real close-bracket,
--- otherwise recurse to the real leftmost/rightmost descendant leaf --
--- confirmed against `os.execute(cmd)` and a bare `return a + b` both
--- landing correctly, not assumed from reading the parser alone.
--- @param node Node
--- @param tokens {tl.Token} The token stream from the SAME parse (`Parsed.tokens`) --
---   needed for the bracket check above. A raw byte offset for splicing is a
---   different need, taken on by the ast-rewrite item instead, not this one.
--- @return integer, integer 1-based line, column
local function span_end(node: Node, tokens: {tl.Token}): integer, integer
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
  walk: function(node: Node, visit: function(Node))
  span_start: function(node: Node): integer, integer
  span_end: function(node: Node, tokens: {tl.Token}): integer, integer
end

local M: WalkModule = {
  walk = walk,
  span_start = span_start,
  span_end = span_end,
}

return M
