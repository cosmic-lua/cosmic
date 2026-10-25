# the new checker's types

a draft of the type system [the new checker] is built against, designed
before its checker as [the grammar](new-checker-grammar.md) was designed
before its parser. [strict-teal.md] holds the rules the types carry and the
order the work lands in; the grammar holds the syntax; this file holds what a
type is, how two types relate, how an expression is checked, how an error
reads, how a type becomes a row, and what checking costs. everything here is
intended, not built, so each example is a `text` block.

the types are constrained to what the repository needs. a form is here
because the tree writes it, or because a rule of the plan needs it to replace
something the tree writes; [what the types leave out] lists each cut. a
design choice is a rule in [the decisions], with the alternatives it did not
adopt, and the rest of the file applies them.

notation: `T <: U` reads "T is a subtype of U". a type is written as the
grammar spells it. counts are by text over the `.tl` files outside `vendor/`,
the fork and `testdata/`, so they are heuristics; each step that relies on
one counts again with the checker's own rows.

## what the checker starts from

- **the syntax tree and the scope builder.** [`lang/ast.tl`] keeps a type as it
  was spelled (`TypeName`, `TypeArray`, `TypeMap`, `TypeUnion`, `TypeOptional`,
  `TypeMut`, `TypeFunction`, `Narrows`, ...) beside the declarations;
  [`lang/scopes.tl`] has resolved every name, and [`Scoped.resolved`] maps each
  `TypeName` to its `Var`. so the type layer resolves nothing and decides no
  scoping, and a semantic type, this file's, is made from a syntax type once.
  a place's identity is [`Var.id`]; [`Var.assigned`], [`Var.captures`] with
  [`Capture.after`], and [`Var.copies`] are what narrowing and definite assignment
  read.
- **the declarations.** a `.d.tl` signature is the only typing taken without
  proof ("declarations are the trust boundary" in [strict-teal.md]): the Lua
  library's in `checker/stdlib.d.tl`, the tree's bindings in
  `cosmic/internal/*.d.tl`.
- **what the tree writes.** 1,786 records, 56 interfaces, 88 enums, 13
  generic records and interfaces, 65 `function<`, 6 constraints (four on one
  interface, [`build/alias_members.tl`]); `integer` annotates 6,328 places
  and `number` 710; of 3,120 `local function`s outside tests, `checker/` and
  `lang/`, 471 have no return annotation and return nothing.

## the forms

each form lists what needs it. a form with no entry is not here.

