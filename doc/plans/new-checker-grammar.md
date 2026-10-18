# the new checker's grammar

a draft of the grammar [the new checker] is built against, designed
before its parser, with the syntax tree and the interface the `build/`
modules read. [strict-teal.md] holds the rules the grammar carries and
the order the work lands in; this file holds the syntax. everything here
is intended, not built, so each example is a `text` block.

the grammar is constrained to what the repository needs: what the tree
writes, or what a rule of the plan needs to replace what the tree writes.
a form nothing uses is left out and can be added later; [what the grammar
leaves out] lists each cut with the count that justified it. a form that
only the translator needs, to carry something across before the gate, is
marked temporary.

notation: `{ x }` repeats, `[ x ]` is optional, `|` chooses, `"x"` is a
token, `Name`, `String` and `Number` are token kinds, `(* *)` a comment.

## what the tree writes today

counts come from parsing the 976 `.tl` files outside `vendor/`,
`testdata/`, the fork and the `.d.tl` declaration files (14 more, parsed
separately) with the fork's parser, which parses them all, or from text
searches where marked. type counts can repeat a type that nodes share.

- **syntax the grammar replaces.** `as` 1,635 and `is` 652; `goto` 5, all
  of the shape [goto only as continue] allows; `and` 14,222 and `or`
  8,082 operator nodes, about 800 of them ternaries; unions with `nil`
  3,751 outside the fork; `function R:m()` 156;
  `metamethod` 45, all `__close`; `pcall` 132 sites and `coroutine.*` 32
  outside tests.
- **words the grammar adds that the tree uses as names.** `match` binds in
  about ten places and is a field everywhere (`s:match(p)`); `continue`
  binds in 4, names 3 of the 5 labels and is a field once; `class` binds
  in 27 and is a field; `record` binds in 49 (mostly tests), `enum` in 3
  and `interface` in 1; `mut`, `is`, `as` and `asserts` are bound
  nowhere; `userdata` is a field name twice.
- **how the tree discriminates today.** it has no union of records outside
  the language tour [`cosmic/removed_example.tl`], which uses `where`. a
  `kind`, `type` or `tag` field sits on one record: 38 of type `string`,
  19 of a named type (an enum), and code narrows it with `==`.

## decisions

each is made. the first group is the owner's, the rest the draft's.

- **no `defer`.** the six per-call `__close` guards are rewritten as
  classes with `__close` and a `<close>` local. the grammar has no word
  for it.
- **narrowing declarations are predicate returns.** `function(v: any): v
  is Reader` narrows `v` when it returns true; `function<T>(v: T?,
  message?: string): asserts v is T` returns only when `v` is a `T`.
  `where` is dropped; `io.type` becomes a declaration of this form.
- **multiple returns are a matched call.** a function type may return a
  union of value lists, `function(): (true, R) | (false, E)`, and `match`
  takes tuple patterns. a multi-value call is never a value and nothing
  is packed at run time. `local ok, v = pcall(f)` stays legal and gives
  each name the union of its column, unlinked.
- **a constraint is one interface after `is`,** `<T is Ordered>`. the tree
  has 6 constraints, each a plain interface name; combining constraints
  is left out.
- **views everywhere.** `{T}` and `{K:V}` are views in every position and
  `mut {T}` is changeable. `mut name: T` (a field reassigned after
  creation) and `name: mut {T}` (a collection changed in place) differ and
  both are written. a table literal is `mut {T}` and passes where a view
  is expected. there is no `view` marker. about 2,500 typed collection
  locals outside tests are in the translator's count.
- **holes made by an index write are not a grammar question.** the checker
  recognizes `t[#t + 1] = v` as an `Assign` to an `Index` whose key is a
  `Binary +` of a `Unary #` of the same `Name` and the integer 1.
- **tags are the types the tree has.** a union of records is discriminated
  by a field of a single-member enum, which parses today. string-literal
  types are left out: the tree has no union of records outside the tour,
  so no count asks for them. `true` and `false` are types, because a union
  of value lists tells its members apart by them.
- **no backtracking.** the parser reads at most three tokens ahead, only
  in the places [lookahead] lists.
- **new words are reserved, except the declaration words.** `match`,
  `continue`, `mut`, `is`, `asserts`, `userdata` and, while it exists,
  `as` are reserved and still accepted as field names. `record`,
  `interface`, `class`, `enum` and `type` stay names, read as keywords by
  one rule, because `type` is a Lua function and `record` binds 49 times.
- **a method is declared inside its class,** with `self` written; there is
  no colon form of `function` and no constructor form (a class value is a
  table literal typed as the class). a record with a method is refused
  with the fix `class`; a `userdata` record keeps its methods.
- **`T?` is the one spelling.** `T | nil` is not in the grammar; the
  parser's error says to write `T?`.
- **an `if` expression always has an `else`.**

## the lexical grammar

the lexer is Lua 5.5's with these changes.

- **kept.** names; short strings in either quote with all of Lua's
  escapes (the tree uses `\z`, `\x`, `\u` and decimal) and long strings
  (140 with `=` levels); decimal integers and floats with exponents and
  hex integers; every Lua operator and punctuator. an unterminated string
  or comment or a stray byte is a token of kind `$ERR$` and lexing goes
  on, so one run reports several problems; an unterminated long string
  or long comment runs to the end of the file, as in Lua.
- **a comment is `--` to the end of the line.** a line break is Lua's: `\n`,
  `\r`, `\r\n` and `\n\r` are each one. a doc comment is the run
  ending on the line before a declaration's first token; the parser
  attaches it once to the declaration, field, method or enum value.
  tokens keep the comments before them, and gain a byte offset and
  length, so `line_starts` and `offset_of` in [`build/ast/rewrite.tl`] and
  the formatter's token scan read one table.
