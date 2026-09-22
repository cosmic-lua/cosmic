--- A real `Node` record for tl's parser output, and `parse()` to
--- produce one.
---
--- `tl.parse_program` returns its AST erased to `any`; this module is
--- the one cast that turns it into a real shape, covering the fields
--- tl's parser actually sets across the "op"/"variable"/"identifier"/
--- "string"/"if"/"if_block"/"statements"/"return"/"expression_list"/
--- "local_function" kinds.
---
--- tl's AST has real cycles: an "if_block" node's `if_parent` points
--- back at its own enclosing "if" statement, not a copy. Array-shaped
--- nodes ("statements", a block; "expression_list", a bare list) carry
--- their elements in the table's own array part rather than a named
--- field, which `Node is {Node}` models directly instead of needing a
--- second, generic array type alongside it.
---
local type compiler = require("build.compiler")

--- The operator payload of an "op" node. The live parser also sets
--- `arity`/`prec` on this table, which nothing outside the parser reads
--- today; `.op` is the operator or call marker itself, e.g. `"+"`,
--- `"."`, `"@funcall"`.
---
--- `y`/`x` are the operator TOKEN's own position, which is the only
--- place it is recorded: an "op" node's own `y`/`x` is where the parser
--- finished building the node, and its operands have positions of their
--- own, so a renderer asking whether `..` was written at the end of one
--- line or the start of the next has nothing else to read.
local record OpInfo
  op: string
  y: integer
  x: integer
end

--- A type as tl's parser builds it: a semantic object rather than a
--- node, so it has no `kind` and `build.ast.walk` never descends into
--- one. It carries the position the type was read from, and -- where
--- the type's own syntax closes with a bracket, as `{a: b}` does -- an
--- end position too. It keeps no record of how the type was SPELLED,
--- which is why a renderer writes type syntax out as original bytes
--- rather than rebuilding it from here.
local record TypeNode
  y: integer
  x: integer
  yend: integer | nil
  xend: integer | nil
  --- The type's own shape, e.g. `"integer"`, `"map"`, `"function"`,
  --- `"nominal"`, `"record"`, `"tuple"`.
  typename: string
  --- A tuple type's members: a function's argument or return types, and
  --- the type list a `local` declaration carries after its names.
  tuple: {TypeNode} | nil
  --- A union's alternatives.
  types: {TypeNode} | nil

  --- A `"typedecl"`: the record, enum, or alias it declares, and whether
  --- it is an alias (`local type X = Y`) rather than a definition.
  def: TypeNode | nil
  is_alias: boolean | nil
  --- A `"generic"`: the type under the type arguments.
  t: TypeNode | nil
  --- A `"record"` or `"interface"`: its fields by name, the order the
  --- source declared them in, and the comments tl attached to each --
  --- one comment list per declaration of the name, so a field declared
  --- once has exactly one.
  fields: {string: TypeNode} | nil
  field_order: {string} | nil
  field_comments: {string: {{compiler.Comment}}} | nil
  --- An `"enum"`: its values, and the comments attached to each.
  enumset: {string: boolean} | nil
  value_comments: {string: {compiler.Comment}} | nil
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
  --- visited set to terminate.
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

  --- "local_function": the declared name, an "identifier" node whose
  --- own `tk` is the function's name -- `build.positions.analyze` reads
  --- this to find every top-level `test_*` function without falling
  --- back to a text pattern over the raw source.
  name: Node | nil

  --- "identifier": the Lua 5.4 variable attribute this name was
  --- declared with, `"const"` or `"close"`, as tl's parser reads it off
  --- the `<const>`/`<close>` that follows the name and BEFORE any type
  --- annotation. Structured here, so writing one back out is a question
  --- about this field rather than about the spacing of three tokens.
  attribute: string | nil

  -- "local_declaration" and "assignment": the names being bound, a
  -- "variable_list" node.
  vars: Node | nil
  --- "local_declaration": the type list written after the names, whose
  --- own position is the `:` that opens it. Empty when the declaration
  --- carries no annotation at all.
  decltuple: TypeNode | nil

  -- "local_function", "record_function", and a "function" literal.
  args: Node | nil
  rets: TypeNode | nil
  --- Comments tl's parser attached to a statement directly. The
  --- renderer reads comments off the token stream instead, uniformly,
  --- so it never has to ask which kinds carry this and which do not.
  comments: {compiler.Comment} | nil

  -- "argument": the declared type, and whether a `?` followed the name.
  argtype: TypeNode | nil
  opt: boolean | nil

  -- "cast": the type after an `as` or an `is`.
  casttype: TypeNode | nil

  -- "newtype": the record, enum, or type alias being declared.
  newtype: TypeNode | nil

  -- "local_type": the name it binds, and what it binds to -- a
  -- "newtype" node for a declaration or alias, any other expression for
  -- a `local type x = require(...)`; also a "literal_table_item"'s value.
  var: Node | nil
  value: Node | nil

  -- "literal_table_item": the key, and how the source spelled it --
  -- "implicit" (no key at all), "short" (`k = v`), or "long"
  -- (`[k] = v`).
  key: Node | nil
  key_parsed: string | nil

  -- "record_function": what the function hangs off, and whether it was
  -- declared with a `:` rather than a `.`.
  fn_owner: Node | nil
  is_method: boolean | nil
  --- "identifier", inside a method's argument list: the implicit `self`
  --- the parser inserts at the `(`'s own position, which the source
  --- never wrote.
  is_self: boolean | nil

  -- "goto" and "label": the name jumped to, or declared.
  label: string | nil

  -- "fornum": the numeric loop's bounds. `step` is absent when the
  -- source wrote none.
  from: Node | nil
  to: Node | nil
  step: Node | nil
