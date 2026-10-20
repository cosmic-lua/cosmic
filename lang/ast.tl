--- The syntax tree of the new checker's grammar
--- ([`doc/plans/new-checker-grammar.md`], "the syntax tree"), which
--- [`lang.parser`] builds.
---
--- [`Node`] is a tagged union on `kind`. A node is a range of tokens: `first`
--- and `last` index [`Chunk.tokens`], and a place is read from them
--- ([`Ast.span`]), so a node holds no line or column. A block ends at its
--- terminator and a statement at its last token, so the statements of a block
--- tile its tokens (an [`Error`] node holds the tokens a failed production
--- skipped). The tree holds only tokens and nodes the source has, and no node
--- points up. A node's `id` is its position in a pre-order walk of the tree
--- ([`Ast.number`]), 1 for the chunk.
---
--- A name that introduces something is a [`Binding`]; a name that refers to
--- something is a [`Name`], a [`Field`] or a path of a [`TypeName`]. The scope
--- builder, not the parser, sets which [`Binding`] a [`Name`] refers to.
---
--- A comment that is a doc comment is on the node it documents (`doc`), a
--- [`Binding`] for a local or a type, a [`Function`], a [`FieldDecl`], a [`Method`] or an
--- [`EnumValue`].
---
--- [`Ast.fields`] lists the structural fields of each kind in source order,
--- so that a walker needs no code per kind ([`Ast.children`]). A tree is as
--- deep as its source nests, and as a chain of `a + a + ...` is long, so a
--- recursive walker can overflow the stack where [`Ast.number`] does not.

-- TODO: at the switch, replace each `where` clause with the single-member enum tag the
-- plan's tagged unions use, write each test `n is Ast.Local` of a node (here and in every
-- module that imports this one) as a tag test or a `match` in the same change, and read the
-- nodes in `number` and `children` by their kinds in place of as `{string: any}`
-- (doc/plans/strict-teal.md, "the switch"): the new code generator writes a test `is` of a
-- record as one for a table once the clause is gone, and of a union of unions as well. The
-- pinned release is the fork's, which discriminates only by a `where` clause, so nothing
-- earlier makes this due.
local Lexer = require("lang.lexer")

