--- A real `Node` record for tl's parser output, and `parse()` to
--- produce one.
---
--- `tl.parse_program` returns its AST erased to `any`; every consumer
--- that reads real fields off it casts to its own narrow view at its
--- own call site today (`_tool/coverage/lines.tl`'s local `Node`,
--- `_tool/discover.tl`'s `{string: any}`). This module is that same
--- cast, done once, covering the fields tl's parser actually sets
--- across the "op"/"variable"/"identifier"/"string"/"if"/"if_block"/
--- "statements"/"return"/"expression_list" kinds -- `node_test.tl`
--- probes each of them against the pinned tl source directly, so a
--- pin bump that reshapes one fails loudly here instead of silently
--- downstream.
---
--- tl's AST has real cycles: an "if_block" node's `if_parent` points
--- back at its own enclosing "if" statement, not a copy. Array-shaped
--- nodes ("statements", a block; "expression_list", a bare list) carry
--- their elements in the table's own array part rather than a named
--- field, which `Node is {Node}` models directly instead of needing a
--- second, generic array type alongside it.
local tl = require("tl")

--- The operator payload of an "op" node. The live parser also sets
--- `arity`/`prec`/`x`/`y` on this table, but nothing outside the
--- parser reads them today; `.op` (the operator or call marker itself,
--- e.g. `"+"`, `"."`, `"@funcall"`) is the only field worth naming
--- until a real consumer needs more.
local record OpInfo
  op: string
end

--- One node of a real (post-lex, post-parse) tl AST.
---
--- Every field but `kind`/`f`/`y`/`x` is optional: which ones are set
--- depends on `kind`, and this record only names the fields the nine
--- kinds above actually carry. A field absent for a given kind reads
--- as `nil`, exactly as tl leaves it.
local record Node is {Node}
  --- The node's shape discriminator, e.g. `"op"`, `"if"`, `"statements"`.
  kind: string
  --- Source name this node was parsed under (the `name` argument to
  --- `parse`, propagated onto every node by tl's own parser).
  f: string
  --- 1-based line/column where the parser constructed this node --
  --- often mid-expression for a compound node (an "op" node's y/x sit
  --- right after its operator token, not at its left operand), so a
  --- node's true start is a property of the whole subtree, not this
  --- field alone.
  y: integer
  x: integer
  --- End position tl's parser stamped, when it stamped one at all --
  --- reliable for a "statements" block (the only place a block's true
  --- close lives) and for a bracketed list closed by its own
  --- delimiter; NOT reliable for a bare list (e.g. `return a + b`'s
  --- expression_list) stopped only by an enclosing block's own
  --- terminator three lines later. Absent on a plain leaf ("op",
  --- "variable", "identifier", "string").
  yend: integer | nil
  xend: integer | nil
  --- The raw token text this node opened on. Semantic identity for a
  --- "variable"/"identifier"/"string" leaf (its actual name or literal
  --- text); on every other kind here it is just whichever token
  --- happened to start it, incidental to the node's real shape. An
  --- "op" node has none at all.
  tk: string | nil

  -- "string": the literal payload behind `tk`'s quoted/bracketed text.
  conststr: string | nil
  is_longstring: boolean | nil

  -- "op": a binary/unary operator, an index (`.`/`[]`), or a call
  -- (`op.op == "@funcall"`/`"@method"`). Unary ops have no `e2`.
  e1: Node | nil
  e2: Node | nil
  op: OpInfo | nil

  -- "if": one `if_block` per `if`/`elseif` branch, source order.
  if_blocks: {Node} | nil
  -- "if_block": this branch's 1-based position within its `if_blocks`.
  if_block_n: integer | nil
  --- The enclosing "if" statement this "if_block" belongs to -- a REAL
  --- cycle (this node reachable from itself), not a copy or shared
  --- literal. A generic walk over `Node` needs an identity-keyed
  --- visited set to terminate, the same way `_tool/coverage/lines.tl`'s
  --- own walk already needs one for shared/cyclic nodes.
  if_parent: Node | nil
  --- "if_block": the branch's condition expression.
  exp: Node | nil
  --- "if_block": the branch's body, a "statements" node.
  body: Node | nil

  --- "return" and "local_declaration" alike: the RHS expression list.
  --- Named once here because tl's parser uses the same field name for
  --- both, not because "local_declaration" is one of this module's
  --- covered kinds.
  exps: Node | nil
end

--- One parse's result: the AST root plus the token stream it came
--- from, together -- a later comment-loss check needs both from one
--- parse, not two separate ones that could drift out of sync.
---
--- Bundled into one record rather than returned as separate slots:
--- `parse`'s first return admits nil (source that fails to lex or
--- parse), and a fallible return may declare at most two slots
--- (`cosmic --docs guide.lint`'s `fallible-returns` rule) -- the
--- extras ride on the value's record instead, per that rule's own
--- worked fix.
local record Parsed
  --- The AST root: tl's own top-level "statements" node.
  node: Node
  --- The full token stream, comments and all.
  tokens: {tl.Token}
end

--- Lex and parse `source` into a `Node` tree and its token stream.
---
--- Casts `tl.parse_program`'s erased `any` result to `Node` the same
--- way every current consumer already casts it to its own narrower
--- view at its own call site.
--- @param source string Source text to lex and parse
--- @param name string Filename used in diagnostics and stamped onto every Node's `f`
--- @param lang? string Parser dialect forwarded to `tl.parse_program` (default: tl's own)
--- @return Parsed|nil The AST root plus the token stream, or nil on failure
--- @return string Error message on failure, nil on success
local function parse(source: string, name: string, lang?: string): Parsed | nil, string
  local tokens, lex_errs = tl.lex(source, name)
  if #lex_errs > 0 then
    local e = lex_errs[1]
    return nil, string.format("%s:%d:%d: %s", name, e.y or 0, e.x or 0, e.msg or "lex error")
  end
  local parse_errs: {tl.Error} = {}
  local ast = tl.parse_program(tokens, parse_errs, name, lang)
  if #parse_errs > 0 then
    local e = parse_errs[1]
    return nil, string.format("%s:%d:%d: %s", name, e.y or 0, e.x or 0, e.msg or "parse error")
  end
  return {node = ast as Node, tokens = tokens}, nil -- cast: tl.parse_program erases its AST to `any`
end

local record NodeModule
  type OpInfo = OpInfo
  type Node = Node
  type Parsed = Parsed
  parse: function(source: string, name: string, lang?: string): Parsed | nil, string
end

local M: NodeModule = {
  parse = parse,
}

return M