end

--- One parse's result: the AST root plus the token stream it came
--- from, together -- a later comment-loss check needs both from one
--- parse, not two separate ones that could drift out of sync.
---
--- Bundled into one record rather than returned as separate slots:
--- `parse`'s first return admits nil (source that fails to lex or
--- parse), and a fallible return may declare at most two slots -- the
--- extras ride on the value's record instead.
local record Parsed
  --- The AST root: tl's own top-level "statements" node.
  node: Node
  --- The full token stream, comments and all.
  tokens: {compiler.Token}
end

--- Lex and parse `source` into a `Node` tree and its token stream.
---
--- Casts `parse_program`'s erased `any` result to `Node` the same way
--- every current consumer already casts it to its own narrower view at
--- its own call site.
--- @param built compiler The loaded compiler capsule (`build.teal.load()`)
--- @param source string Source text to lex and parse
--- @param name string Filename used in diagnostics and stamped onto every Node's `f`
--- @param lang? string Parser dialect forwarded to `parse_program` (default: tl's own)
--- @return Parsed|nil The AST root plus the token stream, or nil on failure
--- @return string Error message on failure, nil on success
local function parse(built: compiler, source: string, name: string,
                     lang?: string): Parsed | nil, string
  local tokens, lex_errs = built.lex(source, name)
  if #lex_errs > 0 then
    local e = lex_errs[1]
    return nil, string.format("%s:%d:%d: %s", name, e.y, e.x, e.msg)
  end
  local parse_errs: {compiler.Error} = {}
  local ast = built.parse_program(tokens, parse_errs, name, lang)
  if #parse_errs > 0 then
    local e = parse_errs[1]
    return nil, string.format("%s:%d:%d: %s", name, e.y, e.x, e.msg)
  end
  -- cast: parse_program erases its AST to `any`
  return { node = ast as Node, tokens = tokens }, nil
end

local record NodeModule
  type OpInfo = OpInfo
  type TypeNode = TypeNode
  type Node = Node
  type Parsed = Parsed
  parse: function(built: compiler, source: string, name: string,
                  lang?: string): Parsed | nil, string
end

local M: NodeModule = {
  parse = parse,
}

return M