- **reserved:** Lua's `and break do else elseif end false for function if
  in local nil not or repeat return then true until while`, and `goto` and
  `global`, which Lua 5.5 reserves in this build, so no program names a
  variable with them; and new, `match`, `continue`, `mut`, `is`,
  `asserts`, `userdata`, and `as` (temporary, see [no casts]). each of the
  new words, and `goto` and `global`, is also accepted wherever a field name
  stands: after `.` or `:`, as a table key before `=`, and in a member
  position followed by `:` or `?:`. no other Lua word is a field name: the
  tree writes none, and `y.` at the end of a line must not take the `local`
  after it for a field. `goto` has no statement; a use is a syntax error that
  says to write `continue`. `global` begins a declaration in a declaration
  file only. `goto` and `global` after `:` are refused: a method call
  would have to be written `x["goto"](x, ...)`, evaluating `x` twice.
- **`>>` closing two type-argument lists** (`Cache<K, List<V>>`) is one
  token consumed as two closers, without rewriting it; the fork rewrites
  it and [`build/ast/node.tl`] puts it back after the parse.
- **a call opens on its line.** a `(` that begins a line does not
  continue the expression before it. the fork inserts a `;` token on
  seeing this and the formatter writes it out; here it is a rule of the
  call suffix, the parser inserts nothing and the tree holds no token the
  source lacks.
- **the bindings of `match` and `continue`** (about a dozen) are renamed
  in Teal before the translator runs, so the translator renames nothing
  and the Lua stays identical.

## the syntactic grammar

### chunks and statements

```text
chunk       = block
block       = { stat } [ "return" [ explist ] ]

stat        = varlist "=" explist
            | call
            | "do" block "end"
            | "while" exp "do" block "end"
            | "repeat" block "until" exp
            | "if" exp "then" block { "elseif" exp "then" block } [ "else" block ] "end"
            | "for" Name "=" exp "," exp [ "," exp ] "do" block "end"
            | "for" namelist "in" explist "do" block "end"
            | "match" call "do" arm { arm } "end"
            | "break"
            | "continue"
            | "function" Name "." Name [ typeparams ] fn      (* of a record or class *)
            | "local" "function" Name [ typeparams ] fn
            | "local" binding { "," binding } [ ":" typelist ] [ "=" explist ]
            | ( "local" | "global" ) typedecl                 (* "global": declaration files *)
            | "global" binding { "," binding } [ ":" typelist ] [ "=" explist ]

arm         = "|" "(" patitem { "," patitem } ")" "then" block
patitem     = "true" | "false" | Name                         (* a name binds *)

binding     = Name [ "<" ( "const" | "close" ) ">" ]
varlist     = var { "," var }
var         = Name | prefix "." fname | prefix "[" exp "]"
namelist    = Name { "," Name }
explist     = exp { "," exp }
prefix      = primary { suffix }                  (* a call is a prefix ending in args *)
```

- `local a, b: T, U = f()` is the fork's declaration, kept (189 uses): the
  names, then the type list, then the values. a name with no type needs a
  value ([assigned before read]).
- `continue` is legal in the body of a `while`, `for` or `repeat`, not
  across a function, and emits `goto continue` with a `::continue::`
  before the loop's `end`. in a `repeat` it is refused when the body
  declares a local at its own level after the `continue`: the `until` is
  inside the scope of every local of the body, so Lua cannot jump past one,
  whether or not the `until` reads it. the error says to declare the local
  before the `repeat` if the `until` reads it, and else to wrap the code from
  the local to the end of the body in `do ... end`. a local here is a
  `local` or `local function`, and a `local class`, `local record` or
  `local type m = require(...)`, which are values in the Lua written for them;
  an enum, an alias and an interface are not.
- `match` takes a call whose function type returns a union of value
  lists. each arm is one list, `true` and `false` selecting the member
  and a name binding the value in that position; the arms cover the
  union exactly, so there is no `else`, and a missing member is an error.
  an arm after one with no `true` or `false` is unreachable and refused,
  as is a name bound twice in one arm (a name starting with `_` aside).
  it emits an `if` chain over the first value. the tree has 132 `pcall`
  sites and 32 `coroutine.*` for it to replace.
- a statement cannot begin with an expression, so an `if` at a statement's
  start is the statement and anywhere else the expression. a bare
  `function f()` (a global) and a bare `record R` are refused.

### expressions

```text
exp         = binary
binary      = unary { binop unary }                  (* by the list below *)
unary       = { "not" | "#" | "-" | "~" } power
power       = postfix [ "^" unary ]                  (* right associative *)
postfix     = primary { suffix } [ "is" base | "as" type ]   (* "as": temporary *)
primary     = Name | "(" exp ")" | literal | "function" fn | tablector | ifexp
suffix      = "." fname | "[" exp "]" | ":" fname args | args
args        = "(" [ explist ] ")" | tablector     (* "(" on the callee's line *)
literal     = "nil" | "true" | "false" | Number | String | "..."
tablector   = "{" [ item { "," item } [ "," ] ] "}"
item        = "[" exp "]" "=" exp | fname "=" exp | exp
fname       = Name | added word                  (* match continue mut is as asserts userdata, goto, global *)

ifexp       = "if" exp "then" exp { "elseif" exp "then" exp } "else" exp "end"
```

binary operators, lowest binding first, all left associative but `..`:
`or`; `and`; `< > <= >= ~= ==`; `|`; `~`; `&`; `<< >>`; `..` (right
associative); `+ -`; `* / // %`. `^` binds tighter than the unary
operators, as in Lua. every operator is used by the tree.

`is` is a postfix test at the tightest level, as in the fork: `not x is T`
is `not (x is T)` and `a == b is T` tests `b`. its type is a base type
(the 652 uses are arrays, maps, nominal types and primitives, never a
union), and `is` does not chain.

- **the `if` expression.** each arm is one expression, adjusted to one
  value. the compiler emits `c and a or b` when the first arm can be
  neither false nor nil, which is every ternary [honest `or` and `and`]
  accepts, so a translated ternary keeps the Teal's Lua byte for byte;
  any other arm is emitted as the compiler chooses.
- **`as`** is the transition form of [no casts]: parsed, never accepted,
  and gone at the gate.

### types

```text
type        = union
union       = optional { "|" optional }
optional    = base [ "?" ]
base        = "mut" collection | collection
            | "function" [ typeparams ] "(" [ ptype { "," ptype } ] ")" [ ":" rets ]
            | "nil" | "true" | "false"
            | tref
            | "(" type ")"
collection  = "{" type "}" | "{" type ":" type "}"
tref        = tname [ "<" type { "," type } ">" ]
tname       = Name { "." Name }

ptype       = [ Name [ "?" ] ":" | "..." ":" ] type
rets        = rlist | plist "|" plist { "|" plist }       (* a union of value lists *)
rlist       = rtype { "," rtype } [ "..." ] | "(" [ rtype { "," rtype } ] [ "..." ] ")"
plist       = "(" rtype { "," rtype } ")"
rtype       = type | Name "is" type | "asserts" Name "is" type   (* narrowing declarations *)
typelist    = type { "," type }
typeparams  = "<" tparam { "," tparam } ">"
tparam      = Name [ "is" tname ]
```

- `T?` is a postfix on the base, so `A | B?` is `A | (B?)`, `{T}?` an
  optional array and `mut {T}?` is `(mut {T})?`; `T??` is a syntax error,
  and `(A | B)?` is how a union with `nil` is written. `mut` applies to an
  array or a map, and the checker refuses it before any other type
  ([collections are views unless declared mutable]).
- `?` marks an omittable parameter only as `name?: T`, before the `:`. a
  parameter of a function type is `name: T`, `name?: T` or `...: T` for the
  rest; the variadic mark `T...` is only the tail of a return list.
- a parenthesized list followed by `|` and another is a union of lists;
  `(A) | (B)` is therefore not a type union, and is written `A | B`. a
  narrowing item is the whole return list.
- a parameter's type is optional in a declaration; [annotated parameters]
  is a checker rule.
- `never` is a primitive type name and `: never` an ordinary return type,
  so the tree's declarations of it need no rewrite.

### declarations

```text
typedecl    = "record" Name [ typeparams ] [ "is" ( "{" type "}" | tref ) ] { member } "end"
            | "interface" Name [ typeparams ] [ "is" tref { "," tref } ] { member } "end"
            | "class" Name [ typeparams ] [ "is" tref ] { cmember } "end"
            | "enum" Name { String } "end"
            | "type" Name [ typeparams ] "=" ( type | "require" "(" String ")" )

member      = field | typedecl | "userdata"
cmember     = field | typedecl | method
field       = [ "mut" ] ( fname | "[" String "]" ) [ "?" ] ":" type
method      = "function" Name "(" "self" { "," param } ")" [ ":" rets ] block "end"

fn          = "(" [ param { "," param } ] ")" [ ":" rets ] block "end"
param       = Name [ "?" ] [ ":" type ] | "..." ":" type
```

nested declarations in a body take no `local`.

- **record.** fields only, each fixed unless `mut`; a function-typed field
  is a callback. a record may be generic, implement one interface, and
  carry an array part in place of one (`record Node is {Node}`; 9 uses).
- **interface.** fields and function-typed fields, which name their
  receiver as `self: I` ([named receivers]); no nested `record`. one
  tree interface extends two (`Conn is Stream.Reader, Stream.Writer`), so
  an interface may list several; a record or class lists one (84 list
  one, none two). an implementing type declares `mut` exactly where the
  interface does.
- **class.** [compiler-written classes] in one place: fields with their
  `mut` markers, then methods with bodies. a method's first parameter is
  `self`, untyped, and is the class; a method has no type parameters of
  its own and the class's are in scope. `__close` and `__tostring` are
  methods so named. a class value is a table literal that names every
  field.
- **type.** an alias, or an import of a module's types (`local type sqlite
  = require("cosmic.internal.sqlite")`, 106 outside tests). an alias
  names a type and creates none, and may be generic (`type Key<T> =
  Types.Key<T>`, used in [`cosmic/web/init.tl`]). a **tagged union** is an
  alias of a union of records, held to a shared tag where it is declared.
- **enum.** string members, each with its comment (12 have one).
- **overloads** are repeated function-typed fields of one name, legal in a
  declaration file only (26, all there); any other repeated field is an
  error.

### declaration files

a `.d.tl` file is the same grammar in a mode that changes three things.

- there is no function body: no `function` statement or literal. the
  statements are type declarations, `local x = require(...)`, `global`
  declarations, `do` blocks of those and one `return Name`.
- `global` is accepted before a type declaration or a binding (`global
  record io ... end`, `global assert <const> = Library.assert`) and is a
  syntax error in a `.tl` file, since a program's globals are exactly the
  ones a declaration file declares ([no implicit conversion or hidden
  code]). `userdata` (11 uses in 5 files) and overloads are accepted in a
  record there and nowhere else.
- a narrowing declaration is taken on trust, as every signature is. in a
  `.tl` file it is accepted only where the function's returned expression
  is a guard the checker verifies.

### lookahead

the places the parser reads past the current token. none backtracks.

- `record`, `interface`, `class`, `enum` or `type` followed by a name
  begins a type declaration after `local` or `global` and in a member
  position. `local class = 1` and `local type, x` bind those names.
- in a member position one of those words followed by `:` or `?:` is a
  field of that name (`userdata: boolean`); `mut` followed by a name or `[` is
  the modifier, and `mut mut: T` is both; `userdata` alone is the marker.
- after a type in a type list or return list, a `,` continues the list
  unless a parameter begins after it: `Name :`, `Name ? :` or `...`
  (the fork's `starts_parameter`). write a two-valued return inside a
  parameter list with parentheses.
- in a function type's parameters, `Name :` or `Name ? :` names the
  parameter; a name followed by anything else begins its type.
- in a table constructor, `Name =` is a keyed item and any other `Name`
  begins an expression.
- `Name is` in a return list is a narrowing return; `asserts Name is`
  an asserting one.

### a sketch

```text
local type Reply = function(): (true, string) | (false, string)

local function show(fetch: Reply)
  match fetch() do
    | (true, body) then print(body)             -- body is a string here
    | (false, why) then print("failed: " .. why)
  end
end

local class Counter is Resettable
  label: string
  mut count: integer                            -- reassigned after creation
  seen: mut {string}                            -- fixed field, changeable collection
  function bump(self, by: integer): integer
    self.count = self.count + by
    return self.count
  end
end

local function count(xs: {integer}, skip: integer?): integer   -- xs is a view
  local n = 0
  for _, x in ipairs(xs) do if x == skip then continue end n = n + 1 end
  return n
end

local c: Counter = { label = "n", count = 0, seen = {} }
local noun = if c.count == 1 then "item" else "items" end
is_reader: function(v: any): v is Reader        -- a field of a record or a .d.tl
```

## departures from Teal, and what the translator does

the translator ([the new checker] has the plan for it) writes a Teal
module in this grammar. the class says whether the new checker's Lua for
the result equals the fork's for the original: **respelling** (byte for
byte, compared over the whole tree), **layout** (the same tokens in
another place, compared after the stated normalization), **meaning** (the
Lua differs; the test suite compares behavior) or **new** (no Teal
source; hand-written in the rewrites).

| construct | replaces | translator rule | class |
|---|---|---|---|
| `T?` | `T \| nil`, `nil \| T`, `A \| B \| nil` | a union with `nil` becomes an optional of the rest, parenthesized when two members or more remain | respelling |
| fixed field | `readonly f: T` | drop `readonly`; write `mut` on each field the fork's `uses` rows show assigned after creation | respelling |
| view parameter | `{T}`, `{K:V}` parameters | write `mut` where the function changes the collection | respelling |
| `...: T` | `T...` as a parameter type | rewrite in place | respelling |
| `continue` | `goto continue` and `::continue::` at a loop's end | replace the goto; blank the label's line | layout: the label moves to the loop's `end` line; the oracle deletes `::continue::` tokens first |
| `if` expression | `c and a or b` | when the fork's type report shows `a` neither boolean nor optional; any other ternary stays and counts under the [honest `or` and `and`] ceiling | respelling |
| `class` | a record with `function R:m()` or `metamethod __close` | move each method into the class and add `self`; the translator writes the `setmetatable` pattern as the class ([compiler-written classes, in the new checker]) | meaning: bodies move, the reserved form replaces the metatable |
| `__close` field | `metamethod __close: T` in a declaration file | drop `metamethod` | respelling |
| `as` | `e as T` | kept as the transition form, counted in the [no casts] ceiling | respelling; the checker refuses it |
| `is` | `e is T` | unchanged | respelling for primitives, enums, `nil`, function and table kinds; meaning for a class (the compiler's metatable test); refused for a record that is not a class |
| `match`, typed `pcall` | `pcall`, `coroutine.*` | none | new |
| unchanged | `record`, `interface`, `enum`, `local type`, `is {T}`, `userdata`, `name?: T`, generics, `<const>`, `<close>`, numeric `for` with a step, `repeat` | none | respelling |

the forms in [what the grammar leaves out] that the tree does write are
rewritten by hand in Teal first, so the translator never meets them.

## the syntax tree

### shape

- **a node is a range of tokens.** `first` and `last` index the token
  array and `y`, `x`, `yend`, `xend` are read from them, so a `local`
  starts at its `local`, an operator node at its left operand and a
  block ends at its terminator.
- **a node has an id,** its position in a pre-order walk. the type
  report, the scopes and the docs rows are keyed by it, as positions are
  not unique (`a.b.c` has three nodes at one start).
- **nothing is inserted.** the fork's parser adds a `;` and a `self` the
  source never wrote; the tree holds only tokens and nodes the source has.
- **no node points up.** `if_parent` goes; [`build/ast/walk.tl`] supplies
  parents where a reader asks.
- **types are syntax nodes** with kinds and spans, apart from the
  checker's semantic types, so the tree keeps how a type was spelled.
  the parser makes no semantic type and no `typeid`.
- **the tree is typed by construction.** `Node` is a tagged union on
  `kind`. the cast in [`build/ast/node.tl`], its entry in the casts table
  of [`build/contracts.tl`] and the note on [`compiler.Result`] in
  [`build/compiler.d.tl`] go.
- **a declaration is not a use.** a `Binding` (a name that introduces a
  variable, parameter, loop variable, type or field) is a different kind
  from a `Name`; the fork's `identifier` and `variable` make every reader
  tell them apart by context. the scope builder, not the parser, sets
  which `Binding` a `Name` refers to, so [`build/scopes.tl`] stays the one
  place that decides.
- **each kind lists its child fields in source order,** so a walker needs
  no code per kind. the parser never raises: an `Error` node holds the
  span a failed production skipped.

### kinds

```text
Chunk        body: Block, tokens: {Token}, requires: {Require}
Block        stats: {Stat}, close: token          (* the end/else/until/EOF that ended it *)
Require      module: string, node: id             (* each literal require("m") call *)

Local        bindings: {Binding}, types: {Type}, values: {Exp}
LocalFunction  name: Binding, typeparams, fn: Fn  Function  path: {Name}, typeparams, fn: Fn
Assign       targets, values                      CallStat  call       Return  values
Do, Break, Continue      While  cond, body        Repeat  body, cond
If           arms: {cond, body: Block}, else_body: Block?
Match        scrutinee: Call, arms: {pats: {PatItem}, body: Block}
ForNum       var: Binding, from, to, step?, body  ForIn  vars: {Binding}, iterators, body

Name         text, binding: id?                   (* a use *)
Nil, Boolean, Integer, Float, String (value, long), Vararg, Paren inner
Function     fn: Fn                               Table  items: {Item}
Field        object, name: string                 Index  object, key
Call         callee, args                         MethodCall  object, name, args
Unary        op, operand                          Binary  op, left, right
IsTest       value, type                          Cast  value, type  (* temporary *)
IfExp        arms: {cond, value}, else_value
Item         Positional value | Named name, value | Keyed key, value
PatItem      Bool value | Bind name: Binding

Fn           params: {Param}, rets: Rets?, body: Block        (* nil: no return list *)
Rets         lists: {{Type}}, variadic            (* two or more lists: a union of lists *)
Param        name: Binding, optional, type: Type?, variadic
Binding      name, attr: ("const" | "close")?, doc: {Comment}

TypeName     path: {string}, args               TypeBool  value      TypeNil   TypeError
TypeArray    element     TypeMap  key, value    TypeUnion  members   TypeOptional  inner
TypeMut      inner       TypeFunction  typeparams, params: {PType}, rets: Rets
Narrows      param: string, type: Type, asserts: boolean        (* a return item *)
TypeParam    name: Binding, constraint: Type?

Record, Interface  name: Binding, typeparams, supers, array: Type?, members, doc
Class        name: Binding, typeparams, supers, members, doc
Enum         name: Binding, values: {EnumValue}   Alias  name, typeparams, type
Import       name: Binding, module: string
Field        name, mut, omittable, type, doc      Method  name, params, rets, body, doc
Userdata
```

a `Local`'s doc comment is on its first binding, a type declaration's on
its `name`.

### what the parser settled

[`lang/parser.tl`] builds this tree; [`lang/ast.tl`] declares it. where the
draft was loose, the parser chose the smallest form that fits it:

- **names.** two kinds were named twice: the statement is `Function` and the
  function literal `FunctionLit`; a record member is `FieldDecl` and the
  expression `a.b` is `Field`. the nodes the draft left unnamed are `Arm`,
  `ExpArm` and `MatchArm` (the arms of `if`, an `if` expression and `match`),
  `PatBool` and `PatBind`, `Positional`, `Named` and `Keyed`, `PType` (a
  parameter of a function type, whose name is a string, not a `Binding`) and
  `EnumValue`. an operator is the field `op` of `Unary` and `Binary`. the
  Teal record of `Alias` is `TypeAlias`, since another module of the tree
  has an `Alias` of its own and the shorter name would make a link to either
  ambiguous.
- **spans.** a block ends at its terminator, so an `Arm` begins at its
  condition and a `MatchArm` at its `(`, which leaves the `elseif` or `|` that
  ends the block before it to the block alone, and the nodes of one parent
  never overlap. where a construct is not closed, its block ends before the
  token that stopped it.
- **scope.** `Local` and each declaration have `scope`, `local` or `global`,
  and nested declarations have none. a `Method` lists `self` as its first
  parameter, and a rest parameter `...: T` has no name.
- **doc comments.** a doc comment is the run of comments each alone on its
  line, ending on the line before the first token of a local, a type
  declaration (on its `name`), a field, a method or an enum value; a comment at
  the end of a line of code is no doc.
- **`as` chains.** `e as any as T` is nested casts: 16 of the tree's casts
  are chained. `is` does not chain.
- **`|` at the start of a line** in a `match` arm, followed by `(` and not
  inside a bracket the arm opened, begins the next arm and continues no
  expression, type or return list, as a `(` that begins a line begins a
  statement. a function literal's signature in an arm is outside the arm. a
  second arm on a line is refused, with the fix to start each on its own.
- **`continue` in a `repeat`** is refused when the body declares a local at
  its own level after it, as above.
- **what takes a suffix.** only a name or a parenthesized expression, and
  what a suffix makes of one, takes `.`, `:`, `[`, a call or a table or
  string argument, as in Lua: `"abc":upper()` is refused with the fix to
  parenthesize.
- **lists.** a trailing `,` is refused in parameters (of a function or of a
  function type) and in the patterns of an arm; a table may end in one. a
  table item on the next line with no `,` before it is refused with the fix
  to add one.
- **reserved words as names.** `match = 1`, `continue = true` (the tree writes
  it once, in [`cosmic/http/wire.tl`]), `match(a, b)` and `continue(a)` at the
  start of a statement are errors with a rename, read as the name they were
  meant for.
- **left to the checker.** a `...` outside a vararg function, which the
  grammar cannot tell from one; and every rule of types.
- **declarations.** a type declaration nested in an interface is refused. a
  narrowing return stands alone as the whole return list. a method and a
  field, or two methods, cannot share a name. a declaration file holds the
  types, `local x = require("m")`, `global` declarations, `do` blocks of
  those and one `return Name`. `local type X = record ... end` (5 uses in the
  tree, 3 records and 2 enums) is refused with the fix `local record X ...
  end` and is rewritten by hand with the other cut forms.
- **nesting** past 200 levels of blocks, expressions and types is the error
  `too_deep`, a limit of the size of Lua's own (which counts its C levels); the rest of that construct is skipped and not
  reported, and the statements after it are.
- **errors.** the parser's codes are the lexer's and those of `Code` in
  [`lang/parser.tl`], among them the draft's `reserved_word`, `label_or_goto`,
  `nil_union`, `method_in_record` and `continue_outside_loop`. `cast_refused`
  is the checker's, since the parser keeps the `Cast`. `parse` takes the
  `Lexed` and answers a `Parsed`: the chunk, and the lexer's errors and the
  parser's as one list in source order.

### what the translator settled

[`lang/translate.tl`] reads Teal with [`lang/parser.tl`]: the grammar is Teal
less the cut forms, and the parser keeps a tree for each form it refuses
(`T | nil` is a `TypeUnion` with a `TypeNil`, `function R:m` a `Function`,
`goto continue` an `Error` and a `Continue`), so a rewrite is an edit of the
bytes of tokens the source has. the fork's parser gives positions of where a
node was built, no comments and a `;` and a `self` the source never wrote. a
rewrite repeats until the text holds none, then the class rewrite moves the
methods, and the answer is the text and the errors of its last parse: those
errors are the account of what the translator did not handle.

- **respellings.** the lines of the file stay where they are for every row
  but the class: `T?`, `...: T`, `argN?: T`, `continue`, `;`, `_` in a
  number, a hexadecimal float, `local record X`, `__close: T`, a dropped
  `readonly` and the `if` expression. a long comment of several lines
  becomes as many line comments, and a label's line is left empty. a
  comment is never touched.
- **a return list that begins `(A | B)?`** and goes on is written
  `((A | B)?, C)`: the parser reads a `(` that begins a return list as the
  list. a return list that begins with a parenthesized type in Teal is read
  the same way, and is not handled (the tree has none).
- **the `if` expression** is written where the middle operand is a literal,
  a table, a function, an arithmetic or concatenation or a cast to a type of
  those: 1,217 sites outside the fork, in chains as `elseif`. the draft asks
  for the fork's type report on a name or a call; those stay and count under
  the `or` and `and` ceiling.
- **the class** takes each record that has `function R:m` statements at the
  top of the file (53 outside the fork): the record's field of the same name
  is dropped, its doc comment goes to the method, and the types it gives
  (parameters and returns the method leaves out) are written on the method.
  a method moves above every local declared between its record and it, so a
  method that reads one reads another name, or none: 42 methods do. a method
  whose types differ from its field's is another (1). both are a ceiling in
  `translated` that only falls with the `mut` places above (55 in all), each
  to be fixed in Teal by declaring the name above its record, by making the
  types agree, or by giving the interface its `mut`. a record that
  implements an array, is `userdata`, or whose methods are written inside a
  block stays.
- **the class literal** takes each `setmetatable(T, mt)` of a class of the file whose `T` is a table literal and
  whose `mt` is `local mt: metatable<R> = { __index = R }` (or the literal `{ __index = R }`), in a place that gives
  `R` as the type of the value: the only value of a local declared `R`, which gets `: R` where it had none, or of a
  `return` in a function that answers `R`. the call is written `T`, and the metatable goes when no other use of its
  name is left. a metatable with a use that is no such call, or with an item besides `__index` (a `__gc`, a `__mode`),
  stays with all its calls and keeps its `__close`: the class rewrite moves a `__close` only out of a metatable that
  holds nothing else. the calls left are the ceiling of `setmetatable_call` in `checked`.
- **`mut`** is written for a field assigned through a name declared as its
  record, for an array or map held by a field that an index write or a
  `table` function changes (`table.move` changes its fifth argument, or its
  first without one), and for a collection parameter that the function
  changes the same way (834, 221 and 141 outside the fork). a record
  declares a field `mut` where its interface does, so the mark spreads to
  every type of the file that implements it and declares it, up through the
  interfaces that declare it (a super written [`Stream.Reader`] is the type of
  the file called `Reader`). a record that extends an interface of another
  file and is given `mut` on a field, declared or inherited, is a place
  `translated` counts when that interface, or one it extends, declares the
  field (12 in the tree: 3 declared, 9 inherited). a name counts only where
  its block binds it once, with the record's plain name as its type or as `self` in a
  method. the writes the syntax cannot attribute (a call's result, a field
  of a field, a collection passed on to a function that changes it) wait for
  the checker's type report.
- **a `goto continue`** becomes `continue` only where the nearest label a
  block around it holds, before a function ends, ends the body of the
  innermost loop; the label goes with the gotos that reach it. any other
  stays, with its label.
- **`;` between table items** becomes `,`: the parser ends the table at the
  first, so the ones after it, up to the first word that begins a block, are
  changed in the same read, and each after such a word takes a read of its
  own. a long comment followed by another long comment or by code stays.
- **the forms left**, pinned by file and code in `translated`: a tuple type
  or cast, `where`, a bare `function` type, a `goto` that is no `continue`, a
  reserved word as a name (the draft renames those first) and a method
  written in a block.

### what the scope builder settled

[`lang/scopes.tl`] resolves the names of a parsed chunk; [`build/scopes.tl`]
stays what the `build/` readers use until they are rewritten to the tree, and
then goes. it sets [`Name.binding`] and answers a `Var` per `Binding` by the
node's id, the uses of each (`reads`, `writes`, the type names that name it),
and the globals the chunk uses. its rules:

- **scoping is Lua 5.5's.** a local is visible from the token after its
  statement, a `local function`, record, class and the other declarations from
  their own name, a parameter in its whole function, a `for` variable in its
  body, a `match` binding in its arm and the locals of a `repeat` body in its
  `until`. the bounds of a `for` and the `elseif` conditions are outside the
  scope the arm before them opened.
- **one namespace, a space per binding.** as in the fork, a name is looked up once and
  the binding it finds says what it is for: a variable, a function, a
  parameter, a loop variable and a `match` binding are values, an enum, an
  interface, an alias and a type parameter are types, and a record, a class and
  an import are both. a type used as a value is `not_a_value`; a parameter, loop
  variable, `match` binding, function, or a local that holds no module, used
  as a type, is `not_a_type`. a local is the head of a type path only when it
  holds a module (`local Rules = require("rules")`, then `Rules.Grant`); a local
  that aliases a type through a value (`local Seatbelt = Rules.Seatbelt`) is
  refused, with the fix `local type Seatbelt = Rules.Seatbelt` (three sites in the
  tree, pinned). a primitive type name (`integer`, `string`, ...) is never a
  binding, and declaring a type, record, class, enum, alias or type parameter of
  that name is `primitive_type_name`.
- **types may be declared later in a signature or a type.** a type name in a
  function's signature or constraint, a type declaration or a function type
  may be declared later in an enclosing scope; one in the annotation of a local
  may not. this is the new checker's own rule, not the fork's, which is lazier
  (it rejects a name only where the type is used, and accepts `local x: {Later}`):
  the tree writes forward names in signatures and records about 50 times, and
  would not scope without it. the
  names of a signature wait outside the function, so a parameter or a local of
  the function never answers them. a name not declared by the end of the chunk
  is `unknown_type`.
- **globals are what a declaration file declares.** `build` takes the declared
  names; `declared` reads them off a `.d.tl` chunk, `do` blocks included. a use
  of any other name is `unknown_variable`, with the nearest name in scope or
  declared if one is within an edit or two, and a note where the name is
  declared later in its scope. a declaration file's `global` is not a local:
  any function may assign it.
- **captures.** a function that assigns a local of the code around it is
  `captured_assigned`. for each local a function reads from outside,
  [`Capture.after`] says whether an assignment may run after that function is
  made: one later in the source, one in the same statement, or one in a loop
  that holds both inside the local's scope. a test of the local inside the
  function narrows it only where this is false ([narrowing only what nothing
  else can change]).
- **shadowing is the fork's.** a declaration whose name is visible in an enclosing scope, the
  same scope or the declared globals is `shadows`, with the fork's exceptions: a name
  that begins with `_`, `self`, a type declared inside a record or class, `local x = x`
  (the copy, [`Var.copies`]), and a declared global that is a type (`any`, `thread`) hidden by a
  value. the parameters of `local function f` do not shadow `f`, as the fork has it.
- **read-only.** an assignment to a `<const>` or `<close>` variable, to the
  control variable of a numeric `for` and to the first variable of a generic
  `for` (Lua 5.5 refuses them) is `const_assigned`; `_ENV` declared or
  assigned is `env_reserved`; a narrowing return that names no parameter is
  `unknown_parameter`.
- **what the fork resolves that the builder does not.** the fork resolves a type
  name in a record by the scope where the record is used, so a field of the
  type `Orchestration.Group` finds a local of a function that uses the record
  (two sites in [`ci/cosmic_ci/orchestration_test.tl`], pinned in
  [`build/tree_checks.tl`]'s `scoped`). the builder reports `unknown_type`.

### who reads what

- [`build/analyzer.tl`] and [`build/link_text.tl`]: declarations and their
  `doc`, the `path` of a `Function` (what it hangs off), `Field` and
  `Name` chains for references, string values.
- [`build/contracts.tl`]: calls, `Return`, `Local`, function bodies,
  parameter and return lists, and one kind per operator in place of a
  switch on `op.op`.
- [`build/scopes.tl`]: `Block` extents from its tokens, every `Binding`,
  loops, `Function`, `If`, and `Repeat` (the `until` sees the body's
  locals). [`build/stub.tl`]: function-body spans to cut, `rets` nil for a
  literal typed by context.
- [`build/fix/`]: tokens with comments and offsets, spans, [`Block.close`],
  `Table` items, [`Binding.attr`].
- [`build/shape_specs.tl`], [`build/receivers.tl`], [`build/teal.tl`],
  [`build/importer.tl`], [`build/globals.tl`], [`build/tree_checks.tl`]:
  type nodes, `Require`, `Name` and `Binding` text, `Table` keys, node ids
  for the type report.

### the interface

[`build/compiler.d.tl`] declares what the tree uses of the checker, and
nothing else reaches into it. the new interface keeps its calls and
changes their types.

- `lex(source, name): {Token}, {Error}` and `parse(tokens, errs, name,
  dialect): Chunk`, where `dialect` is `tl` or `decl`. `Token`
  gains `offset` and `length`.
- `check(chunk, env, name): Result` and `generate(chunk, options):
  string`. [`Result.ast`] is a `Chunk`, not `any`; `Result.types` is the
  type report keyed by node id, so [`build/receivers.tl`] reads no
  positions.
- `Error` keeps its code, places and fix, so the hints in
  [`build/teal.tl`] read the same fields; the grammar adds the codes
  `reserved_word`, `label_or_goto`, `nil_union`, `method_in_record`,
  `continue_outside_loop` and `cast_refused`. the checker's rows keep
  their schemas ([what the language keeps working]).

## what the grammar leaves out, and how it would come back

counts are over the whole tree, tests included, unless noted. each cut
returns as the production named, when a use appears.

- **`T | nil`** (3,751 outside the fork): the translator respells it `T?`. a second
  spelling; it does not return.
- **`? T` as an omittable parameter** (100 in function types outside the
  fork): the translator writes `argN?: T`, N being its place. does not
  return.
- **`T...` as a parameter type** (68 outside the fork): respelled `...: T`.
  does not return.
- **`goto` and labels** (5, all `continue`). a general jump would add
  `goto Name` and `::Name::`.
- **`;`** (1 statement, in [`ci/cosmic_ci/orchestration.tl`]; 0 as a table
  separator): removed by hand. would add `";"` to `stat` and tables.
- **`#!` first line** (0 in `.tl`). would add `[ hashbang ]` to `chunk`.
- **a `lua` dialect** (0: no doc example outside `vendor/` is tagged `lua`).
  it would add a third value of `dialect`, with Lua's reserved words alone
  and none of the cut forms below, to the lexer and the parser.
- **long comments** (27, all in [`checker/stdlib.d.tl`]): rewritten as line
  comments. would add `--[==[ ... ]==]` to the lexer.
- **`_` digit separators** (4 tokens) and **hex floats** (1): the fork
  strips the separators, so removing them keeps the Lua. both would
  return in the number lexer.
- **string-call arguments** `f"s"` (0). `args` would gain `String`.
- **`function a.b.c()`** (0 with more than two names). `stat` would gain
  `{ "." Name }`.
- **type parameters on a function literal** (0) **and on a method** (0 of
  its own: the generic methods in [`cosmic/channel.tl`] repeat the class's
  `T`). `fn` and `method` would gain `[ typeparams ]`.
- **bare `function` and `table` types** (9 `function` outside the fork, in 4
  files; 0 `table`), **tuple tables** `{A, B}` (51 outside the fork, in 22
  files, most as `{{string, integer}}`; the tour has one) and **string-literal
  types** (0 asking for them: no union of records outside the tour). `base`
  would gain `String`, or a tuple form. the translator leaves each, and
  [`build/tree_checks.tl`]'s `translated` pins them by file.
- **`where`** (3: `FILE` and the tour's two), **`macroexp`** (0),
  **`<total>`** (0), **`--#pragma`** (0), **a table item with a type** (0
  by text) and **`metamethod`** (45, all `__close`, which becomes a
  `__close` field or class method).
- **combined constraints** `T is A & B` or a list (0 of 6) and **a generic
  interface as a constraint** (0). `tparam` would gain a list or `&`, and
  `tref` in place of `tname`.
- **a record or class implementing two interfaces** (0; one interface
  extends two) and **an array part beside an interface** (0). `record` and
  `class` would take a list.
- **`is` with a union or optional type** (0 of 652). `is` would take
  `type`.
- **`asserts v` without a type, `else` in a `match`, string, number and
  `is` patterns, and a value-yielding `match`** (the rule is new and its
  users are the `pcall` and `coroutine` sites, which need none). each
  returns when a rewrite of those sites asks.
- **`local type X = record ... end`** (5): the fork's declaration of a record
  or enum as a type. rewritten as `local record X ... end`; the parser refuses
  it and reads the declaration.
- **`defer`** (0), **a `view` marker** and **a packed tuple**: decided
  against, above.
- **checked and kept:** every Lua operator (`~` 27 binary and 7 unary, `^`
  8, `//` 270, the shifts 288), numeric `for` with a step (115), `repeat`
  (15), `while` (859), single-quoted strings (2,562), long strings (812),
  every string escape, `<const>` (1,423) and `<close>` (459), enum value
  comments (12), generic aliases, `local type x = require(...)` (106),
  string-key fields (`["end"]: string`, 3 in one test), and `userdata`
  (11) and overloads (26) in declaration files.

## the order the grammar lands in

- the `match` and `continue` bindings are renamed in Teal first, by an
  ordinary change the fork accepts, along with the hand rewrites in [what
  the grammar leaves out].
- the lexer and tree, with a round trip: every file of the tree is written
  back from its tokens and spans to the same bytes. the lexer is
  [`lang/lexer.tl`]. the new checker lives in `lang/` until it replaces the
  fork, as ordinary modules of the tree compiled by the tool's compiler and
  tested like any other. the fork sits outside the module closure because
  the pinned seed compiles it before a module system exists; the new checker
  is no one's seed yet, and moves to `checker/` in the change that replaces
  the fork. [`build/tree_checks.tl`]'s `lexed` lexes every `.tl` file of
  the tree in `fix --check .` and holds it to the cut forms it still writes,
  pinned by file and code. its `lex` answers a `Lexed` record of the tokens and the errors,
  since [`build/contracts.tl`] holds an exported function to one result; the
  declaration in [`build/compiler.d.tl`] may keep the pair.
- `cosmic compile --grammar new` ([`build/compile.tl`]) reads files in the
  grammar: lex, parse, scope, lower, check and generate, writing the line
  for line Lua despite type errors, as it does for Teal. the grammar is
  named by that flag and never guessed from a file, since a file in the new
  grammar keeps `.tl` (a marker in the file, or a path rule, would be the
  second way to say it). a release that carries the flag compiles the
  checker's own translated source once the switch's hand steps are made
  ([the switch]), which is what lets the pin move before it.
- the scope builder, [`lang/scopes.tl`], against the fork's `shadows`,
  `captured_assigned` and `unknown_variable` over the checker's corpora and
  generated programs, and over the tree: [`build/tree_checks.tl`]'s `scoped`
  scopes every `.tl` file in `fix --check .` and holds it to the errors the tree
  has, pinned by file and code.
- the translator and the oracle, before any type rule exists, so the
  lexer, parser and code generator are checked against the fork's Lua
  alone; then [`build/fix/`] and the readers above are rewritten to the
  tree beside the checker, the typed `Node` replacing the cast in
  [`build/ast/node.tl`].
- the first readers are rewritten as `build/syntax_<name>.tl` beside the one they replace ([`build/syntax_node.tl`],
  which also walks the tree and lists what a file requires, `_match`, `_rewrite`, `_scopes`, `_globals`, `_stub`,
  `_shape_specs`, `_derivation` and
  [`build/coverage/syntax_lines.tl`]), each taking the tree and never the compiler. [`build/syntax_compared.tl`]
  reads every file of the tree through the fork's readers and through these, over the translated file
  ([`lang.translate`]), and `fix --check .` holds the answers equal but for the `[read]` pins of
  [`build/ceilings.txt`] (no program declares a global and the check leaves out declaration files, so the globals are
  compared by the unit tests alone; a pattern `function $F() end` no longer compiles, as a program may not declare
  a global function). The switch deletes the fork's readers and the comparison, and moves each
  `build/syntax_<name>.tl` to the name it replaces.
- the readers of a parse's other rows follow the same way: [`build/syntax_analyzer.tl`] (the tests, the policy, the
  catalog, the docs, the examples, the references and the bound names), [`build/syntax_link_text.tl`] (the part of
  [`build/link_text.tl`] that reads a tree: the comments, what a file declares where each stands, and the links a source
  records), [`build/syntax_links.tl`] (the entries of [`build/links.tl`] that use it) and the rows of [`build/syntax_derivation.tl`].
  The rules a `policy` is held to are no tree's and moved into [`build/policy_rules.tl`], which both analyzers use;
  [`build/links.tl`] takes the way a file is read as a `Reader`; and [`build/link_files.tl`] needs no tree. The same
  `[read]` check compares each row of an analysis over every file, and a dimension that compared no row in a tree of any
  size fails it. Differences the grammar forces, each tested in [`build/syntax_analyzer_test.tl`] or
  `build/policy_rules_test.tl`: a class is documented as the record the fork documented, its methods as `method` rows
  `Class:name` with the head as written (`function read(self, max: integer?)`, where the fork had a field row
  `read: function(self: R)` and a `function R:read()` row, which the comparison merges); a field or method named `__x`
  is a `metamethod` row, with no `metamethod` keyword in the signature; a `goto` is a parse error, so a policy is never
  refused for a jump past its call. Kept as the fork reads them, each with a `TODO:` for the switch: a catalog message
  keeps its escapes and the line break that opens a long string, enum values are listed sorted, and the members of a
  generic type are not declared for link resolution. The consumers of a docs `signature` that the switch must read
  again are in [`build/docs.tl`]: they match a function-typed field (`name: function(`) at the `signature:match` and
  GLOB sites of the member listings and the parameter search, and a class method is now a `method` row whose signature
  is `function read(self, ...)`.

[annotated parameters]: strict-teal.md#annotated-parameters
[assigned before read]: strict-teal.md#assigned-before-read
[collections are views unless declared mutable]: strict-teal.md#collections-are-views-unless-declared-mutable
[compiler-written classes]: strict-teal.md#compiler-written-classes
[compiler-written classes, in the new checker]: strict-teal.md#compiler-written-classes-in-the-new-checker
[goto only as continue]: strict-teal.md#goto-only-as-continue
[honest `or` and `and`]: strict-teal.md#honest-or-and-and
[lookahead]: #lookahead
[narrowing only what nothing else can change]: strict-teal.md#narrowing-only-what-nothing-else-can-change
[named receivers]: strict-teal.md#named-receivers
[no casts]: strict-teal.md#no-casts
[no implicit conversion or hidden code]: strict-teal.md#no-implicit-conversion-or-hidden-code
[strict-teal.md]: strict-teal.md
[the new checker]: strict-teal.md#the-new-checker
[the switch]: strict-teal.md#the-switch
[what the grammar leaves out]: #what-the-grammar-leaves-out-and-how-it-would-come-back
[what the language keeps working]: strict-teal.md#what-the-language-keeps-working

[`Binding.attr`]: ../../lang/ast.tl
[`Block.close`]: ../../lang/ast.tl
[`build/analyzer.tl`]: ../../build/analyzer.tl
[`build/ast/node.tl`]: ../../build/ast/node.tl
[`build/ast/rewrite.tl`]: ../../build/ast/rewrite.tl
[`build/ast/walk.tl`]: ../../build/ast/walk.tl
[`build/ceilings.txt`]: ../../build/ceilings.txt
[`build/compile.tl`]: ../../build/compile.tl
[`build/compiler.d.tl`]: ../../build/compiler.d.tl
[`build/contracts.tl`]: ../../build/contracts.tl
[`build/coverage/syntax_lines.tl`]: ../../build/coverage/syntax_lines.tl
[`build/docs.tl`]: ../../build/docs.tl
[`build/globals.tl`]: ../../build/globals.tl
[`build/importer.tl`]: ../../build/importer.tl
[`build/link_files.tl`]: ../../build/link_files.tl
[`build/link_text.tl`]: ../../build/link_text.tl
[`build/links.tl`]: ../../build/links.tl
[`build/policy_rules.tl`]: ../../build/policy_rules.tl
[`build/receivers.tl`]: ../../build/receivers.tl
[`build/scopes.tl`]: ../../build/scopes.tl
[`build/shape_specs.tl`]: ../../build/shape_specs.tl
[`build/stub.tl`]: ../../build/stub.tl
[`build/syntax_analyzer.tl`]: ../../build/syntax_analyzer.tl
[`build/syntax_analyzer_test.tl`]: ../../build/syntax_analyzer_test.tl
[`build/syntax_compared.tl`]: ../../build/syntax_compared.tl
[`build/syntax_derivation.tl`]: ../../build/syntax_derivation.tl
[`build/syntax_link_text.tl`]: ../../build/syntax_link_text.tl
[`build/syntax_links.tl`]: ../../build/syntax_links.tl
[`build/syntax_node.tl`]: ../../build/syntax_node.tl
[`build/teal.tl`]: ../../build/teal.tl
[`build/tree_checks.tl`]: ../../build/tree_checks.tl
[`Capture.after`]: ../../lang/scopes.tl
[`checker/stdlib.d.tl`]: ../../checker/stdlib.d.tl
[`ci/cosmic_ci/orchestration.tl`]: ../../ci/cosmic_ci/orchestration.tl
[`ci/cosmic_ci/orchestration_test.tl`]: ../../ci/cosmic_ci/orchestration_test.tl
[`compiler.Result`]: ../../build/compiler.d.tl
[`cosmic/channel.tl`]: ../../cosmic/channel.tl
[`cosmic/http/wire.tl`]: ../../cosmic/http/wire.tl
[`cosmic/removed_example.tl`]: ../../cosmic/removed_example.tl
[`cosmic/web/init.tl`]: ../../cosmic/web/init.tl
[`lang.translate`]: ../../lang/translate.tl
[`lang/ast.tl`]: ../../lang/ast.tl
[`lang/lexer.tl`]: ../../lang/lexer.tl
[`lang/parser.tl`]: ../../lang/parser.tl
[`lang/scopes.tl`]: ../../lang/scopes.tl
[`lang/translate.tl`]: ../../lang/translate.tl
[`Name.binding`]: ../../lang/ast.tl
[`Result.ast`]: ../../build/compiler.d.tl
[`Stream.Reader`]: ../../cosmic/stream.tl
[`Var.copies`]: ../../lang/scopes.tl