local record Ast
  enum Kind
    "Chunk" "Block"
    -- statements
    "Local" "LocalFunction" "Function" "Assign" "CallStat" "Return" "Do" "Break" "Continue"
    "While" "Repeat" "If" "Arm" "Match" "MatchArm" "PatBool" "PatBind" "ForNum" "ForIn"
    -- expressions
    "Name" "Nil" "Boolean" "Integer" "Float" "String" "Vararg" "Paren" "FunctionLit" "Table"
    "Positional" "Named" "Keyed" "Field" "Index" "Call" "MethodCall" "Unary" "Binary"
    "IsTest" "Cast" "IfExp" "ExpArm"
    -- function parts
    "Fn" "Rets" "Param" "Binding"
    -- types
    "TypeName" "TypeBool" "TypeNil" "TypeError" "TypeArray" "TypeMap" "TypeUnion" "TypeOptional"
    "TypeMut" "TypeFunction" "PType" "Narrows" "TypeParam"
    -- declarations
    "Record" "Interface" "Class" "Enum" "EnumValue" "Alias" "Import" "FieldDecl" "Method" "Userdata"
    -- a failed production
    "Error"
  end

  --- `local` or `global`: how a declaration is introduced. Nil for a
  --- declaration nested in a body.
  enum Scope
    "local"
    "global"
  end

  enum Attr
    "const"
    "close"
  end

  enum UnaryOp
    "not"
    "#"
    "-"
    "~"
  end

  --- A binary operator. One field of the node, not a node of its own, so a
  --- reader tells operators apart by `op` and not by the shape of a nested token.
  enum BinaryOp
    "or" "and" "<" ">" "<=" ">=" "~=" "==" "|" "~" "&" "<<" ">>" ".." "+" "-" "*" "/" "//" "%" "^"
  end

  --- `tl` is a program; `decl` a declaration file (`.d.tl`).
  enum Dialect
    "tl"
    "decl"
  end

  --- What every node holds.
  interface Base
    kind: Kind
    --- The indexes in [`Chunk.tokens`] of its first and last token.
    first: integer
    last: integer
    --- Set by [`Ast.number`]; 0 before. A node is made with the field so that numbering
    --- does not grow its table.
    id: integer
  end

  record Chunk is Base
    where self.kind == "Chunk"
    body: Block
    tokens: Lexer.Tokens
    requires: {Require}
  end

  --- A place, 1-based, in bytes, of the first byte of a node and of its last
  --- as [`lang.lexer`]'s tokens give them.
  record Span
    y: integer
    x: integer
    yend: integer
    xend: integer
  end

  --- A literal `require("m")` call, or a type import of one.
  record Require
    module: string
    --- The id of the [`Call`] or the [`Import`].
    node: integer
  end

  --- Its last token is the one that ended it: `end`, `else`, `elseif`,
  --- `until`, `}`-less, or the `$EOF$` of the chunk. `close` is that token's index.
  record Block is Base
    where self.kind == "Block"
    stats: {Stat}
    close: integer
  end

  record Local is Base
    where self.kind == "Local"
    scope: Scope
    bindings: {Binding}
    types: {Type}
    values: {Exp}
  end
  record LocalFunction is Base
    where self.kind == "LocalFunction"
    name: Binding
    typeparams: {TypeParam}
    fn: Fn
  end
  --- `function R.m(...)`: `path` is `R` and `m`. Its `doc` is the doc comment of the statement.
  record Function is Base
    where self.kind == "Function"
    path: {Name}
    typeparams: {TypeParam}
    fn: Fn
    doc?: {Lexer.Comment}
  end
  record Assign is Base
    where self.kind == "Assign"
    targets: {Exp}
    values: {Exp}
  end
  record CallStat is Base
    where self.kind == "CallStat"
    call: CallExp
  end
  record Return is Base
    where self.kind == "Return"
    values: {Exp}
  end
  record Do is Base
    where self.kind == "Do"
    body: Block
  end
  record Break is Base
    where self.kind == "Break"
  end
  record Continue is Base
    where self.kind == "Continue"
  end
  record While is Base
    where self.kind == "While"
    cond: Exp
    body: Block
  end
  record Repeat is Base
    where self.kind == "Repeat"
    body: Block
    cond: Exp
  end
  record If is Base
    where self.kind == "If"
    arms: {Arm}
    else_body?: Block
  end
  record Arm is Base
    where self.kind == "Arm"
    cond: Exp
    body: Block
  end
  record Match is Base
    where self.kind == "Match"
    scrutinee: CallExp
    arms: {MatchArm}
  end
  record MatchArm is Base
    where self.kind == "MatchArm"
    pats: {PatItem}
    body: Block
  end
  record PatBool is Base
    where self.kind == "PatBool"
    value: boolean
  end
  record PatBind is Base
    where self.kind == "PatBind"
    name: Binding
  end
  record ForNum is Base
    where self.kind == "ForNum"
    var: Binding
    from: Exp
    to: Exp
    step?: Exp
    body: Block
  end
  record ForIn is Base
    where self.kind == "ForIn"
    vars: {Binding}
    iterators: {Exp}
    body: Block
  end

  record Name is Base
    where self.kind == "Name"
    text: string
    --- The id of the [`Binding`] it refers to, set by the scope builder.
    binding?: integer
  end
  record Nil is Base
    where self.kind == "Nil"
  end
  record Boolean is Base
    where self.kind == "Boolean"
    value: boolean
  end
  record Integer is Base
    where self.kind == "Integer"
    value: integer
  end
  record Float is Base
    where self.kind == "Float"
    value: number
  end
  record String is Base
    where self.kind == "String"
    --- The decoded contents.
    value: string
    long: boolean
  end
  record Vararg is Base
    where self.kind == "Vararg"
  end
  record Paren is Base
    where self.kind == "Paren"
    inner: Exp
  end
  record FunctionLit is Base
    where self.kind == "FunctionLit"
    fn: Fn
  end
  record Table is Base
    where self.kind == "Table"
    items: {Item}
  end
  record Positional is Base
    where self.kind == "Positional"
    value: Exp
  end
  record Named is Base
    where self.kind == "Named"
    name: string
    value: Exp
  end
  record Keyed is Base
    where self.kind == "Keyed"
    key: Exp
    value: Exp
  end
  record Field is Base
    where self.kind == "Field"
    object: Exp
    name: string
  end
  record Index is Base
    where self.kind == "Index"
    object: Exp
    key: Exp
  end
  record Call is Base
    where self.kind == "Call"
    callee: Exp
    args: {Exp}
  end
  record MethodCall is Base
    where self.kind == "MethodCall"
    object: Exp
    name: string
    args: {Exp}
  end
  record Unary is Base
    where self.kind == "Unary"
    op: UnaryOp
    operand: Exp
  end
  record Binary is Base
    where self.kind == "Binary"
    op: BinaryOp
    left: Exp
    right: Exp
  end
  record IsTest is Base
    where self.kind == "IsTest"
    value: Exp
    type: Type
  end
  --- The transition form `e as T`. The checker refuses it.
  record Cast is Base
    where self.kind == "Cast"
    value: Exp
    type: Type
  end
  record IfExp is Base
    where self.kind == "IfExp"
    arms: {ExpArm}
    else_value: Exp
  end
  record ExpArm is Base
    where self.kind == "ExpArm"
    cond: Exp
    value: Exp
  end

  --- A function's parameters, return list and body. `rets` is nil where the
  --- source has no return list.
  record Fn is Base
    where self.kind == "Fn"
    params: {Param}
    rets?: Rets
    body: Block
  end
  --- Two or more `lists` are a union of value lists. `variadic` marks a
  --- trailing `T...` on the one list.
  record Rets is Base
    where self.kind == "Rets"
    lists: {{RType}}
    variadic: boolean
  end
  --- `name` is nil for the rest parameter `...: T`, which has `variadic`.
  record Param is Base
    where self.kind == "Param"
    name?: Binding
    optional: boolean
    type?: Type
    variadic: boolean
  end
  record Binding is Base
    where self.kind == "Binding"
    name: string
    attr?: Attr
    doc?: {Lexer.Comment}
  end

  record TypeName is Base
    where self.kind == "TypeName"
    path: {string}
    args: {Type}
  end
  record TypeBool is Base
    where self.kind == "TypeBool"
    value: boolean
  end
  record TypeNil is Base
    where self.kind == "TypeNil"
  end
  record TypeError is Base
    where self.kind == "TypeError"
  end
  record TypeArray is Base
    where self.kind == "TypeArray"
    element: Type
  end
  record TypeMap is Base
    where self.kind == "TypeMap"
    key: Type
    value: Type
  end
  record TypeUnion is Base
    where self.kind == "TypeUnion"
    members: {Type}
  end
  record TypeOptional is Base
    where self.kind == "TypeOptional"
    inner: Type
  end
  record TypeMut is Base
    where self.kind == "TypeMut"
    inner: Type
  end
  record TypeFunction is Base
    where self.kind == "TypeFunction"
    typeparams: {TypeParam}
    params: {PType}
    rets?: Rets
  end
  --- A parameter of a function type. `name` is nil where only the type is written.
  record PType is Base
    where self.kind == "PType"
    name?: string
    optional: boolean
    variadic: boolean
    type: Type
  end
  --- A return item `v is T` or `asserts v is T`.
  record Narrows is Base
    where self.kind == "Narrows"
    param: string
    type: Type
    asserts: boolean
  end
  record TypeParam is Base
    where self.kind == "TypeParam"
    name: Binding
    constraint?: TypeName
  end

  --- `is` names the array part (`record Node is {Node}`) or the one interface.
  record Record is Base
    where self.kind == "Record"
    scope?: Scope
    name: Binding
    typeparams: {TypeParam}
    supers: {TypeName}
    array?: Type
    members: {Member}
  end
  record Interface is Base
    where self.kind == "Interface"
    scope?: Scope
    name: Binding
    typeparams: {TypeParam}
    supers: {TypeName}
    members: {Member}
  end
  record Class is Base
    where self.kind == "Class"
    scope?: Scope
    name: Binding
    typeparams: {TypeParam}
    supers: {TypeName}
    members: {Member}
  end
  record Enum is Base
    where self.kind == "Enum"
    scope?: Scope
    name: Binding
    values: {EnumValue}
  end
  record EnumValue is Base
    where self.kind == "EnumValue"
    value: string
    doc?: {Lexer.Comment}
  end
  --- `type Name = T`, the draft's `Alias` kind. The record is [`TypeAlias`], which names no other type of the tree.
  record TypeAlias is Base
    where self.kind == "Alias"
    scope?: Scope
    name: Binding
    typeparams: {TypeParam}
    type: Type
  end
  --- `type name = require("module")`.
  record Import is Base
    where self.kind == "Import"
    scope?: Scope
    name: Binding
    module: string
  end
  record FieldDecl is Base
    where self.kind == "FieldDecl"
    name: Binding
    mut: boolean
    omittable: boolean
    type: Type
    doc?: {Lexer.Comment}
  end
  --- A method of a class. `params` begins with `self`.
  record Method is Base
    where self.kind == "Method"
    name: Binding
    params: {Param}
    rets?: Rets
    body: Block
    doc?: {Lexer.Comment}
  end
  record Userdata is Base
    where self.kind == "Userdata"
  end
  --- The tokens a failed production skipped; the parser reports why.
  record Error is Base
    where self.kind == "Error"
  end

  type Stat = Local | LocalFunction | Function | Assign | CallStat | Return | Do | Break | Continue |
    While | Repeat | If | Match | ForNum | ForIn | Record | Interface | Class | Enum | TypeAlias | Import | Error
  type Exp = Name | Nil | Boolean | Integer | Float | String | Vararg | Paren | FunctionLit | Table |
    Field | Index | Call | MethodCall | Unary | Binary | IsTest | Cast | IfExp | Error
  --- What a statement or a `match` takes as a call: a [`Call`] or a [`MethodCall`], or an [`Error`].
  type CallExp = Call | MethodCall | Error
  type Item = Positional | Named | Keyed
  type PatItem = PatBool | PatBind
  type Type = TypeName | TypeBool | TypeNil | TypeError | TypeArray | TypeMap | TypeUnion |
    TypeOptional | TypeMut | TypeFunction
  --- An item of a return list.
  type RType = Type | Narrows
  type Member = FieldDecl | Record | Interface | Class | Enum | TypeAlias | Import | Method | Userdata | Error
  --- Every kind of node. A flat union: a test `is Ast.Node` against nested aliases would test only that
  --- the value is a table.
  type Node = Chunk | Block | Local | LocalFunction | Function | Assign | CallStat | Return | Do | Break |
    Continue | While | Repeat | If | Arm | Match | MatchArm | PatBool | PatBind | ForNum | ForIn | Name |
    Nil | Boolean | Integer | Float | String | Vararg | Paren | FunctionLit | Table | Positional | Named |
    Keyed | Field | Index | Call | MethodCall | Unary | Binary | IsTest | Cast | IfExp | ExpArm | Fn |
    Rets | Param | Binding | TypeName | TypeBool | TypeNil | TypeError | TypeArray | TypeMap | TypeUnion |
    TypeOptional | TypeMut | TypeFunction | PType | Narrows | TypeParam | Record | Interface | Class |
    Enum | EnumValue | TypeAlias | Import | FieldDecl | Method | Userdata | Error

  --- The fields of each kind that hold a node, a list of nodes or a scalar
  --- the tree is read by, in source order. `doc` is not among them.
  fields: {string: {string}}

  --- For each kind, how deep the list is in each field of `fields`: 0 for a
  --- node or a scalar, 1 for a list, 2 for a list of lists.
  depths: {string: {integer}}

  --- Numbers the nodes of `chunk` in pre-order, from 1, and answers how many there are. It
  --- keeps its own stack, so a chain of any length is numbered.
  number: function(chunk: Chunk): integer

  --- Calls `visit` with each child node of `node`, in source order.
  children: function(node: Node, visit: function(Node))

  --- The place of `node`: its first byte and its last. A node of no token, which
  --- a failed production leaves, is empty at the token it stands before: `xend` is `x - 1`.
  span: function(chunk: Chunk, node: Node): Span
