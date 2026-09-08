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

local type Node = node_mod.Node

local record Child
  node: Node
  role: string
end

local array_kinds: {string: string} = {
  statements = "statement",
  argument_list = "argument",
  literal_table = "item",
  variable_list = "variable",
  expression_list = "expression",
}

local no_child_kinds: {string: boolean} = {
  ["..."] = true, ["nil"] = true, ["cast"] = true, ["goto"] = true,
  ["break"] = true, ["label"] = true, ["number"] = true,
  ["pragma"] = true, ["string"] = true, ["boolean"] = true,
  ["integer"] = true, ["variable"] = true, ["error_node"] = true,
  ["identifier"] = true, ["type_identifier"] = true, ["argument"] = true,
  ["newtype"] = true,
}

local function as_node(value: any): Node | nil
  if value is {any: any} then
    local kind = value["kind"]
    if kind is string then
      return value as Node -- cast: parser node identified by its discriminator
    end
  end
  return nil
end

local function field(node: Node, name: string): any
  return (node as {any: any})[name] -- cast: grammar-owned parser field
end

local function append(out: {Child}, value: any, role: string)
  local child = as_node(value)
  if child then
    out[#out + 1] = {node = child, role = role}
  end
end

--- Return syntax children in deterministic grammar order.
--- Unknown kinds are opaque, and backlinks such as `if_parent` are excluded.
--- @param node Node
--- @return {Child} Child nodes and their roles
local function children(node: Node): {Child}
  local out: {Child} = {}
  local array_role = array_kinds[node.kind]
  if array_role then
    for i, child in ipairs(node as {any}) do
      append(out, child, array_role .. "[" .. i .. "]")
    end
    return out
  end

  local kind = node.kind
  if kind == "op" then
    append(out, field(node, "e1"), "left")
    if field(node, "e2") ~= nil then
      local op = node.op
      append(out, field(node, "e2"),
        (op and (op.op == "as" or op.op == "is")) and "type_operand" or "right")
    end
  elseif kind == "literal_table_item" then
    append(out, field(node, "key"), "key")
    append(out, field(node, "value"), "value")
  elseif kind == "assignment" or kind == "local_declaration"
  or kind == "global_declaration" then
    append(out, field(node, "vars"), "declarations")
    append(out, field(node, "exps"), "values")
  elseif kind == "local_type" or kind == "global_type" then
    append(out, field(node, "var"), "declaration_name")
    append(out, field(node, "value"), "type_value")
  elseif kind == "if" then
    local blocks = field(node, "if_blocks")
    if blocks is {any} then
      for i, block in ipairs(blocks) do
        append(out, block, "branch[" .. i .. "]")
      end
    end
  elseif kind == "if_block" then
    append(out, field(node, "exp"), "condition")
    append(out, field(node, "body"), "body")
  elseif kind == "while" then
    append(out, field(node, "exp"), "condition")
    append(out, field(node, "body"), "body")
  elseif kind == "repeat" then
    append(out, field(node, "body"), "body")
    append(out, field(node, "exp"), "condition")
  elseif kind == "macroexp" then
    append(out, field(node, "args"), "parameters")
    append(out, field(node, "exp"), "value")
  elseif kind == "function" then
    append(out, field(node, "args"), "parameters")
    append(out, field(node, "body"), "body")
  elseif kind == "local_function" or kind == "global_function" then
    append(out, field(node, "name"), "declaration_name")
    append(out, field(node, "args"), "parameters")
    append(out, field(node, "body"), "body")
  elseif kind == "record_function" then
    append(out, field(node, "fn_owner"), "owner")
    append(out, field(node, "name"), "declaration_name")
    append(out, field(node, "args"), "parameters")
    append(out, field(node, "body"), "body")
  elseif kind == "local_macroexp" then
    append(out, field(node, "name"), "declaration_name")
    local macrodef = field(node, "macrodef")
    if macrodef is {any: any} then
      append(out, macrodef["args"], "parameters")
      append(out, macrodef["exp"], "value")
    end
  elseif kind == "forin" then
    append(out, field(node, "vars"), "declarations")
    append(out, field(node, "exps"), "values")
    append(out, field(node, "body"), "body")
  elseif kind == "fornum" then
    append(out, field(node, "var"), "declaration")
    append(out, field(node, "from"), "start")
    append(out, field(node, "to"), "stop")
    append(out, field(node, "step"), "step")
    append(out, field(node, "body"), "body")
  elseif kind == "return" then
    append(out, field(node, "exps"), "values")
  elseif kind == "do" then
    append(out, field(node, "body"), "body")
  elseif kind == "paren" then
    append(out, field(node, "e1"), "expression")
  else
    local _known_leaf = no_child_kinds[kind]
  end
  return out
end

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
    for _, child in ipairs(children(n)) do
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
    for _, child in ipairs(children(n)) do
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
    for _, child in ipairs(children(n)) do
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
  type Child = Child
  children: function(node: Node): {Child}
  walk: function(node: Node, visit: function(Node))
  span_start: function(node: Node): integer, integer
  span_end: function(node: Node, tokens: {tl.Token}): integer, integer
end

local M: WalkModule = {
  children = children,
  walk = walk,
  span_start = span_start,
  span_end = span_end,
}

return M
