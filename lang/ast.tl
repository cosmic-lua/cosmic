--- The syntax tree of the new checker's grammar,
--- which [`lang.parser`] builds.
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
--- [`Ast.fields`] lists the structural fields of each kind in source order, for a reader that walks them by name
--- (a pattern, a translation). [`Ast.children`] has code of its own for each kind, which lang/ast_test.tl holds to the
--- list. A tree is as deep as its source nests, and as a chain of `a + a + ...` is long, so a recursive walker can
--- overflow the stack where [`Ast.number`] does not.

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

local type Visit = function(Ast.Node)

--- How to visit the children of each kind that has any, in source order. A kind with no field that holds a node
--- ([`Break`], [`Name`], ...) has no entry. An entry takes a [`Node`] and tests its kind once, which narrows it to the
--- record whose fields it reads, so no field is read by name from a string: lang/ast_test.tl holds the table to
--- [`Ast.fields`] and to the declarations of the records, so a field added to one without the other fails there.
--- The table is a lookup by `kind` and not a chain of tests, so a walk pays one lookup per node however many kinds
--- there are.
local WALK <const>: {string: function(Ast.Node, Visit)} = {
  Chunk = function(n: Ast.Node, visit: Visit)
    if n.kind == "Chunk" then
      visit(n.body)
    end
  end,
  Block = function(n: Ast.Node, visit: Visit)
    if n.kind == "Block" then
      for _, item in ipairs(n.stats) do
        visit(item)
      end
    end
  end,
  Local = function(n: Ast.Node, visit: Visit)
    if n.kind == "Local" then
      for _, item in ipairs(n.bindings) do
        visit(item)
      end
      for _, item in ipairs(n.types) do
        visit(item)
      end
      for _, item in ipairs(n.values) do
        visit(item)
      end
    end
  end,
  LocalFunction = function(n: Ast.Node, visit: Visit)
    if n.kind == "LocalFunction" then
      visit(n.name)
      for _, item in ipairs(n.typeparams) do
        visit(item)
      end
      visit(n.fn)
    end
  end,
  Function = function(n: Ast.Node, visit: Visit)
    if n.kind == "Function" then
      for _, item in ipairs(n.path) do
        visit(item)
      end
      for _, item in ipairs(n.typeparams) do
        visit(item)
      end
      visit(n.fn)
    end
  end,
  Assign = function(n: Ast.Node, visit: Visit)
    if n.kind == "Assign" then
      for _, item in ipairs(n.targets) do
        visit(item)
      end
      for _, item in ipairs(n.values) do
        visit(item)
      end
    end
  end,
  CallStat = function(n: Ast.Node, visit: Visit)
    if n.kind == "CallStat" then
      visit(n.call)
    end
  end,
  Return = function(n: Ast.Node, visit: Visit)
    if n.kind == "Return" then
      for _, item in ipairs(n.values) do
        visit(item)
      end
    end
  end,
  Do = function(n: Ast.Node, visit: Visit)
    if n.kind == "Do" then
      visit(n.body)
    end
  end,
  While = function(n: Ast.Node, visit: Visit)
    if n.kind == "While" then
      visit(n.cond)
      visit(n.body)
    end
  end,
  Repeat = function(n: Ast.Node, visit: Visit)
    if n.kind == "Repeat" then
      visit(n.body)
      visit(n.cond)
    end
  end,
  If = function(n: Ast.Node, visit: Visit)
    if n.kind == "If" then
      for _, item in ipairs(n.arms) do
        visit(item)
      end
      local else_body_node = n.else_body
      if else_body_node ~= nil then
        visit(else_body_node)
      end
    end
  end,
  Arm = function(n: Ast.Node, visit: Visit)
    if n.kind == "Arm" then
      visit(n.cond)
      visit(n.body)
    end
  end,
  Match = function(n: Ast.Node, visit: Visit)
    if n.kind == "Match" then
      visit(n.scrutinee)
      for _, item in ipairs(n.arms) do
        visit(item)
      end
    end
  end,
  MatchArm = function(n: Ast.Node, visit: Visit)
    if n.kind == "MatchArm" then
      for _, item in ipairs(n.pats) do
        visit(item)
      end
      visit(n.body)
    end
  end,
  PatBind = function(n: Ast.Node, visit: Visit)
    if n.kind == "PatBind" then
      visit(n.name)
    end
  end,
  ForNum = function(n: Ast.Node, visit: Visit)
    if n.kind == "ForNum" then
      visit(n.var)
      visit(n.from)
      visit(n.to)
      local step_node = n.step
      if step_node ~= nil then
        visit(step_node)
      end
      visit(n.body)
    end
  end,
  ForIn = function(n: Ast.Node, visit: Visit)
    if n.kind == "ForIn" then
      for _, item in ipairs(n.vars) do
        visit(item)
      end
      for _, item in ipairs(n.iterators) do
        visit(item)
      end
      visit(n.body)
    end
  end,
  Paren = function(n: Ast.Node, visit: Visit)
    if n.kind == "Paren" then
      visit(n.inner)
    end
  end,
  FunctionLit = function(n: Ast.Node, visit: Visit)
    if n.kind == "FunctionLit" then
      visit(n.fn)
    end
  end,
  Table = function(n: Ast.Node, visit: Visit)
    if n.kind == "Table" then
      for _, item in ipairs(n.items) do
        visit(item)
      end
    end
  end,
  Positional = function(n: Ast.Node, visit: Visit)
    if n.kind == "Positional" then
      visit(n.value)
    end
  end,
  Named = function(n: Ast.Node, visit: Visit)
    if n.kind == "Named" then
      visit(n.value)
    end
  end,
  Keyed = function(n: Ast.Node, visit: Visit)
    if n.kind == "Keyed" then
      visit(n.key)
      visit(n.value)
    end
  end,
  Field = function(n: Ast.Node, visit: Visit)
    if n.kind == "Field" then
      visit(n.object)
    end
  end,
  Index = function(n: Ast.Node, visit: Visit)
    if n.kind == "Index" then
      visit(n.object)
      visit(n.key)
    end
  end,
  Call = function(n: Ast.Node, visit: Visit)
    if n.kind == "Call" then
      visit(n.callee)
      for _, item in ipairs(n.args) do
        visit(item)
      end
    end
  end,
  MethodCall = function(n: Ast.Node, visit: Visit)
    if n.kind == "MethodCall" then
      visit(n.object)
      for _, item in ipairs(n.args) do
        visit(item)
      end
    end
  end,
  Unary = function(n: Ast.Node, visit: Visit)
    if n.kind == "Unary" then
      visit(n.operand)
    end
  end,
  Binary = function(n: Ast.Node, visit: Visit)
    if n.kind == "Binary" then
      visit(n.left)
      visit(n.right)
    end
  end,
  IsTest = function(n: Ast.Node, visit: Visit)
    if n.kind == "IsTest" then
      visit(n.value)
      visit(n.type)
    end
  end,
  Cast = function(n: Ast.Node, visit: Visit)
    if n.kind == "Cast" then
      visit(n.value)
      visit(n.type)
    end
  end,
  IfExp = function(n: Ast.Node, visit: Visit)
    if n.kind == "IfExp" then
      for _, item in ipairs(n.arms) do
        visit(item)
      end
      visit(n.else_value)
    end
  end,
  ExpArm = function(n: Ast.Node, visit: Visit)
    if n.kind == "ExpArm" then
      visit(n.cond)
      visit(n.value)
    end
  end,
  Fn = function(n: Ast.Node, visit: Visit)
    if n.kind == "Fn" then
      for _, item in ipairs(n.params) do
        visit(item)
      end
      local rets_node = n.rets
      if rets_node ~= nil then
        visit(rets_node)
      end
      visit(n.body)
    end
  end,
  Rets = function(n: Ast.Node, visit: Visit)
    if n.kind == "Rets" then
      for _, list in ipairs(n.lists) do
        for _, item in ipairs(list) do
          visit(item)
        end
      end
    end
  end,
  Param = function(n: Ast.Node, visit: Visit)
    if n.kind == "Param" then
      local name_node = n.name
      if name_node ~= nil then
        visit(name_node)
      end
      local type_node = n.type
      if type_node ~= nil then
        visit(type_node)
      end
    end
  end,
  TypeName = function(n: Ast.Node, visit: Visit)
    if n.kind == "TypeName" then
      for _, item in ipairs(n.args) do
        visit(item)
      end
    end
  end,
  TypeArray = function(n: Ast.Node, visit: Visit)
    if n.kind == "TypeArray" then
      visit(n.element)
    end
  end,
  TypeMap = function(n: Ast.Node, visit: Visit)
    if n.kind == "TypeMap" then
      visit(n.key)
      visit(n.value)
    end
  end,
  TypeUnion = function(n: Ast.Node, visit: Visit)
    if n.kind == "TypeUnion" then
      for _, item in ipairs(n.members) do
        visit(item)
      end
    end
  end,
  TypeOptional = function(n: Ast.Node, visit: Visit)
    if n.kind == "TypeOptional" then
      visit(n.inner)
    end
  end,
  TypeMut = function(n: Ast.Node, visit: Visit)
    if n.kind == "TypeMut" then
      visit(n.inner)
    end
  end,
  TypeFunction = function(n: Ast.Node, visit: Visit)
    if n.kind == "TypeFunction" then
      for _, item in ipairs(n.typeparams) do
        visit(item)
      end
      for _, item in ipairs(n.params) do
        visit(item)
      end
      local rets_node = n.rets
      if rets_node ~= nil then
        visit(rets_node)
      end
    end
  end,
  PType = function(n: Ast.Node, visit: Visit)
    if n.kind == "PType" then
      visit(n.type)
    end
  end,
  Narrows = function(n: Ast.Node, visit: Visit)
    if n.kind == "Narrows" then
      visit(n.type)
    end
  end,
  TypeParam = function(n: Ast.Node, visit: Visit)
    if n.kind == "TypeParam" then
      visit(n.name)
      local constraint_node = n.constraint
      if constraint_node ~= nil then
        visit(constraint_node)
      end
    end
  end,
  Record = function(n: Ast.Node, visit: Visit)
    if n.kind == "Record" then
      visit(n.name)
      for _, item in ipairs(n.typeparams) do
        visit(item)
      end
      for _, item in ipairs(n.supers) do
        visit(item)
      end
      local array_node = n.array
      if array_node ~= nil then
        visit(array_node)
      end
      for _, item in ipairs(n.members) do
        visit(item)
      end
    end
  end,
  Interface = function(n: Ast.Node, visit: Visit)
    if n.kind == "Interface" then
      visit(n.name)
      for _, item in ipairs(n.typeparams) do
        visit(item)
      end
      for _, item in ipairs(n.supers) do
        visit(item)
      end
      for _, item in ipairs(n.members) do
        visit(item)
      end
    end
  end,
  Class = function(n: Ast.Node, visit: Visit)
    if n.kind == "Class" then
      visit(n.name)
      for _, item in ipairs(n.typeparams) do
        visit(item)
      end
      for _, item in ipairs(n.supers) do
        visit(item)
      end
      for _, item in ipairs(n.members) do
        visit(item)
      end
    end
  end,
  Enum = function(n: Ast.Node, visit: Visit)
    if n.kind == "Enum" then
      visit(n.name)
      for _, item in ipairs(n.values) do
        visit(item)
      end
    end
  end,
  Alias = function(n: Ast.Node, visit: Visit)
    if n.kind == "Alias" then
      visit(n.name)
      for _, item in ipairs(n.typeparams) do
        visit(item)
      end
      visit(n.type)
    end
  end,
  Import = function(n: Ast.Node, visit: Visit)
    if n.kind == "Import" then
      visit(n.name)
    end
  end,
  FieldDecl = function(n: Ast.Node, visit: Visit)
    if n.kind == "FieldDecl" then
      visit(n.name)
      visit(n.type)
    end
  end,
  Method = function(n: Ast.Node, visit: Visit)
    if n.kind == "Method" then
      visit(n.name)
      for _, item in ipairs(n.params) do
        visit(item)
      end
      local rets_node = n.rets
      if rets_node ~= nil then
        visit(rets_node)
      end
      visit(n.body)
    end
  end,
}

function Ast.children(node: Ast.Node, visit: function(Ast.Node))
  local walk = WALK[node.kind]
  if walk ~= nil then
    walk(node, visit)
  end
end

local children = Ast.children

local function number_node(node: Ast.Base, id: integer)
  node.id = id
end

function Ast.number(chunk: Ast.Chunk): integer
  local pending: mut {Ast.Node} = { chunk }
  local kids: mut {Ast.Node} = {}
  local function push(child: Ast.Node)
    kids[#kids + 1] = child
  end
  local count = 0
  while true do
    local node = table.remove(pending)
    if node == nil then
      break
    end
    count = count + 1
    number_node(node, count)
    -- The children are met in source order and go on in the reverse, so that the first is the next node taken.
    children(node, push)
    while true do
      local child = table.remove(kids)
      if child == nil then
        break
      end
      pending[#pending + 1] = child
    end
  end
  return count
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