end

-- The fields of each kind, a name for each, followed by `*` where the field
-- is a list and `**` a list of lists.
local SPEC <const>: {string: string} = {
  Chunk = "body", Block = "stats*",
  Local = "scope bindings* types* values*", LocalFunction = "name typeparams* fn",
  Function = "path* typeparams* fn", Assign = "targets* values*", CallStat = "call",
  Return = "values*", Do = "body", Break = "", Continue = "", While = "cond body",
  Repeat = "body cond", If = "arms* else_body", Arm = "cond body",
  Match = "scrutinee arms*", MatchArm = "pats* body", PatBool = "value", PatBind = "name",
  ForNum = "var from to step body", ForIn = "vars* iterators* body",
  Name = "text", Nil = "", Boolean = "value", Integer = "value", Float = "value",
  String = "value long", Vararg = "", Paren = "inner", FunctionLit = "fn", Table = "items*",
  Positional = "value", Named = "name value", Keyed = "key value",
  Field = "object name", Index = "object key", Call = "callee args*",
  MethodCall = "object name args*", Unary = "op operand", Binary = "op left right",
  IsTest = "value type", Cast = "value type", IfExp = "arms* else_value",
  ExpArm = "cond value",
  Fn = "params* rets body", Rets = "lists** variadic",
  Param = "name optional type variadic", Binding = "name attr",
  TypeName = "path* args*", TypeBool = "value", TypeNil = "", TypeError = "",
  TypeArray = "element", TypeMap = "key value", TypeUnion = "members*",
  TypeOptional = "inner", TypeMut = "inner", TypeFunction = "typeparams* params* rets",
  PType = "name optional variadic type", Narrows = "param type asserts",
  TypeParam = "name constraint",
  Record = "scope name typeparams* supers* array members*",
  Interface = "scope name typeparams* supers* members*",
  Class = "scope name typeparams* supers* members*",
  Enum = "scope name values*", EnumValue = "value",
  Alias = "scope name typeparams* type", Import = "scope name module",
  FieldDecl = "name mut omittable type", Method = "name params* rets body",
  Userdata = "", Error = "",
}

