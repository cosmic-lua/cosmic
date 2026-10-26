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

-- TODO: read the nodes in `number` and `children` by their kinds (a test `n.kind == "Local"` of each, then the fields of the
-- record it selects) in place of as `{string: any}` driven by `SPEC`, and test a node of [`visit_list`] and [`children_of`] with
-- the one test `is Ast.Node` in place of the chain of compares of `kind` the translation of the tree made of it. Waits on a
-- change of its own that replaces both walkers (the `any_use` pin of this file counts them).
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

  --- What every node holds besides its kind: each record declares `kind` as an enum of its own, and [`Node`] is told
  --- apart by it. No value is in the enums of two records (`untagged_union` otherwise), a kind is never `mut`, and
  --- [`Kind`] lists them all for the tables below (lang/ast_test.tl holds the two to agree). A record repeats these
  --- fields, since a record lists the fields of an interface alike.
  interface Base
    --- The indexes in [`Chunk.tokens`] of its first and last token.
    first: integer
    mut last: integer
    --- Set by [`Ast.number`]; 0 before. A node is made with the field so that numbering
    --- does not grow its table.
    mut id: integer
  end

  enum Chunk_kind
    "Chunk"
  end
  record Chunk is Base
    kind: Chunk_kind
    first: integer
    mut last: integer
    mut id: integer
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

  --- A literal `require("m")` call, a `pcall(require, "m")` call, or a type import of one.
  record Require
    module: string
    --- The id of the [`Call`] or the [`Import`], set once the tree is numbered.
    mut node: integer
  end

  enum Block_kind
    "Block"
  end
  --- Its last token is the one that ended it: `end`, `else`, `elseif`,
  --- `until`, `}`-less, or the `$EOF$` of the chunk. `close` is that token's index.
  record Block is Base
    kind: Block_kind
    first: integer
    mut last: integer
    mut id: integer
    stats: {Stat}
    close: integer
  end

  enum Local_kind
    "Local"
  end
  record Local is Base
    kind: Local_kind
    first: integer
    mut last: integer
    mut id: integer
    scope: Scope
    bindings: {Binding}
    types: {Type}
    values: {Exp}
  end
  enum LocalFunction_kind
    "LocalFunction"
  end
  record LocalFunction is Base
    kind: LocalFunction_kind
    first: integer
    mut last: integer
    mut id: integer
    name: Binding
    typeparams: {TypeParam}
    fn: Fn
  end
  enum Function_kind
    "Function"
  end
  --- `function R.m(...)`: `path` is `R` and `m`. Its `doc` is the doc comment of the statement.
  record Function is Base
    kind: Function_kind
    first: integer
    mut last: integer
    mut id: integer
    path: {Name}
    typeparams: {TypeParam}
    fn: Fn
    doc?: {Lexer.Comment}
  end
  enum Assign_kind
    "Assign"
  end
  record Assign is Base
    kind: Assign_kind
    first: integer
    mut last: integer
    mut id: integer
    targets: {Exp}
    values: {Exp}
  end
  enum CallStat_kind
    "CallStat"
  end
  record CallStat is Base
    kind: CallStat_kind
    first: integer
    mut last: integer
    mut id: integer
    call: CallExp
  end
  enum Return_kind
    "Return"
  end
  record Return is Base
    kind: Return_kind
    first: integer
    mut last: integer
    mut id: integer
    values: {Exp}
  end
  enum Do_kind
    "Do"
  end
  record Do is Base
    kind: Do_kind
    first: integer
    mut last: integer
    mut id: integer
    body: Block
  end
  enum Break_kind
    "Break"
  end
  record Break is Base
    kind: Break_kind
    first: integer
    mut last: integer
    mut id: integer
  end
  enum Continue_kind
    "Continue"
  end
  record Continue is Base
    kind: Continue_kind
    first: integer
    mut last: integer
    mut id: integer
  end
  enum While_kind
    "While"
  end
  record While is Base
    kind: While_kind
    first: integer
    mut last: integer
    mut id: integer
    cond: Exp
    body: Block
  end
  enum Repeat_kind
    "Repeat"
  end
  record Repeat is Base
    kind: Repeat_kind
    first: integer
    mut last: integer
    mut id: integer
    body: Block
    cond: Exp
  end
  enum If_kind
    "If"
  end
  record If is Base
    kind: If_kind
    first: integer
    mut last: integer
    mut id: integer
    arms: {Arm}
    else_body?: Block
  end
  enum Arm_kind
    "Arm"
  end
  record Arm is Base
    kind: Arm_kind
    first: integer
    mut last: integer
    mut id: integer
    cond: Exp
    body: Block
  end
  enum Match_kind
    "Match"
  end
  record Match is Base
    kind: Match_kind
    first: integer
    mut last: integer
    mut id: integer
    scrutinee: CallExp
    arms: {MatchArm}
  end
  enum MatchArm_kind
    "MatchArm"
  end
  record MatchArm is Base
    kind: MatchArm_kind
    first: integer
    mut last: integer
    mut id: integer
    pats: {PatItem}
    body: Block
  end
  enum PatBool_kind
    "PatBool"
  end
  record PatBool is Base
    kind: PatBool_kind
    first: integer
    mut last: integer
    mut id: integer
    value: boolean
  end
  enum PatBind_kind
    "PatBind"
  end
  record PatBind is Base
    kind: PatBind_kind
    first: integer
    mut last: integer
    mut id: integer
    name: Binding
  end
  enum ForNum_kind
    "ForNum"
  end
  record ForNum is Base
    kind: ForNum_kind
    first: integer
    mut last: integer
    mut id: integer
    var: Binding
    from: Exp
    to: Exp
    step?: Exp
    body: Block
  end
  enum ForIn_kind
    "ForIn"
  end
  record ForIn is Base
    kind: ForIn_kind
    first: integer
    mut last: integer
    mut id: integer
    vars: {Binding}
    iterators: {Exp}
    body: Block
  end

  enum Name_kind
    "Name"
  end
  record Name is Base
    kind: Name_kind
    first: integer
    mut last: integer
    mut id: integer
    text: string
    --- The id of the [`Binding`] it refers to, set by the scope builder.
    mut binding?: integer
  end
  enum Nil_kind
    "Nil"
  end
  record Nil is Base
    kind: Nil_kind
    first: integer
    mut last: integer
    mut id: integer
  end
  enum Boolean_kind
    "Boolean"
  end
  record Boolean is Base
    kind: Boolean_kind
    first: integer
    mut last: integer
    mut id: integer
    value: boolean
  end
  enum Integer_kind
    "Integer"
  end
  record Integer is Base
    kind: Integer_kind
    first: integer
    mut last: integer
    mut id: integer
    value: integer
  end
  enum Float_kind
    "Float"
  end
  record Float is Base
    kind: Float_kind
    first: integer
    mut last: integer
    mut id: integer
    value: number
  end
  enum String_kind
    "String"
  end
  record String is Base
    kind: String_kind
    first: integer
    mut last: integer
    mut id: integer
    --- The decoded contents.
    value: string
    long: boolean
  end
  enum Vararg_kind
    "Vararg"
  end
  record Vararg is Base
    kind: Vararg_kind
    first: integer
    mut last: integer
    mut id: integer
  end
  enum Paren_kind
    "Paren"
  end
  record Paren is Base
    kind: Paren_kind
    first: integer
    mut last: integer
    mut id: integer
    inner: Exp
  end
  enum FunctionLit_kind
    "FunctionLit"
  end
  record FunctionLit is Base
    kind: FunctionLit_kind
    first: integer
    mut last: integer
    mut id: integer
    fn: Fn
  end
  enum Table_kind
    "Table"
  end
  record Table is Base
    kind: Table_kind
    first: integer
    mut last: integer
    mut id: integer
    items: {Item}
  end
  enum Positional_kind
    "Positional"
  end
  record Positional is Base
    kind: Positional_kind
    first: integer
    mut last: integer
    mut id: integer
    value: Exp
  end
  enum Named_kind
    "Named"
  end
  record Named is Base
    kind: Named_kind
    first: integer
    mut last: integer
    mut id: integer
    name: string
    value: Exp
  end
  enum Keyed_kind
    "Keyed"
  end
  record Keyed is Base
    kind: Keyed_kind
    first: integer
    mut last: integer
    mut id: integer
    key: Exp
    value: Exp
  end
  enum Field_kind
    "Field"
  end
  record Field is Base
    kind: Field_kind
    first: integer
    mut last: integer
    mut id: integer
    object: Exp
    name: string
  end
  enum Index_kind
    "Index"
  end
  record Index is Base
    kind: Index_kind
    first: integer
    mut last: integer
    mut id: integer
    object: Exp
    key: Exp
  end
  enum Call_kind
    "Call"
  end
  record Call is Base
    kind: Call_kind
    first: integer
    mut last: integer
    mut id: integer
    callee: Exp
    args: {Exp}
  end
  enum MethodCall_kind
    "MethodCall"
  end
  record MethodCall is Base
    kind: MethodCall_kind
    first: integer
    mut last: integer
    mut id: integer
    object: Exp
    name: string
    args: {Exp}
  end
  enum Unary_kind
    "Unary"
  end
  record Unary is Base
    kind: Unary_kind
    first: integer
    mut last: integer
    mut id: integer
    op: UnaryOp
    operand: Exp
  end
  enum Binary_kind
    "Binary"
  end
  record Binary is Base
    kind: Binary_kind
    first: integer
    mut last: integer
    mut id: integer
    op: BinaryOp
    left: Exp
    right: Exp
  end
  enum IsTest_kind
    "IsTest"
  end
  record IsTest is Base
    kind: IsTest_kind
    first: integer
    mut last: integer
    mut id: integer
    value: Exp
    type: Type
  end
  enum Cast_kind
    "Cast"
  end
  --- The transition form `e as T`. The checker refuses it.
  record Cast is Base
    kind: Cast_kind
    first: integer
    mut last: integer
    mut id: integer
    value: Exp
    type: Type
  end
  enum IfExp_kind
    "IfExp"
  end
  record IfExp is Base
    kind: IfExp_kind
    first: integer
    mut last: integer
    mut id: integer
    arms: {ExpArm}
    else_value: Exp
  end
  enum ExpArm_kind
    "ExpArm"
  end
  record ExpArm is Base
    kind: ExpArm_kind
    first: integer
    mut last: integer
    mut id: integer
    cond: Exp
    value: Exp
  end

  enum Fn_kind
    "Fn"
  end
  --- A function's parameters, return list and body. `rets` is nil where the
  --- source has no return list.
  record Fn is Base
    kind: Fn_kind
    first: integer
    mut last: integer
    mut id: integer
    params: {Param}
    rets?: Rets
    body: Block
  end
  enum Rets_kind
    "Rets"
  end
  --- Two or more `lists` are a union of value lists. `variadic` marks a
  --- trailing `T...` on the one list.
  record Rets is Base
    kind: Rets_kind
    first: integer
    mut last: integer
    mut id: integer
    lists: {{RType}}
    variadic: boolean
  end
  enum Param_kind
    "Param"
  end
  --- `name` is nil for the rest parameter `...: T`, which has `variadic`.
  record Param is Base
    kind: Param_kind
    first: integer
    mut last: integer
    mut id: integer
    name?: Binding
    optional: boolean
    type?: Type
    variadic: boolean
  end
  enum Binding_kind
    "Binding"
  end
  record Binding is Base
    kind: Binding_kind
    first: integer
    mut last: integer
    mut id: integer
    name: string
    mut attr?: Attr
    mut doc?: {Lexer.Comment}
  end

  enum TypeName_kind
    "TypeName"
  end
  record TypeName is Base
    kind: TypeName_kind
    first: integer
    mut last: integer
    mut id: integer
    path: {string}
    args: {Type}
  end
  enum TypeBool_kind
    "TypeBool"
  end
  record TypeBool is Base
    kind: TypeBool_kind
    first: integer
    mut last: integer
    mut id: integer
    value: boolean
  end
  enum TypeNil_kind
    "TypeNil"
  end
  record TypeNil is Base
    kind: TypeNil_kind
    first: integer
    mut last: integer
    mut id: integer
  end
  enum TypeError_kind
    "TypeError"
  end
  record TypeError is Base
    kind: TypeError_kind
    first: integer
    mut last: integer
    mut id: integer
  end
  enum TypeArray_kind
    "TypeArray"
  end
  record TypeArray is Base
    kind: TypeArray_kind
    first: integer
    mut last: integer
    mut id: integer
    element: Type
  end
  enum TypeMap_kind
    "TypeMap"
  end
  record TypeMap is Base
    kind: TypeMap_kind
    first: integer
    mut last: integer
    mut id: integer
    key: Type
    value: Type
  end
  enum TypeUnion_kind
    "TypeUnion"
  end
  record TypeUnion is Base
    kind: TypeUnion_kind
    first: integer
    mut last: integer
    mut id: integer
    members: {Type}
  end
  enum TypeOptional_kind
    "TypeOptional"
  end
  record TypeOptional is Base
    kind: TypeOptional_kind
    first: integer
    mut last: integer
    mut id: integer
    inner: Type
  end
  enum TypeMut_kind
    "TypeMut"
  end
  record TypeMut is Base
    kind: TypeMut_kind
    first: integer
    mut last: integer
    mut id: integer
    inner: Type
  end
  enum TypeFunction_kind
    "TypeFunction"
  end
  record TypeFunction is Base
    kind: TypeFunction_kind
    first: integer
    mut last: integer
    mut id: integer
    typeparams: {TypeParam}
    params: {PType}
    rets?: Rets
  end
  enum PType_kind
    "PType"
  end
  --- A parameter of a function type. `name` is nil where only the type is written.
  record PType is Base
    kind: PType_kind
    first: integer
    mut last: integer
    mut id: integer
    name?: string
    optional: boolean
    variadic: boolean
    type: Type
  end
  enum Narrows_kind
    "Narrows"
  end
  --- A return item `v is T` or `asserts v is T`.
  record Narrows is Base
    kind: Narrows_kind
    first: integer
    mut last: integer
    mut id: integer
    param: string
    type: Type
    asserts: boolean
  end
  enum TypeParam_kind
    "TypeParam"
  end
  record TypeParam is Base
    kind: TypeParam_kind
    first: integer
    mut last: integer
    mut id: integer
    name: Binding
    constraint?: TypeName
  end

  enum Record_kind
    "Record"
  end
  --- `is` names the array part (`record Node is {Node}`) or the one interface.
  record Record is Base
    kind: Record_kind
    first: integer
    mut last: integer
    mut id: integer
    scope?: Scope
    name: Binding
    typeparams: {TypeParam}
    supers: {TypeName}
    array?: Type
    members: {Member}
  end
  enum Interface_kind
    "Interface"
  end
  record Interface is Base
    kind: Interface_kind
    first: integer
    mut last: integer
    mut id: integer
    scope?: Scope
    name: Binding
    typeparams: {TypeParam}
    supers: {TypeName}
    members: {Member}
  end
  enum Class_kind
    "Class"
  end
  record Class is Base
    kind: Class_kind
    first: integer
    mut last: integer
    mut id: integer
    scope?: Scope
    name: Binding
    typeparams: {TypeParam}
    supers: {TypeName}
    members: {Member}
  end
  enum Enum_kind
    "Enum"
  end
  record Enum is Base
    kind: Enum_kind
    first: integer
    mut last: integer
    mut id: integer
    scope?: Scope
    name: Binding
    values: {EnumValue}
  end
  enum EnumValue_kind
    "EnumValue"
  end
  record EnumValue is Base
    kind: EnumValue_kind
    first: integer
    mut last: integer
    mut id: integer
    value: string
    doc?: {Lexer.Comment}
  end
  enum TypeAlias_kind
    "Alias"
  end
  --- `type Name = T`, the draft's `Alias` kind. The record is [`TypeAlias`], which names no other type of the tree.
  record TypeAlias is Base
    kind: TypeAlias_kind
    first: integer
    mut last: integer
    mut id: integer
    scope?: Scope
    name: Binding
    typeparams: {TypeParam}
    type: Type
  end
  enum Import_kind
    "Import"
  end
  --- `type name = require("module")`.
  record Import is Base
    kind: Import_kind
    first: integer
    mut last: integer
    mut id: integer
    scope?: Scope
    name: Binding
    module: string
  end
  enum FieldDecl_kind
    "FieldDecl"
  end
  record FieldDecl is Base
    kind: FieldDecl_kind
    first: integer
    mut last: integer
    mut id: integer
    name: Binding
    mut: boolean
    omittable: boolean
    type: Type
    doc?: {Lexer.Comment}
  end
  enum Method_kind
    "Method"
  end
  --- A method of a class. `params` begins with `self`.
  record Method is Base
    kind: Method_kind
    first: integer
    mut last: integer
    mut id: integer
    name: Binding
    params: {Param}
    rets?: Rets
    body: Block
    doc?: {Lexer.Comment}
  end
  enum Userdata_kind
    "Userdata"
  end
  record Userdata is Base
    kind: Userdata_kind
    first: integer
    mut last: integer
    mut id: integer
  end
  enum Error_kind
    "Error"
  end
  --- The tokens a failed production skipped; the parser reports why.
  record Error is Base
    kind: Error_kind
    first: integer
    mut last: integer
    mut id: integer
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
  local names: mut {string} = {}
  local depths: mut {integer} = {}
  for name, stars in spec:gmatch("([%w_]+)(%*?%*?)") do
    names[#names + 1] = name
    depths[#depths + 1] = #stars
  end
  Ast.fields[kind] = names
  Ast.depths[kind] = depths
end

local fields, depths = Ast.fields, Ast.depths

--- Pushes the nodes of `value`, which is a node, a list of nodes or, `depth` 2, of lists, last first.
local function push(stack: mut {{string: any}}, top: integer, value: {any}, depth: integer): integer
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
  local stack: mut {{string: any}} = {}
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
      if (item.kind == "Chunk" or item.kind == "Block" or item.kind == "Local" or item.kind == "LocalFunction" or item.kind == "Function" or item.kind == "Assign" or item.kind == "CallStat" or item.kind == "Return" or item.kind == "Do" or item.kind == "Break" or item.kind == "Continue" or item.kind == "While" or item.kind == "Repeat" or item.kind == "If" or item.kind == "Arm" or item.kind == "Match" or item.kind == "MatchArm" or item.kind == "PatBool" or item.kind == "PatBind" or item.kind == "ForNum" or item.kind == "ForIn" or item.kind == "Name" or item.kind == "Nil" or item.kind == "Boolean" or item.kind == "Integer" or item.kind == "Float" or item.kind == "String" or item.kind == "Vararg" or item.kind == "Paren" or item.kind == "FunctionLit" or item.kind == "Table" or item.kind == "Positional" or item.kind == "Named" or item.kind == "Keyed" or item.kind == "Field" or item.kind == "Index" or item.kind == "Call" or item.kind == "MethodCall" or item.kind == "Unary" or item.kind == "Binary" or item.kind == "IsTest" or item.kind == "Cast" or item.kind == "IfExp" or item.kind == "ExpArm" or item.kind == "Fn" or item.kind == "Rets" or item.kind == "Param" or item.kind == "Binding" or item.kind == "TypeName" or item.kind == "TypeBool" or item.kind == "TypeNil" or item.kind == "TypeError" or item.kind == "TypeArray" or item.kind == "TypeMap" or item.kind == "TypeUnion" or item.kind == "TypeOptional" or item.kind == "TypeMut" or item.kind == "TypeFunction" or item.kind == "PType" or item.kind == "Narrows" or item.kind == "TypeParam" or item.kind == "Record" or item.kind == "Interface" or item.kind == "Class" or item.kind == "Enum" or item.kind == "EnumValue" or item.kind == "Alias" or item.kind == "Import" or item.kind == "FieldDecl" or item.kind == "Method" or item.kind == "Userdata" or item.kind == "Error") then
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
        if (value.kind == "Chunk" or value.kind == "Block" or value.kind == "Local" or value.kind == "LocalFunction" or value.kind == "Function" or value.kind == "Assign" or value.kind == "CallStat" or value.kind == "Return" or value.kind == "Do" or value.kind == "Break" or value.kind == "Continue" or value.kind == "While" or value.kind == "Repeat" or value.kind == "If" or value.kind == "Arm" or value.kind == "Match" or value.kind == "MatchArm" or value.kind == "PatBool" or value.kind == "PatBind" or value.kind == "ForNum" or value.kind == "ForIn" or value.kind == "Name" or value.kind == "Nil" or value.kind == "Boolean" or value.kind == "Integer" or value.kind == "Float" or value.kind == "String" or value.kind == "Vararg" or value.kind == "Paren" or value.kind == "FunctionLit" or value.kind == "Table" or value.kind == "Positional" or value.kind == "Named" or value.kind == "Keyed" or value.kind == "Field" or value.kind == "Index" or value.kind == "Call" or value.kind == "MethodCall" or value.kind == "Unary" or value.kind == "Binary" or value.kind == "IsTest" or value.kind == "Cast" or value.kind == "IfExp" or value.kind == "ExpArm" or value.kind == "Fn" or value.kind == "Rets" or value.kind == "Param" or value.kind == "Binding" or value.kind == "TypeName" or value.kind == "TypeBool" or value.kind == "TypeNil" or value.kind == "TypeError" or value.kind == "TypeArray" or value.kind == "TypeMap" or value.kind == "TypeUnion" or value.kind == "TypeOptional" or value.kind == "TypeMut" or value.kind == "TypeFunction" or value.kind == "PType" or value.kind == "Narrows" or value.kind == "TypeParam" or value.kind == "Record" or value.kind == "Interface" or value.kind == "Class" or value.kind == "Enum" or value.kind == "EnumValue" or value.kind == "Alias" or value.kind == "Import" or value.kind == "FieldDecl" or value.kind == "Method" or value.kind == "Userdata" or value.kind == "Error") then
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
