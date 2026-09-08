--- Grammar-defined traversal of a `cosmic.ast.node` `Node` tree,
--- plus span computation over it: a node's start and end position as
--- the whole subtree actually occupies, not just wherever the parser
--- happened to stamp its own `y`/`x`.
---
--- `children`, `walk`, and the span functions share the parser's explicit
--- node-child schema. It follows only syntax edges and never reflects over
--- compiler metadata or the `if_parent` backlink. Unknown node kinds are
--- opaque: adding a parser kind cannot silently make a metadata table part
--- of the public syntax tree.
local tl = require("tl")
local node_mod = require("cosmic.ast.node")
local children_mod = require("cosmic.ast.children")

local type Node = node_mod.Node

--- Walk `node`'s subtree in deterministic depth-first order.
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
    for _, child in ipairs(children_mod.children(n)) do
      go(child.node)
    end
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
    for _, child in ipairs(children_mod.children(n)) do
      local cy, cx = compute(child.node, seen)
      if cy < by or (cy == by and cx < bx) then
        by, bx = cy, cx
      end
    end
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
--- @return integer The 1-based line
--- @return integer The 1-based column
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
    for _, child in ipairs(children_mod.children(n)) do
      local cy, cx = compute(child.node, seen)
      if cy > by or (cy == by and cx > bx) then
        by, bx = cy, cx
      end
    end
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