Ast.fields = {}
Ast.depths = {}
for kind, spec in pairs(SPEC) do
  local names: {string} = {}
  local depths: {integer} = {}
  for name, stars in spec:gmatch("([%w_]+)(%*?%*?)") do
    names[#names + 1] = name
    depths[#depths + 1] = #stars
  end
  Ast.fields[kind] = names
  Ast.depths[kind] = depths
end

local fields, depths = Ast.fields, Ast.depths

--- Pushes the nodes of `value`, which is a node, a list of nodes or, `depth` 2, of lists, last first.
local function push(stack: {{string: any}}, top: integer, value: {any}, depth: integer): integer
  for i = #value, 1, -1 do
    local item = value[i]
    if depth == 1 then
      if item is {string: any} then
        top = top + 1
        stack[top] = item
      end
    elseif item is {any} then
      top = push(stack, top, item, 1)
    end
  end
  return top
end

local function number(root: any): integer
  local stack: {{string: any}} = {}
  local top = 0
  if root is {string: any} then
    top = 1
    stack[1] = root
  end
  local count = 0
  while top > 0 do
    local node = stack[top]
    stack[top] = nil
    top = top - 1
    count = count + 1
    node.id = count
    local kind = node.kind
    if kind is string then
      local names, depth = fields[kind], depths[kind]
      for i = #names, 1, -1 do
        local value = node[names[i]]
        if type(value) == "table" then
          if depth[i] == 0 then
            if value is {string: any} then
              top = top + 1
              stack[top] = value
            end
          elseif value is {any} then
            top = push(stack, top, value, depth[i])
          end
        end
      end
    end
  end
  return count
end

function Ast.number(chunk: Ast.Chunk): integer
  return number(chunk)
end

--- Calls `visit` with each node in `list`, which is a list of nodes or, `depth` 2, of lists.
local function visit_list(list: {any}, depth: integer, visit: function(Ast.Node))
  for i = 1, #list do
    local item = list[i]
    if depth == 1 then
      if item is Ast.Node then
        visit(item)
      end
    elseif item is {any} then
      visit_list(item, 1, visit)
    end
  end
end

local function children_of(owner: {string: any}, visit: function(Ast.Node))
  local kind = owner.kind
  if not (kind is string) then
    return
  end
  local names, depth = fields[kind], depths[kind]
  for i = 1, #names do
    local value = owner[names[i]]
    if type(value) == "table" then
      if depth[i] == 0 then
        if value is Ast.Node then
          visit(value)
        end
      elseif value is {any} then
        visit_list(value, depth[i], visit)
      end
    end
  end
end

local function start_children(root: any, visit: function(Ast.Node))
  if root is {string: any} then
    children_of(root, visit)
  end
end

function Ast.children(node: Ast.Node, visit: function(Ast.Node))
  start_children(node, visit)
end

function Ast.span(chunk: Ast.Chunk, node: Ast.Node): Ast.Span
  local base: Ast.Base = node
  local tokens = chunk.tokens
  local first = base.first
  if base.last < first then
    return { y = Lexer.y(tokens, first), x = Lexer.x(tokens, first), yend = Lexer.y(tokens, first), xend = Lexer.x(tokens, first) - 1 }
  end
  local last = base.last
  return { y = Lexer.y(tokens, first), x = Lexer.x(tokens, first), yend = Lexer.yend(tokens, last), xend = Lexer.xend(tokens, last) }
end

return Ast
