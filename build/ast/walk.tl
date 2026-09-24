--- Generic, cycle-guarded traversal of a `build.ast.node` `Node` tree,
--- plus span computation over it: a node's start and end position as
--- the whole subtree actually occupies, not just wherever the parser
--- happened to stamp its own `y`/`x`.
---
--- `walk` and the span functions share the same reflection: a Node's
--- CHILD-shaped fields (`e1`, `e2`, `if_blocks`, `exp`, `body`, `exps`,
--- and the array part every "statements"/"expression_list" node
--- carries) are read generically, through the table itself, rather
--- than named one by one -- so a tl node kind this module has never
--- heard of still gets walked correctly.
---
--- The one place that reflection needs care: a NAMED field can hold
--- either a real node (a `Node`) or a BARE array of nodes with no
--- position of its own (`if_blocks`; a "statements" node's own array
--- part, reached again through a DIFFERENT node's named field).
--- Checking `is {any: any}` cannot tell the two apart -- Teal's generic
--- map type structurally covers an array too, so it matches EITHER
--- shape at runtime. That was exactly the first version of this walk's
--- bug: an `elseif v is {any} then ...` fallback placed after an
--- `is {any: any}` branch never ran, so `if_blocks` was silently never
--- descended into at all. `classify` below checks the actual `kind`
--- field instead -- present as a string on every real `Node`, and on
--- nothing else reachable this way, including the "op" node's own
--- `OpInfo` payload table (`build/ast/node.tl`'s `.op` field), which
--- the live parser also stamps with `y`/`x` (arity and precedence live
--- there too) but never with `kind`. A `y`-field check reads that
--- payload as a real node too -- inert for span computation only
--- because `OpInfo.y`/`.x` duplicate the enclosing "op" node's own
--- position, but it violates `walk`'s "once per node reached" contract
--- and a consumer built on `walk` (a matcher) has no such guarantee to
--- lean on. Confirmed against a real "if" fixture and against
--- `os.execute(cmd)`'s "op" payload rather than assumed from reading
--- tl's grammar alone.
---
local type compiler = require("build.compiler")
local node_mod = require("build.ast.node")

local type Node = node_mod.Node

--- `node`'s own array part, viewed generically for `ipairs` -- every
--- "statements"/"expression_list" node's own elements, in source
--- order.
--- @param node Node
--- @return {any} The same table, viewed as an array
local function array_of(node: Node): {any}
  return node
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
--- @return Node|nil The value itself, when it is a real node (its own `kind` is a string)
--- @return {any}|nil Its elements, when it is a bare array of nodes instead
local function classify(value: any): Node | nil, {any} | nil
  if not (value is {any: any}) then
    return nil, nil
  end
  local vt = value as {any: any} -- cast: map view of a declared value
  local vkind = vt["kind"]
  if vkind is string then
    return vt as Node, nil -- cast: map view of a declared value
  end
  return nil, vt
end

--- Call `consider` once for every child value reachable from `node`'s
--- own fields, in array-part-then-named-field order -- the shared
--- reflection `walk`, `span_start` and `span_end` each fold over.
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

--- Every node `node` holds directly: a field that is a node, and each
--- node of a field that is a bare array of them -- its array part's
--- included. A field `skipped` names (one pointing back up the tree,
--- such as `if_parent`) is passed by.
--- @param node Node
--- @param skipped? {string: boolean} Field names not followed
--- @return {Node} The children, in no promised order
local function children(node: Node, skipped?: {string: boolean}): {Node}
  local out: {Node} = {}
  for _, v in ipairs(array_of(node)) do
    local child = classify(v)
    if child then
      out[#out + 1] = child
    end
  end
  for k, v in pairs(map_of(node)) do
    local passed = k is integer or (k is string and skipped ~= nil and skipped[k] == true)
    if not passed then
      local child, rest = classify(v)
      if child then
        out[#out + 1] = child
      elseif rest then
        for _, e in ipairs(rest) do
          local grandchild = classify(e)
          if grandchild then
            out[#out + 1] = grandchild
          end
        end
      end
    end
  end
  return out
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
--- @return integer The 1-based line
--- @return integer The 1-based column
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
--- IS the position to match against: `t.x` is a token's START column
--- while the `xend` this is matched against (`trusted_end` below) is
--- the INCLUSIVE last column of whatever it was stamped from, and
--- those two only ever coincide for a token exactly one character
--- wide -- true of every close bracket, which is why a plain equality
--- check on (`y`, `x`) suffices here and would not for a multi-column
--- token.
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
--- @param tokens {compiler.Token} The token stream from the SAME parse
---   (`Parsed.tokens`) -- needed for the bracket check above. A raw byte
---   offset for splicing is a different need, `build.ast.rewrite`'s job.
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
  walk: function(node: Node, visit: function(Node))
  children: function(node: Node, skipped?: {string: boolean}): {Node}
  span_start: function(node: Node): integer, integer
  span_end: function(node: Node, tokens: {compiler.Token}): integer, integer
end

local M: WalkModule = {
  walk = walk,
  children = children,
  span_start = span_start,
  span_end = span_end,
}

return M