- **`integer`, `number`, `string`, `boolean`.** everything. `integer <:
  number` ([integer is below number](#integer-is-below-number)).
- **`true` and `false`.** the types of a position that tells the alternatives
  of a union of value lists apart (`pcall`, `match`). `boolean` is `true |
  false` and the union normalises to it.
- **`nil`.** a unit type, a member of no other type ([nil is its own type]).
- **`never`.** the bottom ([never is the bottom type]): `error`, the end of
  an exhaustive chain, a branch that cannot run.
- **`any`.** untrusted data and nothing else ([what `any` may
  do](#what-any-may-do)).
- **named types.** a *record* (fields and an optional array part: `record
  Node is {Node}`, 9 uses), a *class* (a record with methods, whose
  metatable the compiler writes), an *interface*, an *enum* (an ordered set
  of strings) and a *userdata* record (declarations only, 11 uses). each is a
  declaration with an identity; a use is the declaration and its type
  arguments, which generic ones take.
- **`{T}`, `mut {T}`, `{K:V}`, `mut {K:V}`.** a view unless `mut`
  ([collections are views unless declared mutable]).
- **functions.** parameters (some omittable, an optional rest), a set of
  return alternatives (below), optional type parameters. a method is a
  function whose first parameter is its declaring type.
- **`T?` and unions.** 3,751 `| nil` in the tree; `string | integer` (78
  uses) and `string | number` (83) are the unions it writes besides.
- **type variables with one bound.** `function<A>({A}, A)`; a bound is one
  interface (`<T is Ordered>`, [generic bodies compare, pass and store]).
- **`Coroutine<Y, R, S>`.** a generic userdata record in the standard
  library's declarations, not a form of its own ([pcall and coroutines are
  typed]).
- **`invalid`.** what a type that failed to lower becomes, so one mistake
  reports once; it relates to everything, and a program cannot write it.

a *value list* is not a type: it is what a call answers and a return gives.
a function's returns are a set of alternatives, each an ordered list of types
with an optional trailing `T...`. one alternative is the usual function;
`function(): (true, R) | (false, E)` has two, told apart by `true` and
`false` in a position. a list with a `never` in it is no list, so
`function(): never` has no alternative: it is the empty set, below every
set by the ordinary rule, and `never` needs no flag.

### what the types leave out

- **tuple tables `{A, B}`** (51, cut from the grammar): `table.unpack`
  declares `A...`, whose reads end in nil ([varargs end in nil]).
- **string-literal types and intersections:** no union of records outside the
  language tour ([`cosmic/removed_example.tl`]) needs them; a tag is a
  single-member enum.
- **`thread`:** nothing names it once coroutines are typed, so it leaves the
  primitives of [`lang/scopes.tl`] with raw `coroutine.*`.
- **a top type, type packs, type-level functions, declaration-site variance,
  `metatable<T>`, bounds over primitives:** `any` is a source and an argument
  sink, not a supertype; `pcall` needs no packs ([protected
  calls are enumerated overloads](#protected-calls-are-enumerated-overloads)); the plan rejects the last two. `math.abs` becomes
  two overloads, not `<N is Numeric>`.

## how a type is identified

### interning

**types are values, interned in a store.** a type is immutable and made by
`intern(kind, parts)`, which answers the one object for equal parts, so
equality is `==`. a store belongs to one check; its ids are local to it and
nothing outside keeps one.

- a union is normalised before it is interned: nested unions flatten, `never`
  and duplicates go, `any` absorbs, nil is a flag beside the other members in
  a fixed order, and three pairs collapse (`integer` into `number`, an enum
  into `string`, `true` with `false` into `boolean`). a union of one member is
  that member. no other subsumption is searched for, since it would cost a
  quadratic comparison on every union, so `R | I` and `I` for an `R` that
  implements `I` are different types, each below the other. an invariant
  position compares by `==`, so `mut {R | I}` is not `mut {I}`; the error says
  to write one of them.
- a type variable is numbered by binder and position, so two spellings of one
  generic signature intern to one type. a type caches whether a view of it
  differs from it and whether it mentions a variable, so `view(T)` and
  instantiation return the type itself when they would change nothing.
- an alias creates no type: its use is what it names, arguments substituted.
  an alias that reaches itself with no declaration between is refused.

### declarations

**a named type is its declaration and its arguments.** a declaration has a
*path* (the module's name, then the names it is nested under) and a body:
type parameters, `supers`, ordered `fields`, `array?`, `methods`, or an
enum's `values`. comparison of named types is by path and arguments and
never unfolds a body to compare two uses, so a recursive record cannot loop the relation and
the relation needs no assumption set (the fork counts open comparisons for it). it reads
`supers` for the interfaces a type lists and `array?` for a record's view, as [the
relation](#the-relation) says.
a body is checked once, where it is declared:

- **interface agreement.** a type that lists an interface has every field of
  it and of every interface it extends, of exactly the interface's type
  (a method's receiver aside) and `mut` exactly where the interface is
  ([fields are fixed unless declared mutable]). the closure of its supers is
  computed here, so `R <: I` later is a set lookup.
- **a tag.** a union alias of records is legal only if each member has one
  shared field typed by a distinct single-member enum ([tagged unions]).
- **a dense array.** `{T?}` and `{K: V?}` are refused ([arrays are dense]),
  and so is an instance that makes one: `{A}` with `A = string?`.
- **a key.** a map key is `integer`, `string`, `boolean`, an enum, or a record,
  class, interface or userdata (by identity; 45 uses key by a node), never
  `number` ([numeric keys are integers]), `any` or an optional.
- **distinct names.** a class's fields and methods share no name; a repeated
  function-typed field is an overload, legal in a declaration file only.

### rows

**types cross processes as rows** ([the database](strict-teal.md#the-database)).
a type is never stored by id but by a *canonical encoding*: a text that names
a declaration by its path and builds the rest from its parts, so any process
decodes it into its own store. union members are sorted by their digest, the
hash of the encoding with each part written as its own digest (a Merkle hash,
so a part held many times costs once), so the text does not depend on the
process that wrote it.

```text
(array (ref "cosmic.stream" "Stream.Reader"))         {Stream.Reader}
(mmap string (union (ref "sys" "Fd") nil))            mut {string: Fd?}
(fn (tp (ref "m" "Ordered")) ((var 0 0)) (rets ((var 0 0))))   function<T is Ordered>(T): T
(fn (tp) () (rets (true string) (false any)))         function(): (true, string) | (false, any)
```

- **a row per declaration.** `declared(key, path, decl_hash, body)`: the body
  encodes one declaration, and path "" is the type of the module's returned
  value. a module returns a name whose type is written, a declaration, or a
  function literal with a written signature; any other return is
  `export_not_declared`, so an interface never depends on a body.
- **the declaration hash is a Merkle hash** of the body and the hashes of the
  declarations it reaches. a strongly connected group (a record that mentions
  itself, two that mention each other) is hashed as one unit with its members
  numbered inside it. an edit that leaves a declaration and everything it
  reaches alone leaves its hash.
- **an interface hash** is the hash of a module's declaration hashes in path
  order. the stub, the compile key and the check key of a requiring module
  read it.
- **declarations are decoded when looked up.** a worker reads the row of a
  name a module uses, and decodes what that reaches the first time a
  comparison reaches it. it checks any module from rows alone and parses no
  requirement. the globals of the declaration files ([`Scopes.declared`])
  are looked up by name the same way.
- **a check is verified by its trace.** a check records each lookup it made in
  another module as (module, path, hash seen or absent). a later check of
  the same source and tool is reused if every recorded lookup still sees the
  same hash. an *absent* lookup is recorded because adding the declaration it
  missed changes the result; an overload set is one declaration, so a changed
  overload changes its hash. this is the plan's "recheck for what a module
  uses", with the `uses` rows as its first approximation: the first check of
  a changed module keys on whole interface hashes, and the trace narrows
  later ones.

## the relation

one relation, `T <: U`, in the rules below. it reads a declaration's `supers` and
array part, never its fields or methods, and compares two uses of a declaration by
path and arguments. so it ends by recursion on the structure of anonymous types, which
is finite: a body is read only to find the interfaces a type lists, which a bound
ends, and to take a record's array part, where the type compared with is smaller. each result is cached per pair in the judge of [`lang/relation.tl`], not in the store: a
pair that mentions a type variable depends on the binders it is asked under, and the ids that key
the cache are the store's, which a refused decode reuses, so nothing is related while a decode is
open.

- **identity and bottom.** `T <: T`. `never <: T` for every `T`; nothing else
  is below `never`.
- **nil.** `nil <: U` only if `U` is `nil` or has the nil flag; `T <: T?`. no
  other type admits nil, a type variable included: a `T` in a generic body may
  be nil, and nothing makes a `T` out of a value.
- **numbers and strings.** `integer <: number`; an enum `<: string`; `true`
  and `false` `<: boolean`. nothing else. `number` is never below `integer`;
  a conversion is a call.
- **unions.** `A | B <: U` iff each member is `<: U`. `T <: A | B` iff `T <:`
  some member, complete because unions are flat and the pairs collapsed.
- **views are covariant.** `{A} <: {B}` and `mut {A} <: {B}` iff `A <: B`, and
  likewise for a map's value. a map's key is invariant even in a view: a read
  takes a key in and an iteration gives one out. a record with an array part
  `T` is `<: {T}`, never `<: mut {T}`.
- **`mut` is invariant.** `mut {A} <: mut {B}` iff `A == B`, likewise for a
  map's key and value. a view is never `<: mut`.
- **functions.** `F <: G` iff each parameter of `G` is `<:` the matching one of
  `F` (contravariant), `F` accepts every argument count `G` is called with,
  and each return alternative of `F` is `<:` some alternative of `G` (equal
  length, each type `<:`; a trailing `T...` matches one). a method has no
  receiver exemption ([named receivers]). the empty set of alternatives
  (`never`) is below any set.
- **named types are nominal.** `Named(d, args) <: Named(d, args')` iff the
  arguments are `==` (a generic is invariant). `Named(d, args) <: Named(i,
  iargs)` for an interface iff `i` is in `d`'s closure of supers,
  instantiated with `args`, with `==` arguments; an interface is below the
  interfaces it extends by the same closure. a record is never `<:` a map
  nor a map a record ([records are not maps]).
- **type variables.** `V <: V` and `V <:` its bound. inside a generic body a
  value of `V` is passed, stored and compared as `V`.
- **`any`.** `any <: any`. `T <: any` holds in one position, an argument to
  a parameter declared `any`. contravariance does not widen it, so a
  `function(any)` is not a `function(string)` callback.

**instantiation.** a generic function is instantiated at its call, or by
matching when passed where a non-generic function type is expected. a generic
function type that a parameter expects is met only by an identical signature
(variables are numbered, so identical is `==`). the store caches `(generic,
arguments)`.

### what `any` may do

`any` is what the untrusted entry declarations answer (`string.unpack`, the
[`cosmic.sys`] bindings, the failure of a protected call) and what a validator
accepts. values reach it only as an argument to a parameter declared `any`
(`print`, `tostring`, `error`, `type`, a validator `function(v: any): v is
Reader`), and nothing is read out of it.

- *allowed:* pass it to a parameter declared `any`; compare it with `==`;
  narrow it by a test the run-time tag settles (`integer`, `number`,
  `string`, `boolean`, `nil`, `true`, `false`, an enum's members, a class's
  metatable, `type(x) == "..."`); narrow it by a validator's `v is T`.
- *refused:* call, index or operate on it; assign it to a local, field or
  element whose type is not `any`; return it where `any` is not declared;
  write `any` in a `.tl` annotation except as a parameter that accepts
  everything. `{string: any}` is no type outside an entry declaration.
  `x is {string}` and `x is function` on an `any` are refused, since the tag
  says "table" or "function" and the contents go unchecked: the error names a
  [`cosmic.shape`] validator. on a union scrutinee any member may be tested.

a record passed to a sink can never be got back, which is the plan's "a record
is never assigned to `any`", and `print` and `error` get a type ([the
decision](#any-is-a-source-and-a-sink)).

## checking

the checker is bidirectional: `infer(expr)` answers a type, `check(expr,
expected)` verifies against one and uses it to type a literal. errors are in
[errors](#errors).

### expressions

- **literals.** an integer literal is `integer`, a float `number`, a string
  `string`; `true` is accepted where `true` or `boolean` is wanted and infers
  `boolean`. a string literal checked against an enum is accepted if it is a
  member, and the error lists the members and the nearest.
- **`..`** takes two `string`s ([no implicit conversion or hidden code]); a
  number needs `tostring` or `string.format`.
- **arithmetic** `+ - * % //` takes `integer` or `number`: two `integer`s give
  `integer`, otherwise `number`. `/` and `^` give `number`. unary `-` keeps
  its operand's type. `& | ~ << >>` and unary `~` take `integer`. no operator
  takes a string or an optional.
- **comparison** `< <= > >=` takes two numbers (`integer` and `number` mix) or
  two strings. `==` and `~=` take two types that *overlap*: some member of one
  is `<:` some member of the other (`integer` overlaps `number`, an enum
  overlaps `string`, `nil` overlaps an optional, `any` overlaps anything, a
  variable overlaps itself and `nil`). two that cannot be equal are refused,
  which finds the dead test.
- **`#`** takes a `string` or a view (a record with an array part included)
  and answers `integer`; a map is refused.
- **conditions, `not`, `or`, `and`** follow [conditions are booleans or
  optionals] and [honest `or` and `and`]. `a or b`: both `boolean` gives
  `boolean`; `a: T?` gives the join of `T` and `b`'s type. `a and b`: both
  `boolean` gives `boolean`; `a: T?` gives `U?` for `b`'s type `U`, `b`
  checked under `a`'s true facts. any other mix is `or_mix`; `c and x or y` is
  `and_ternary`.
- **`if` expression.** its arms have a *join*: the type every arm is `<:`
  (`never` arms ignored). with none the error is `arms_differ` and asks for a
  type ([arms and elements join to a common type](#arms-and-elements-join-to-a-common-type)).
- **`Cast`** is `cast_refused`, naming the check that replaces it.

### names, fields and indexes

- **`r.f`** on a record or class is the field's type with the arguments
  substituted. on `T?` or a map it is refused (a map is read by `m[k]`). on a
  union, `f` must be a field of every member and the answer is the union of
  the field types, which is a tagged union's tag read.
- **`r[k]`** on a record is legal where `k`'s type is an enum or a literal
  naming fields, and answers the union of them ([records are not maps]). on
  `{T}` the key is `integer` and the answer `T?`; on `{K:V}` the key is `<: K`
  and the answer `V?` ([an index read may be nil]). through a view the answer
  is the *view* of the element: `view(mut {T})` is `{view(T)}`, applied through
  arrays, maps and unions and not through a named type, so a record read out
  of a view keeps its fixed and `mut` fields.
- **a method call** `o:m(a)` is the field `m` of `o`'s type, called with `o`
  first. on a primitive the field is looked up in the declared global record
  of the same name (`s:upper()` finds `string.upper`).
- **a write** `r.f = v` needs `f` declared `mut` and `v <:` its type. `a[i] =
  v` needs `a: mut {T}`, `v <: T` and an index that cannot make a hole (the
  append `a[#a + 1]`; [index writes append](#index-writes-append)). `m[k] = v` needs `m: mut
  {K:V}`; `m[k] = nil` deletes the key and is the only write of nil.

### table literals

**a literal is a record only where checked against one** ([fields are fixed
unless declared mutable]). `check(Table, expected)`:

- *a record or class:* each field given once, none the record lacks, every
  non-omittable field present (a class names every field), each value checked
  against its field. a record with an array part also takes positional items.
- *`{T}` or `mut {T}`:* positional items against `T`. *`{K:V}`:* keyed items.
  an item of the other shape is `literal_shape`.
- *a union:* the member a tagged union's tag literal selects, else the one
  record or class member; with several candidates `literal_ambiguous` says to
  type the literal.
- *an interface or an enum:* refused. a value of an interface is made by a
  class that lists it; the 52 locals typed with a stream interface and made
  by a literal become classes.

with no expected type a literal is `mut {T}` or `mut {K:V}` with the join of
its items; `{}` alone is `literal_needs_type` (27 `local x = {}`), and the fix
names the annotation, `local x: mut {string} = {}`. a `mut {T}` passes where a
view is expected.

### calls and overloads

- **arguments** are checked left to right. a missing one is refused unless the
  parameter is omittable (`name?: T`, typed `T?` inside), a surplus one unless
  there is a rest parameter. **overloads** exist in declarations only: the
  call takes the first, in declared order, whose parameters accept the
  arguments (literal arguments checked last, against that candidate); when
  none does, `overload_none` lists each with the first argument it refused.
- **returns.** a call with one alternative answers its list. where one value is
  wanted it gives the first element, `T?` if the list may be empty or ends in
  `T...` ([varargs end in nil]). a call with several alternatives is no value:
  it is the scrutinee of a `match` or the right side of `local a, b = call()`,
  which gives each name the union of its column (a column a shorter
  alternative lacks adds `nil`), unlinked from the others.
- **generic inference** is local to the call ([generic
  inference is local to the call](#generic-inference-is-local-to-the-call)). variables are solved left to right: a
  non-literal argument is matched against its parameter (a covariant position
  grows the bound to a type both are `<:`, else `infer_conflict`; an invariant
  one needs `==`); the call's expected type binds a variable no argument
  bound; function literals are then checked with parameter types read from
  the instance. an unbound variable is `cannot_infer` and the fix is to type
  the result. each variable is last checked against its bound.
- **narrowing declarations.** a callee returning `v is T` narrows the
  argument for `v` to `T` when true; `asserts v is T` narrows it after the
  call returns. `assert` is `function<T>(v: T?, message?: string): asserts v
  is T`, so its special case goes.
- **iteration.** a generic `for` takes the iterator, state and control value;
  the iterator's alternatives that start with `nil` end the loop and the rest
  give the variables their column types. `ipairs`, `pairs`, `next`,
  `string.gmatch` and `utf8.codes` are plain declarations of this shape, and
  `pairs` of a record is refused because a record is not a `{K:V}`.
- **protected calls.** `pcall` and `xpcall` answer `(true, R...) | (false,
  any)` ([protected calls are enumerated overloads](#protected-calls-are-enumerated-overloads)).

### returns and bodies

a `return` is checked against the declared alternatives: the length, then each
value. a function with alternatives whose end is reachable is `missing_return`,
named at its last statement. a function with no return annotation returns
nothing, and `return v` in it is `return_unexpected`. parameters are annotated
unless the literal is checked against a function type ([annotated
parameters]); `local x = e` has the type of `e` and `local x: T = e` checks
it; nothing else is inferred, so a signature never depends on a body.

### narrowing and reachability

the flow is [narrowing by construction] with the new places and joins.
`checker/facts.tl` knows no type beyond identity (it takes `unite`, `is_a`
and `fixed`), so it is reused as written with interned types as its values.

- **places** are a local, keyed by [`Var.id`], and a path of fixed fields from
  one (`17.a.b`, no field `mut`). a global, a `mut` field and an index are
  not places. a local of the code around a function is a place inside it only
  if [`Capture.after`] is false; the facts at the function's creation flow in
  and no others.
- **facts** map a place to the type it has been narrowed to and never change
  the declared type. a condition leaves a pair, the facts when true and
  false. a join keeps a place held on both edges as the union of its two
  types, never wider than its declared type.
- **what narrows** is the guard list of [narrowing only what nothing else can
  change]: an optional, `== nil`, `~= nil`, `is`, a tag compared with a
  literal, `type(x) == "..."`, `not`, `and`, `or` of these, a narrowing
  declaration, a branch that ends its block.
- **restricting a type** by a test is one function over the union: keep the
  members that overlap, replace a member by the tested type where that is
  `<:` it (`any` or an interface becomes the class tested), and in the false
  edge remove members `<:` the test. a tag test keeps the members whose tag
  enum holds the literal.
- **a place narrowed to `never` makes its edge unreachable,** by the
  mechanism that a `return` and a call of a `never` function use. it lets a
  chain of tag tests that covers every member end a function.
- **an assignment** to a place drops the facts of it and every path from it, then narrows it to the view of the value's type
  (see [flow reads the rules strictly](#flow-reads-the-rules-strictly)). nothing else changes a place:
  a call, a closure, an alias or an operator cannot.
- **definite assignment** is a state in the same map. `local x: T` with no
  value puts `x` in as *unset*; a read of an unset place is `not_assigned`; a
  join keeps it assigned only if both edges assign it; a function literal
  reads each outer variable it names where it is made.
- **loops** are walked to a fixed point: the head is where the entry and the back edge (the end of the body, with
  its `continue`s) meet, so a fact the back edge loses is lost at the head, and the exit keeps a head fact only if
  the back edge does. the passes that settle the head report nothing; one more, from the head they settle on,
  does. [flow reads the rules strictly](#flow-reads-the-rules-strictly) has the rest.

### `match` and tagged unions

`match call() do | (true, v) then ... | (false, why) then ... end`: the
scrutinee's alternatives are the members. an arm selects the alternative
whose `true` and `false` positions it names, and binds the other positions to
that alternative's types. the arms cover the members exactly: `match_missing`
names the alternative left and the arm that covers it, `match_redundant` an
arm that selects none. two alternatives that no position of `true` and `false`
tells apart are refused where the function type is declared (`lists_overlap`).
a union of records is a tagged union by its shared tag, narrowed by `==` on
the tag or `is` on a class.

## errors

an error is a record: `code` (the name of a rule), `msg` (what is wrong, one
line), `fix` (the change that fixes it, in the program's own names), the place
at fault (`y`, `x`, `offset`, `length`), `other` (the second place, when two
are involved) and the types it is about, shown as the program spells them
(`string?`, never `string | nil`), for tools that read them. it is
[`lang/scopes.tl`]'s `Error`, extended. a type is shown by its declared name,
qualified only when two in scope share it.

- **a code is a row.** `catalog` gets, for each code, the rule's name, why
  it holds and the fix template, indexed by FTS5, so `cosmic docs <code>` and
  the error read one text. a test per code builds the program and pins the fix,
  as `test_a_value_that_may_be_nil_is_told_the_check` does for the fork.
  [`lang/syntax_codes.tl`] holds the rows of the lexer, the parser and the scope
  builder; [`build/error_catalog.tl`] joins them with the other catalogs and writes
  each as a `catalog` row of kind `code`, which `cosmic docs <code>` answers from;
  [`build/error_render.tl`] prints an error as `file:line:column: message (code):
  fix`; and [`build/removed_fix.tl`] gives the error for a name [`cosmic.removed`]
  lists its replacement as the fix. the build calls them at the switch.
- **a fix is never empty.** an error whose fix the checker cannot state is a
  bug in the error. where two places matter it names both: a nil names the
  call that answered it and where that is declared; a dropped narrowing
  names the assignment.

the main codes, each named for its rule, with a fix in the program's names:

- `nil_not_allowed` ([nil is its own type]): "`line` is `string?`, as [`Fs.read`]
  (cosmic/fs.tl) answers: test it, `if line == nil then return nil, why end`,
  or `assert(line)`."
- `index_may_be_nil` ([an index read may be nil]): "`xs[i]` is `Row?`: `local
  row = xs[i] if row ~= nil then ... end`, or `for _, row in ipairs(xs)`."
- `not_assignable` (the relation): "`n` is `number` where `integer` is wanted:
  convert with `math.tointeger(n)` or `math.floor(n)`."
- `view_written` ([collections are views unless declared mutable]): "`xs` is a
  view, so `xs[#xs + 1] = v` is refused: declare the parameter `xs: mut {T}`."
- `invariant_mut` ([one variance per type constructor]): "`mut {integer}` is
  not `mut {number}`: a callee could store a float. pass a view, or declare
  the callee's parameter `mut {integer}`."
- `field_fixed` ([fields are fixed unless declared mutable]): "`Job.state` is
  fixed: declare `mut state: State` in `Job`, or make a new `Job`."
- `condition_type`, `or_mix`, `and_ternary`, `concat_type`, `float_key`:
  "`name` is a `string`: test `name ~= ""`." / "use the `if` expression: `if ok
  then a else b end`." / "`count` is an `integer`: write `tostring(count)`."
- `match_missing`: "add the arm `| (false, why) then`."
- `generic_op`: "`<` needs a constraint: declare `T is Ordered`."
- `any_use`, `cast_refused`: "`v` is untrusted data: validate it with a
  [`cosmic.shape`] validator, or test its tag." / "`as` is not in the
  language: validate, test with `is`, or delete the cast."

the others are named for the rule or form they refuse: `record_as_map`,
`array_of_optional`, `view_as_mut`, `is_on_record`, `is_disjoint`, `match_redundant`,
`lists_overlap`, `interface_disagrees`, `literal_missing`, `literal_unknown`,
`literal_needs_type`, `literal_ambiguous`, `literal_shape`, `arms_differ`,
`overload_none`, `arity`, `cannot_infer`, `infer_conflict`, `bound_unmet`, `match_pattern`, `missing_return`,
`return_unexpected`, `not_assigned`, `export_not_declared`, `unreachable`, and
`narrowing_dropped`, kept from the fork, and the expressions' own (`nil_not_allowed` and the rest of [`lang/check_codes.tl`]). a binding of C, which the checker types once it reads the bindings from declaration files, is typed `invalid` and reported as `unchecked_binding`, so no `invalid` is silent. each has a fix pinned by its test. the declarations'
lowering adds `super_not_interface`, `super_cycle`, `listing_too_large`, `untagged_union`, `key_type`, `repeated_field`,
`repeated_value`, `type_arguments`, `type_too_deep`, `alias_cycle`, `bound_not_interface`, `bound_not_met`, `outer_type_parameter`,
`member_missing`, `param_untyped`, `thread_type` and `store_refused`, and uses `float_key` and `array_of_optional`
for the declarations that break their rules.

## performance

the checker is written for the language the foundations leave: no fixpoint, no
unfolding, no per-site nil logic. targets are ratios taken on the tree by
[`bin/perf`] and the speed harness [`lang/speed.tl`], never clocks, and are
set when the first measurement exists.

- **a module is checked from rows.** no requirement is parsed or checked; the
  cost of one is the lookups the module makes and the declarations they decode.
- **identity is `==`.** equality is a comparison, a relation result a cached
  boolean per pair, a nominal comparison a path lookup. each body is walked
  once with the facts register.
- **cold:** the translated tree checks in at most half the fork's time on the
  same database (target). **linear:** four times a module's size costs about
  four times the time, held for each shape that could cost more (a long union,
  nested generics, a record of many fields, a chain of `and`/`or`), as
  [`lang/scopes_speed_test.tl`] holds the builder.
- **warm:** a body edit to a leaf module rechecks that module only; a
  signature edit rechecks the modules whose trace read it, measured on the
  deep-chain workload against the whole-interface key before the trace is kept
  ("the database" in [strict-teal.md]).
- **known cost: declaring a chain of interfaces is quadratic.**
  [`Store.define`] walks a declaration's whole ancestry to refuse a cycle,
  so a chain of n interfaces costs n squared to declare.
  [`lang/relation_speed_test.tl`] found it, and times the relation of a
  chain with the build left out of the work. keeping what each declaration
  reaches makes the check a lookup.

## the order the pieces land in

each is a PR with its tests and a check in [`build/tree_checks.tl`], beside
`lexed` and `scoped`, that checks the translated tree and counts errors per
code, pinned by file and code. a rule's ceiling is its codes' count; it only
falls ([a count the tree cannot yet bring to zero is a ceiling]) and a new
violation is refused. every error has a code, a fix and a catalogue row from
the PR that adds it. the translator ([`lang/translate.tl`]), the scope
builder and the speed harness exist already. a piece is briefed to its
builder in a page of this file, not the whole plan. the pieces end at [the
switch]: the new checker replaces the fork once it is at least as sound as
the fork, and rows and incremental checking come after it.

- **the store.** forms, interning, union normal form, display. property
  tests: interning is idempotent, a union does not depend on member order, an
  encoded type decodes to the same type in a second store.
- **the relation.** every rule above, with the refused programs of the plan
  (the pinned holes of build/teal_test.tl, translated). property tests:
  reflexive, transitive, `never` below everything, only `nil` and optionals
  admit nil, a `mut` collection is invariant.
- **declarations.** lowering of every declaration and annotation with its
  checks (agreement, tags, keys, dense arrays). the tree check lowers every
  declaration of the tree and pins what fails.
- **the code generator and the oracle.** the grammar draft planned them
  ([the order the grammar lands in]) and they land here. [`lang/codegen.tl`]
  writes the tree as Lua, a statement on its source line, and `generated` in
  [`build/tree_checks.tl`] holds that Lua to the fork's for every translated
  file: byte for byte where the construct is a respelling, after the one
  normalization the grammar table gives a `continue`, and a pin for each file
  with a `class`, which the generator refuses.
- **expressions without flow.** operators, calls, overloads, literals, fields,
  writes, returns. the ceilings for nil, indexes, views, mutable fields,
  records as maps, conditions, `or`/`and`, concatenation and numeric keys
  start here. once expressions exist, the speed harness measures checking the
  whole tree in one process against the test suite's budget. that
  decides where rows go. measured, cold, on the 1,039 files: lowering takes
  5.1 s and checking 3.8 s, 9 s together (39 s with the 30 s of translating,
  parsing and scoping that every check repeats), against the 30 s of `cosmic test` in an
  edit loop and the 153 s of a run that finds 1,179 tests unstood. that is fast
  enough, so rows come after the switch.
- **classes,** built once, here ([compiler-written classes, in the new
  checker]): nominal class types, the class literal and its reserved form. it
  follows the expressions, since a class literal is checked against the expected
  type they compute: the class piece lifts the generator's refusal of a `class`
  and of `is` of a class, and the pins of `generated` fall with it.
- **flow.** facts, narrowing, definite assignment, reachability, with the fuzz
  and checked narrowing of [narrowing by construction] run against it.
- **generics, `match`, tagged unions, protected calls and coroutines.** they
  share a seam, the instantiation of a call and the alternatives of a union,
  so they land as few pieces as the seam allows, cut where the work cuts.
  `table.insert`, `ipairs`, `assert`, `pcall` and `Coroutine` lose their
  special cases to declarations.
- **the driver.** [`build/driver.tl`] builds one program over a module graph
  from providers (the tree's files, the `cosmic.*` modules, stubs, and the
  declaration files of the standard library, [`lang/prelude.d.tl`] and
  [`lang/stdlib.d.tl`]), and gives each module
  its errors, its warnings ([`lang/warnings.tl`]: `unused`, `unread`, `branch`,
  `hint`, each with a code and a catalogue row) and the type of every node it
  typed, by the id of the node. the tree checks run through it. the ceilings are
  data in [`build/ceilings.txt`], and the driver refuses a module over its
  ceiling with the same words as `fix --check .`.
- **the bindings of C.** the driver reads the `.d.tl` declarations the build
  derives for [`cosmic.sys`] and the raw C modules, so a call into C has a
  callee, a result type and a contract. the fork enforces the contract
  rules (build/contracts.tl) on about 740 such call sites, and a
  checker that leaves them untyped does not see them. the piece lands
  before the switch, with a `[typed]` ceiling for the calls that still have
  no callee ([the switch]), and the `unchecked_binding` ceilings fall with
  it.
- **cheaper comparisons with the fork.** the `[read]` and `[typed]` checks
  of [`build/tree_checks.tl`] add about four to five minutes to a cold
  `cosmic fix --check .`. their cost is cut before another comparison is
  added, by reading the fork's rows from the working database instead of
  deriving them again. they go with the fork at the switch.
- **the switch.** the gate, then one change that commits the translated tree
  and deletes `checker/` and the translator.
- **rows, then incremental,** after the switch if checking the whole tree in
  one process is fast enough for the test suite, and if it is not, before
  it, after declarations. rows are encoding, Merkle hashes, interface hashes
  and decoding, with a test that checks a module in a second process from
  rows alone and compares every verdict. incremental is the trace, the worker
  split that replaces build/shards.tl, and the speed workloads.

## decisions

each is a rule the file above applies. the owner chose nominal interfaces; the
others follow its stance: sound by default, nominal, and only what the repo
needs. *not adopted* names an alternative that was weighed.

### interface conformance is nominal

a type conforms to an interface only if it lists the interface with `is`, and
agreement is checked once at the declaration, so a conformance test is a set
lookup. the tree's own comment calls Teal's conformance nominal, a class is
told from another at run time by its metatable alone, and `mut` and generics
stay invariant simply. a table literal is never an interface value: the 52
locals typed with a stream interface and made by a literal, and the test
doubles, become small classes. *not adopted:* structural conformance, and
structural conformance for literals only.

### integer is below number

`integer <: number` and never the reverse. the VM keeps both subtypes, 6,328
`integer` and 710 `number` annotations mix (`math.sqrt(n)`), and `mut
{integer}` is invariant, so no float is stored in an integer array. *not
adopted:* unrelated types converted by a call, which adds a conversion at
every call of a `number` function and finds no bug; one type.

### enums are nominal strings

an enum is a nominal type with a member set, `<: string`, and a string literal
is accepted where it is a member. the grammar left literal types out because
no count asked for them, and a single-member enum is a tagged union's tag (19
enum-typed `kind`, `type` and `tag` fields exist). *not adopted:* a union of
string-literal types; an enum that is not a `string`, which breaks every use
of an enum as text.

### signatures are never inferred

a local takes the type of its initializer, a generic is solved per call, and
nothing else is inferred. an unannotated function in the tree returns nothing,
and this keeps an interface independent of bodies, which the rows need. *not
adopted:* the return type of an unannotated local function (no site asks for
it); a module-wide pass.

### any is a source and a sink

as in [what `any` may do](#what-any-may-do): untrusted data comes out of entry
declarations, and a value goes in only as an argument to a parameter declared
`any`. `error` takes tables, `type` takes anything and a validator takes data
it cannot name. *not adopted:* a distinct top type `unknown` for sinks, which
adds a spelling the grammar lacks for the same effect; `any` accepting
nothing, with `print`, `tostring`, `error` and `type` as overloads of
primitives, which cannot type `error` or `type`.

### generic inference is local to the call

variables are solved left to right, the expected type last, and none outlives
the call. the 65 generic functions are solved by their arguments or their
expected result (`Queue.new()`). *not adopted:* a unification pass, which
brings back the fork's `typevar` machinery.

### rows are canonical text

a declaration's row is its canonical text, as in [rows](#rows). an interface is
read a declaration at a time, text hashes simply and a person reads the row.
counts come from the type report, not these rows. *not adopted:* a table of
type nodes with ids joined to load; a binary blob per module.

### protected calls are enumerated overloads

`pcall` and `xpcall` are declared as overloads over the return and argument
counts, as `table.unpack` is today. the arities are those the type report
shows for the tree's 132 sites when the declaration is written. *not adopted:*
type packs in the grammar (`function<R...>`), a form nothing else uses; a
zero-argument thunk with at most one value, which forces a wrapper at each
call that passes arguments.

### yield goes through a handle

`create: function<Y,R,S>(function(Yielder<Y,S>, S): R)`: the coroutine body
receives a handle that yields `Y` and is resumed with `S`. `yield` is
dynamically scoped, so no type says which coroutine a bare `yield` feeds, and
a handle is the only sound form. only [`cosmic.poll`] creates and resumes
coroutines (13 sites); it keeps the handle in its task record, which its
`coroutine.running()` lookup already finds. *not adopted:* a declared
`yield<Y,S>` checked at the resume in test runs; a yield the scheduler
declares for itself.

### index writes append

`t[#t + 1] = v` and `table.insert` are the writes that grow an array, so no
write makes a hole ([arrays are dense]). an overwrite at a loop index is left
out and returns as a rule if a count of such sites asks. *not adopted:* any
integer index, which breaks [arrays are dense].

### overloads take the first match

the first overload that accepts, in declared order. overloads exist in
declarations only (26), a person orders them, and the rule needs no
specificity relation. *not adopted:* the most specific overload.

### arms and elements join to a common type

the type of `if` arms and literal elements is the type all are `<:`, else the
error asks for a type. `{1, "a"}` as `{integer | string}` is nearly always a
mistake, and the union can be written. *not adopted:* the union of the
members.

### the relation reads the rules strictly

[`lang/relation.tl`] is these rules over the interned types of a store. where a rule above is
silent or allows two readings, the judge takes the one that refuses more, and a looser one is
added when a measurement asks for it. *not adopted:* each reading's looser form, named here.

- **`any` is a sink in one position only.** `accepts(argument, param)` is true for a parameter
  declared `any` (a rest parameter included), and the relation proper never admits a type below
  `any`. so `function(): string` is not `function(): any`, `{string}` is not `{any}`, and a
  function over `any` is not a function over `string`. *not adopted:* `any` as a return.
- **a call's argument list is met exactly.** `F` is below `G` when every argument list `G`
  is called with is one `F` accepts. `function()` is not `function(integer)`, since the call
  passes an argument `F` has no place for; a parameter `G` may omit is omittable (or met by a
  rest parameter) in `F`; a parameter `F` requires that `G` never passes is refused. *not
  adopted:* ignoring a surplus argument as Lua does.
- **return alternatives have equal length.** `function(): (A, B)` is not `function(): A`, and a
  list that ends in `T...` matches only one that ends in `U...` with `T <: U`. a narrowing
  declaration is met by one with the same parameter and kind. `asserts v is T` takes a
  narrower `T`. `v is T` takes only the same `T`, since the call has a false edge, where the
  checker removes `T` from the value: a function that tests for `KeyEvent` removes too little
  where one that tests for `Event` is wanted. *not adopted:* dropping surplus values, a fixed
  list below a tailed one, and `v is T` covariant in `T`.
- **a generic function type is below only itself.** an instance of it where a function type
  is wanted waits for generic inference, which owns instantiation. *not adopted:* matching type
  parameters in the relation.
- **an invariant position compares by `==`, with one exception.** `invalid` stands for a
  mistake already reported, so it is equal to every type at the top of an invariant position;
  deeper in one it is not.
- **a type variable is below itself and its bound** and unrelated to every other variable,
  whatever their bounds. the bound is read from the binders the caller has entered, so the
  result of a pair that mentions a variable is for those binders.
- **a map key is invariant in a view and in a `mut` map**, and `{T}` is unrelated to
  `{integer: T}`: an array is not a map.
- **only an interface is a target of a listing.** a type is below a named type of another
  declaration only if that is an interface its declaration lists, with its arguments put in
  through the declaration, or one the listed ones extend. a store refuses a declaration that lists
  itself, so the chain ends; the judge follows at most 4096 listings of one type, and [declarations are
  lowered strictly](#declarations-are-lowered-strictly) refuses a declaration with more. a listing
  whose arguments differ from the target's only by `invalid` is listed, where `invalid` is an
  argument itself and not a part of one. a listing, or an array part, that would nest past the
  store's depth is dropped, so a pair that holds by it is refused.
- **a declaration is read once it is defined.** the judge keeps what it has read of a
  declaration and the results that depended on it, so a type whose declaration has no body to
  read raises `relation: <declaration> is not defined`, and so do two uses of a declaration
  whose count of type arguments is not known with different counts.

### declarations are lowered strictly

[`lang/declarations.tl`] lowers a module's declarations and annotations, and holds each to [declarations](#declarations).
Where the rule above is silent, it takes the stricter reading, and a type that fails to lower is `invalid`, so a
mistake is reported once. *not adopted:* each reading's looser form, named here.

- **a tag is on every union written, not only an alias,** and applies to records: a class is told by its metatable,
  so a union of classes needs none. A union with one record, or with primitives, needs none. The tag is a fixed,
  required field of the same name in each record, typed by an enum of one value, and no two members have the same
  value (not the same enum: the value is what `x.kind == "..."` selects). *not adopted:* a tag on aliases only; a
  `mut` or omittable tag.
- **a key is** `integer`, `string`, `boolean`, an enum, or a declaration, and a union of those is not a key.
  `number` is `float_key`; `any`, `nil`, `true`, an optional, a union, a collection and a function are `key_type`.
- **an instance is checked where it is written.** A record, class, interface or alias records which of its type
  parameters are an element or value of a collection (dense) or a key, directly or by passing them on to another
  declaration; a use whose argument is optional, or no key, is refused. A variable of the code around stays unchecked until
  it is instantiated. *not adopted:* refusing `{T}` for a `T` that may be nil.
- **a declaration lists no declaration that lists it,** even through others, and [`Store.define`] raises for one; a
  closure of more than 4096 listings is `listing_too_large`, so the judge needs no limit on growth. The listing of an
  alias that names an interface is the interface.
- **agreement compares the interface's field, its receiver replaced,** with the field or method of the type, by `==`,
  and `mut` and `?` exactly. An interface that extends another may leave a field out or repeat it exactly. A generic
  function field has its receiver as written.
- **an alias does not see its own name,** so `type Node = Node` in a record names the `Node` around it; one that
  reaches itself through another is `alias_cycle`. An alias of a module not yet lowered is unavailable.
- **a declaration names only its own type parameters:** one in a function's body that names the function's is
  `outer_type_parameter`. A declaration that is not at the top of its module (in a body, or a repeated top-level name)
  is in the module `<name>@<id>` of its node.
- **a record's field is not a type member:** `Module: Module` in `importer` does not make [`importer.Module`] a type;
  declare a nested `type Module = ...` or a nested declaration. A file whose translation does not parse, and a
  `testdata` directory, are not held to these rules.
- **a function field of a userdata record that names the record first is a method of it.** A function-typed field of a
  declaration file may be repeated as an overload (fixed, not omittable) and no other name may.
- **`thread` is `thread_type`** until coroutines are typed; the bindings of C that the tree has no declaration file for
  ([`cosmic.sys`], [`cosmic.internal.process`], [`cosmic.internal.socket`]) are external, and a type named through one is
  `invalid` with no error.

### expressions read the rules strictly

[`lang/check.tl`] types a body by the rules of [checking](#checking) and, where they are silent or allow two
readings, takes the one that refuses more. *not adopted:* each reading's looser form, named here.

- **a form a later piece types is reported, not silent.** a binding of C, and a global the declarations lack, are
  `invalid` and an `unchecked_binding` error that a ceiling holds; the calls of generic functions, protected calls,
  coroutine functions and `match` the first expressions piece left so are typed by [generics, `match`, protected calls and
  coroutines](#generics-match-protected-calls-and-coroutines-read-the-rules-strictly). *not adopted:* `invalid` with no
  error.
- **a function literal takes from the position what its signature leaves out:** the types of its parameters, whether
  each may be omitted, and its return list (`never` too, so it cannot return). *not adopted:* a literal that returns
  nothing unless it says otherwise.
- **an overload skips a candidate whose parameter cannot take a literal's form** (a function literal for a `string`),
  and the literal is then checked against the one taken. *not adopted:* the first candidate whatever the literal.
- **an overload set is no value** (`overload_value`): only a call picks one. *not adopted:* the first overload.
- **a call with several return lists is no value to one name** (`local x = f()`), and gives each of several names the
  union of its column. *not adopted:* the first list.
- **a literal gives every field that is not `name?:`**, the `T?` ones too (`name = nil`); a class's literal gives
  its `?` fields as well ([classes read the rules strictly](#classes-read-the-rules-strictly)). *not adopted:* a
  literal that may omit a field that admits nil or a function.
- **a write to an array is the append, and nothing else** (`array_hole`), `t[#t] = nil` included. *not adopted:*
  any integer index.
- **a literal of named items with no type expected is a map `{string: V}`,** so `t.name` on it is `map_field`.
  *not adopted:* an anonymous record.
- **`x == "lit"` for an enum `x` is dead when the literal is no member** (`enum_member`), as `==` of two types that
  share no value is.
- **a record's array part follows the collection rule:** a view unless declared `mut`, and the grammar has no way to
  declare it so, so every write to it is `view_written`.
- **only a literal `nil` deletes a key of a map;** any other value written is of the map's value type.
- **an `if` expression whose arms have no common type** is accepted only where each arm is below the type the position
  wants, and `x or "lit"` for an enum `x` joins to `string`.
- **`...` read as one value is `T?`,** and an expression of `any` is neither stored (a field, an element, a
  return of another type) nor read: `any_use`.
- **a method called through a union is one function only where its members declare it alike:** the receiver, the member
  itself as a method has it, is replaced by the union, and the parameters, rest and return lists must then be equal; a
  member without the method is `field_unknown` and members that differ are `not_callable`, and both say to narrow first.
  *not adopted:* the call typed by the join of the returns or by the meet of the parameters, and a union of overloads.
- **`v is T` is `is_disjoint` where no type `v` can have is `T`:** some member of one has to be below some member of the
  other, as `==` asks, with `any`, `invalid` and a type variable overlapping everything. A test the rules already refuse
  (`is_on_record`, `class_scope`) is reported for that alone. *not adopted:* an always-false test that is accepted as
  dead code.
- **an expanding last argument fills the parameters after the values known:** each with `T?` (a missing value is
  `nil_not_allowed` where the parameter is not omittable) and the rest parameter with `T`. A value known past the
  parameters is a surplus argument whether or not a tail follows, since the tail may be empty and the value is certain.
  Literals before it are checked against the overload taken, which the tail is part of. *not adopted:* a tail that
  fills nothing it must, and the one more value a call with a tail was let pass.
- **a literal fits an overload by its form:** a function literal takes the arguments the function type is called with,
  every count from its required parameters to all of them and more with a rest parameter, since the relation meets a
  call's argument list exactly; a string literal is a `string` or an enum that has it. *not adopted:* the first candidate
  whatever the arguments the literal takes.
- **the standard library answers nil where Lua does:** `string.find` and `byte`, `tonumber`, `math.tointeger`,
  `table.remove`, `utf8.len` and `offset`, `next`, `rawget`, `getmetatable`, `load` and `loadfile`, the `io`, `os` and
  `debug` calls that fail (`os.execute` answers its three values every time), as `T?` on their first value in place of the fork's `T`, and the values after it `string?` and `integer?` where a success
  returns the first alone (`io.open`, `FILE:close`, `os.remove`, `utf8.len`, `load`), unlike the tree's own `T?, string` that
  its functions answer. The callbacks of
  `string.gsub` are enumerated by the number of captures they take (0 to 3) and answer `string | number | nil`, a nil
  keeping the match. The fork's file (`checker/stdlib.d.tl`) lets a result that may be nil be added and passed on, so the
  corrected declarations are the new checker's own, in [`lang/stdlib.d.tl`]. A capture is declared a `string` and a position capture `()` is an
  integer: a TODO until the checker reads patterns. `select` and `string.match` are unchanged: what they answer past
  the first value is a tail, which reads `T?` as one value. *not adopted:* alternatives (`(T) | (nil, string, integer)`) for the
  calls that fail, which every call would have to `match`.

### classes read the rules strictly

the class piece ([`lang/check.tl`], [`lang/declarations.tl`], [`lang/codegen.tl`] and the patched parser) takes the
reading that refuses more where [compiler-written classes, in the new checker] is silent. *not adopted:* each
reading's looser form, named here.

- **a class's literal names every field, the `?` ones as `name = nil`.** nothing can attach the metatable to a table
  built another way, and a field left absent would read through `__index`. *not adopted:* a class literal that
  leaves out a `?` field, as a record's may.
- **a class's table is the metatable of its values and a local of its module,** so a literal of a class and `is` of
  one are written where the class is declared (`class_scope`), and a class declared inside another type is not
  generated. the class of another module is made there, by a function of the class. *not adopted:* a class
  reached through `require` from another module (a TODO in [`lang/codegen.tl`]).
- **a method or function of a class named for a metamethod is refused** (`class_metamethod`), `__close` and
  `__tostring` included as functions, since the table of the methods is the metatable and `function C.__call()` would
  make a metamethod no rule saw. `__close` takes the value alone and `__tostring` answers a `string`
  (`metamethod_signature`). *not adopted:* the names with two underscores a class may use for other things.
- **`is` of a generic class is refused:** the metatable tells the class and not its arguments, so `v is Box<integer>`
  would narrow `Box<string>`. *not adopted:* the test with the arguments unchecked.
- **a `<close>` local holds nil or a class that declares `__close`** (`close_not_closable`). *not adopted:* an
  interface that declares one: a record may list it too, and its `__close` is a field no metatable holds. the
  rewrite that brings the ceiling to zero turns such a record into a class.
- **a method of an interface is called as `v:m(...)` and never read as a value** (`interface_method_value`): agreement
  gives the method the implementing type as its receiver, so `s.size` through a `Sized` is the one function of the
  value's own class, and `s.size(other)` would run that class's code on another implementer, because the implementation
  depends on the receiver. a class's own methods, read through the class or an instance, are one class's and stay
  readable. *not adopted:* the read typed with the interface as receiver.
- **a program has no `setmetatable`** (`setmetatable_call`): a call is reported where it stands and is a ceiling
  until the rewrite writes the class. *not adopted:* the call typed through the generics piece.
- **a declaration used as a value is a type of its own** (a [`Named`](../../lang/types.tl) with `value`, written `(val ...)`), below
  itself alone, and the functions `function R.m(...)` gave it are members of that type and of no instance
  (`declaration_value` for `local c: C = C`). *not adopted:* the statics as fields of the record.
- **the reserved form is two instructions of the patched parser,** `{ ... } @ C` (`OP_SETCLASS` after the
  constructor's fields) and `@v` (`OP_CLASSOF`, the metatable of a value, which `v is C` compares with `C`). the
  character is no token of Teal or of Lua, so only code the compiler writes holds it, and a chunk loaded from text
  reaches it until the runtime cut takes text `load` from programs. the instructions change the bytecode, so
  `LUAC_FORMAT` is 1 and every stored chunk of the old format fails at its header. *not adopted:* a hidden function
  of the core, which the generated chunk could reach only by a name.

### flow reads the rules strictly

[`lang/flow.tl`] and the walk of [`lang/check.tl`] take the reading of [narrowing and reachability](#narrowing-and-reachability)
that refuses more where it is silent. *not adopted:* each reading's looser form, named here.

- **an assignment narrows the place to the type of the value assigned, as the view of it, and an initializer does the same.** After
  `x = e` the value of `x` is the value of `e`, so `if x == nil then x = d end` leaves `x` a non-nil, and `local c: Color? = nil` leaves `c`
  nil. Two conditions, found by measuring it over the tree. The narrowed type is never `mut`: `mut` is a capability and no fact, and
  narrowing `local xs: {integer} = {}` to the literal's `mut {integer}` would let `xs[#xs + 1] = v` stand, defeating the view rule
  (`view_written` 6,109 to 555 and `array_hole` +845). And `unite` absorbs a member that is below another (`mut {T} | {T}` is
  `{T}`, a class and the interface it lists are the interface), so a join never carries a type its edges do not need. A value
  of `invalid` or `never` narrows nothing. An assignment of a value that is itself optional (`x, why = find()`) narrows nothing,
  so a test before it is dropped and the use is `narrowing_dropped`, naming the assignment. A closure made before the assignment
  reads no fact of the local ([`Capture.after`]). Measured over the tree: `nil_not_allowed` 5,351 to 4,938 and `narrowing_dropped` 77 to
  12, the rises being the next rule a nil hid (`unchecked_generic` +104; `any_use` +5, the `a[k]` of an `any` that `is table` found to be one; `field_unknown` +8, the fields the fork's records inherit from an interface, which the translation leaves out and `interface_disagrees` reports, read through the union an assignment narrowed to). *not adopted:* the
  first reading of this piece, that an assignment narrows nothing, which the review of the flow showed to be sound and needlessly
  strict.
- **`v is E` of an enum tests the values,** where `type(v) == "string"` (the fork's Lua) lets a string that is no member through: the
  Lua [`lang.codegen`] writes for the checker is `({["red"] = true, ...})[v] == true`, and `Check.enums` hands it the values. The kinds
  the checker took out stay the kinds, so a narrowed read of a `string` the test passed is held by the member check. The tree reads this
  ([`build/cache.tl`]). The `generated` oracle of [`build.tree_checks`] keeps the fork's kind test, since it compares with the fork's Lua.
- **`v is table` narrows to a table of unknown shape,** the kind test `type(v) == "table"`, and never to the standard library's record
  `table`, whose fields are its functions (`v.concat` of a `{string}` is not `table.concat`).
- **a narrowing declaration is proved of the argument and a parameter the body assigns cannot carry one.** `function f(v: string?): v is
  string` whose body assigns `v` is `narrows_unproved`: the declaration speaks of the value the caller passed, and the body's edges are
  about the value assigned. *not adopted:* proving it of the original value, which needs the facts of the parameter kept apart from
  the local it becomes.
- **a captured local that is assigned after the function is made is not narrowed inside it,** by a test inside the function either: the
  function may run after any assignment, so a test in it holds only for a local that is fixed from then on.
- **a local is assigned once by a statement:** `x, x = a, b` is `assign_repeated`, since Lua leaves the order open.
- **a loop is walked to a fixed point.** The head is where the entry and the back edge meet, so a fact the back edge loses is lost at
  the head, and a read of it before the assignment is refused; the passes that settle the head report nothing and skip the bodies of
  functions. *not adopted:* a head that keeps what the entry held and refuses the reads the back edge does not support.
- **a function names the locals it reads where it is made.** `local f: function()` with no value, read by a function made before `f`
  is assigned, is `not_assigned` whatever code runs between, so functions that call each other are the functions of a record. A local of
  type `any` with no value is unset (only `T?` admits nil). *not adopted:* the fork's walk of what runs between the function's
  creation and the first call that may run it.
- **a test no value can pass keeps what was known.** `x == nil` of a value that is never nil, `v is T` of a type `v` cannot have and a
  tag no member has are refused (`compare_disjoint`, `is_disjoint`, `enum_member`) and narrow nothing, so one mistake is one error.
  The edge that no value can take (the rest of a chain of tests that covered every member, `x ~= nil` of `nil`) is unreachable.
- **a place is a local or a path of fixed fields of a record, class or interface** read through the type the facts hold of what is
  before it. A field of a userdata record, of a union, of a type variable, a `mut` field, a global and an index are not places.
- **`==` of an enum with a literal narrows nothing,** since an enum is one type: a chain of such tests does not end a function, and
  the rewrite is a tag of a union of records or a `match`. A tag test narrows a union of records or classes by the enum of the field.
- **a statement after a jump is `unreachable`,** reported once for the run of them and checked from the facts at the jump; the
  declaration of a type is no code. A function declared `never` that can reach its end is `missing_return`, since a call of a binding
  of C that is not declared `never` ends no path ([`Proc.exit`] ends in [`sys.exit`], which [`cosmic.sys`] does not yet declare).
- **the narrowing a Teal body declares is proved where it returns.** A function declared `v is T` shows at each `return` that `v` is a
  `T` when the value is true and not when it is false, from the edges of that value; one declared `asserts v is T` shows it at each
  `return` and at its end (`narrows_unproved`). *not adopted:* a declaration taken on trust outside a declaration file.
- **`assert` narrows as a special case** of the global (not a local of that name): the first argument's true edge holds after the call.
  Its type is its declaration's ([generics, `match`, ...](#generics-match-protected-calls-and-coroutines-read-the-rules-strictly)).

### generics, `match`, protected calls and coroutines read the rules strictly

[`lang/check.tl`], [`lang/generics.tl`] and the declarations of [`lang/stdlib.d.tl`] take the reading of [calls and
overloads](#calls-and-overloads) and [`match` and tagged unions](#match-and-tagged-unions) that refuses more where they are
silent. *not adopted:* each reading's looser form, named here.

- **a type parameter is solved from the receiver and the arguments left to right, and the type the call is expected to
  answer comes last.** A position the argument flows into gives the parameter a lower bound, the join of the types found there (a
  type all are below, `T?` where one is `nil`, else `infer_conflict`); a parameter of a function argument gives an upper
  bound; a `mut` collection, the arguments of a generic and a map's key fix it exactly, and two exact types are one type or
  `infer_conflict`. A parameter is its exact type, else its lower bound, else its upper bound. The type expected fills a
  parameter nothing else fixed; it also picks the exact type an invariant position of the result requires when the arguments
  are below it (`local xs: mut {number} = wrap(1)`), and the type two arguments with no common type are both below
  (`local a: Animal = pick(dog, cat)`). `any` as the type expected says nothing. Nothing is solved from the body of a
  callee or across calls, so `local s: Server = must(Shape.into(v, SPEC))` is `cannot_infer` for the inner call. *not
  adopted:* unification across calls; the union of the types found, which `{1, "a"}` already refuses.
- **every argument is checked against the instance.** The solution is a guess the parameters are put through, so a wrong
  guess is an error of the argument and never a hole. A parameter that conflicts is `invalid` in the instance, so the
  conflict is the one error; a parameter whose pattern the argument does not fit (a view where a `mut` collection is
  wanted, a record where a map is) is left unsolved without `cannot_infer`, and the check of the argument reports the
  mistake once, with the parameter as the function declares it.
- **a literal is typed once the parameters its position names are solved.** A table, a string, a boolean, an `if`
  expression of them or a function literal that types every parameter stands in a position that names a parameter nothing
  else fixed: it is typed on its own, as it would be with no type expected, and its type solves the parameter. A function
  literal that leaves a parameter type out there has no type to be checked against, and the candidate is refused
  (`cannot_infer`; `overload_none` among overloads). A literal in a position whose parameters are solved is checked last
  against the instance, so `pick(1, "a")` is `not_assignable` at the literal and `pick(n, s)` is `infer_conflict`.
- **a bound is met by the type argument,** at a call (`bound_unmet`) and at a use of a generic declaration
  (`bound_not_met`): a type conforms to an interface only by listing it, and a type variable of the code around meets it
  through its own bound. A use whose argument names a variable of the code around is unchecked until it is instantiated.
- **a generic function is a value of a function type that is not generic** when its parameters can be taken from the type
  wanted: each from the parameter in its place, else from what the type answers, each meeting its bound
  ([`lang/relation.tl`]). A generic function type wanted is met only by itself. A callee whose function-typed parameter names a
  parameter only the result of a generic function argument fixes (`map(xs, identity)`) is `cannot_infer`.
- **an overload set is searched with the arity first.** A generic candidate is instantiated only if it takes the number of
  arguments, and a candidate that cannot be instantiated is listed with its reason in `overload_none`. A function literal fits an
  overload by the arguments it takes and by the number of values its return list writes. A generic function inside another is
  checked, with the variables of both in scope.
- **`assert` is two overloads and narrows as a special case.** `function<A>(A?): A` answers its argument without the nil, and
  `function<A, B>(A?, B, ...: any): (A, B, any...)` the message too. `asserts v is T` answers no value and narrows a place to a
  type, while `local s = assert(find())` and `assert(x ~= nil)` are the idiom of 945 and 1,455 sites, so the special case stays
  for what follows the call, until a narrowing declaration can say "returns only where the argument holds, and answers it".
  *not adopted:* `function<T>(v: T?, message?: string): asserts v is T`.
- **the standard library's mutators take `mut`, and numbers are numbers.** `table.insert`, `remove`, `sort` and `move`
  (whose source is a view when a destination is given) take `mut {A}`, and `rawset` `mut {K: V}`; `table.sort` writes its
  comparison as a function type, since `SortFunction<A>` named a generic function type applied to an argument. `math.abs` is
  an overload for integers and one for numbers, and `math.max` and `min` take one number and more, with no overload that takes
  anything. *not adopted:* `<N is Numeric>` over a union, which no bound is.
- **an arm of a `match` takes the lists its tests select, and the arms cover the lists exactly.** `true` and `false` at a
  position select the lists that have that value there; a name takes the union of what the lists it selects have at its
  position, `T?` for a position a tail gives. A list some earlier arm takes is not a later arm's. An arm that takes no list, or
  only lists taken before, is `match_redundant`; a list no arm takes is `match_missing`, with the arm that takes it. A test at a
  position a list does not have as `true` or `false` (`boolean`, an integer, nothing) selects nothing and is `match_pattern`,
  since the test could hold at run time for a list the arm was not typed for; so is an arm that names fewer or more values than
  the lists it takes have. A `match` on a call with one list takes it with one arm. *not adopted:* a name for the values left
  unnamed; an arm that tests a position the lists give as `boolean`.
- **return lists are told apart by `true` and `false`,** which the declaration checks (`lists_overlap`): two lists that no
  position has `true` in one and `false` in the other would be told apart by nothing. The grammar spells no tail among
  alternatives, so a function that answers `T...` is no argument of `pcall`.
- **`pcall` and `xpcall` are enumerated overloads** over the values passed on (0 to 6 for `pcall`, 0 to 3 for `xpcall`) and the
  values answered (0 to 3), each `(true, R...) | (false, any)`; for `xpcall` the failure is what its message handler answers or `string`:
  Lua answers `"error in error handling"` when the handler raises, so `H` alone would let `n + 1` through a handler that raises.
  The tree writes at most six extra arguments in all but a handful of sites, which are `overload_none`. The failure is untrusted
  data (`any`), and a column of the two lists is `any` for a name that takes both, so a `local ok, v = pcall(f)` is left with
  the `any_use` that `match` removes.
- **a union of shapes is solved member by member.** An argument `{integer} | {string}` for `{T}` gives `T` each member's
  element, so `T` is the type they join to (`{integer} | {number}` gives `number`) or `infer_conflict`; a parameter that
  is a union with a type parameter in each member (`{T} | {U}`) gets no type from an argument and is `cannot_infer`. A
  type parameter with no type is never left as `invalid` in silence. *not adopted:* an instance that is the union of the
  members' types, which would give `string` and `integer` to the same element.
- **`table.sort` without a comparator is declared for `integer`, `number` and `string`;** any other element type needs a
  comparator, because `<` raises on the rest. An instance that would make an array or a map of optionals
  (`wrap(m)` for `m: integer?`) is `array_of_optional`, as the annotation `mut {integer?}` is.
- **a coroutine is a `Coroutine<Y, R, S>` and yields through a handle.** `coroutine.create` and `wrap` take a body that gets a
  `Yielder<Y, S>` and the first value sent (or the handle alone, or nothing), and answer what it returns (`R`, or `nil` where it
  answers nothing); `resume` sends `S` (nothing where it is `nil`) and answers `(true, Y | R) | (false, any)`; `close` answers
  `(true) | (false, any)`; `status` an enum of the four states. The raw `running` and `yield` are not declared: no type says
  which coroutine a bare `yield` feeds. The declarations are the contract of the typed library: a handle yields only for the
  coroutine it was made for, which [`lang/check_programs.tl`] holds its Lua to, and the runtime provides with the typed
  library.
- **a tag test narrows as flow already reads it,** so tagged unions add no rule: `==` and `~=` of a field with one value an
  enum has in each member, in an `if` chain, a condition or an `elseif`; a chain that covers every member ends a function; a
  `mut` field, a global and an index are not places. A `match` tells lists apart and never records.

[a count the tree cannot yet bring to zero is a ceiling]: strict-teal.md#decisions
[annotated parameters]: strict-teal.md#annotated-parameters
[an index read may be nil]: strict-teal.md#an-index-read-may-be-nil
[arrays are dense]: strict-teal.md#arrays-are-dense
[collections are views unless declared mutable]: strict-teal.md#collections-are-views-unless-declared-mutable
[compiler-written classes, in the new checker]: strict-teal.md#compiler-written-classes-in-the-new-checker
[conditions are booleans or optionals]: strict-teal.md#conditions-are-booleans-or-optionals
[fields are fixed unless declared mutable]: strict-teal.md#fields-are-fixed-unless-declared-mutable
[generic bodies compare, pass and store]: strict-teal.md#generic-bodies-compare-pass-and-store
[honest `or` and `and`]: strict-teal.md#honest-or-and-and
[named receivers]: strict-teal.md#named-receivers
[narrowing by construction]: strict-teal.md#narrowing-by-construction
[narrowing only what nothing else can change]: strict-teal.md#narrowing-only-what-nothing-else-can-change
[never is the bottom type]: strict-teal.md#never-is-the-bottom-type
[nil is its own type]: strict-teal.md#nil-is-its-own-type
[no casts]: strict-teal.md#no-casts
[no implicit conversion or hidden code]: strict-teal.md#no-implicit-conversion-or-hidden-code
[numeric keys are integers]: strict-teal.md#numeric-keys-are-integers
[one variance per type constructor]: strict-teal.md#one-variance-per-type-constructor
[pcall and coroutines are typed]: strict-teal.md#pcall-and-coroutines-are-typed
[records are not maps]: strict-teal.md#records-are-not-maps
[strict-teal.md]: strict-teal.md
[tagged unions]: strict-teal.md#tagged-unions
[the new checker]: strict-teal.md#the-new-checker
[the switch]: strict-teal.md#the-switch
[the decisions]: #decisions
[the order the grammar lands in]: new-checker-grammar.md#the-order-the-grammar-lands-in
[varargs end in nil]: strict-teal.md#varargs-end-in-nil
[what the types leave out]: #what-the-types-leave-out

[`bin/perf`]: ../../bin/perf
[`build.tree_checks`]: ../../build/tree_checks.tl
[`build/alias_members.tl`]: ../../build/alias_members.tl
[`build/cache.tl`]: ../../build/cache.tl
[`build/ceilings.txt`]: ../../build/ceilings.txt
[`build/driver.tl`]: ../../build/driver.tl
[`build/error_catalog.tl`]: ../../build/error_catalog.tl
[`build/error_render.tl`]: ../../build/error_render.tl
[`build/removed_fix.tl`]: ../../build/removed_fix.tl
[`build/tree_checks.tl`]: ../../build/tree_checks.tl
[`Capture.after`]: ../../lang/scopes.tl
[`cosmic.internal.process`]: ../../core/process.h
[`cosmic.internal.socket`]: ../../core/socket.h
[`cosmic.poll`]: ../../cosmic/poll.tl
[`cosmic.removed`]: ../../cosmic/removed.tl
[`cosmic.shape`]: ../../cosmic/shape.tl
[`cosmic.sys`]: ../../core/syscalls.h
[`cosmic/removed_example.tl`]: ../../cosmic/removed_example.tl
[`Fs.read`]: ../../cosmic/fs.tl
[`importer.Module`]: ../../build/importer.tl
[`lang.codegen`]: ../../lang/codegen.tl
[`lang/ast.tl`]: ../../lang/ast.tl
[`lang/check.tl`]: ../../lang/check.tl
[`lang/check_codes.tl`]: ../../lang/check_codes.tl
[`lang/check_programs.tl`]: ../../lang/check_programs.tl
[`lang/codegen.tl`]: ../../lang/codegen.tl
[`lang/declarations.tl`]: ../../lang/declarations.tl
[`lang/flow.tl`]: ../../lang/flow.tl
[`lang/generics.tl`]: ../../lang/generics.tl
[`lang/prelude.d.tl`]: ../../lang/prelude.d.tl
[`lang/relation.tl`]: ../../lang/relation.tl
[`lang/relation_speed_test.tl`]: ../../lang/relation_speed_test.tl
[`lang/scopes.tl`]: ../../lang/scopes.tl
[`lang/scopes_speed_test.tl`]: ../../lang/scopes_speed_test.tl
[`lang/speed.tl`]: ../../lang/speed.tl
[`lang/stdlib.d.tl`]: ../../lang/stdlib.d.tl
[`lang/syntax_codes.tl`]: ../../lang/syntax_codes.tl
[`lang/translate.tl`]: ../../lang/translate.tl
[`lang/warnings.tl`]: ../../lang/warnings.tl
[`Proc.exit`]: ../../cosmic/proc.tl
[`Scoped.resolved`]: ../../lang/scopes.tl
[`Scopes.declared`]: ../../lang/scopes.tl
[`Store.define`]: ../../lang/types.tl
[`sys.exit`]: ../../core/syscalls.h
[`Var.assigned`]: ../../lang/scopes.tl
[`Var.captures`]: ../../lang/scopes.tl
[`Var.copies`]: ../../lang/scopes.tl
[`Var.id`]: ../../lang/scopes.tl
