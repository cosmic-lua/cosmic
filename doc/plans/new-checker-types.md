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
  library's in [`checker/stdlib.d.tl`], the tree's bindings in
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
never unfolds a body, so a recursive record cannot loop the relation and the
relation needs no assumption set (the fork counts open comparisons for it).
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

one relation, `T <: U`, in the rules below. it never unfolds a declaration,
so it ends by recursion on the structure of anonymous types, which is
finite. each result is cached per pair in the store.

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
[`checker/facts.tl`] knows no type beyond identity (it takes `unite`, `is_a`
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
- **an assignment** drops the place and every path from it. nothing else does:
  a call, a closure, an alias or an operator cannot change a place.
- **definite assignment** is a state in the same map. `local x: T` with no
  value puts `x` in as *unset*; a read of an unset place is `not_assigned`; a
  join keeps it assigned only if both edges assign it; a function literal
  reads each outer variable it names where it is made.
- **loops** are walked once under the head's facts minus what the loop
  assigns, as [strict-teal-narrowing.md] has it.

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
`array_of_optional`, `view_as_mut`, `is_on_record`, `match_redundant`,
`lists_overlap`, `interface_disagrees`, `literal_missing`, `literal_unknown`,
`literal_needs_type`, `literal_ambiguous`, `literal_shape`, `arms_differ`,
`overload_none`, `arity`, `cannot_infer`, `infer_conflict`, `missing_return`,
`return_unexpected`, `not_assigned`, `export_not_declared`, `unreachable`, and
`narrowing_dropped`, kept from the fork. each has a fix pinned by its test.

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

## the order the pieces land in

each is a PR with its tests and a check in [`build/tree_checks.tl`], beside
`lexed` and `scoped`, that checks the translated tree and counts errors per
code, pinned by file and code. a rule's ceiling is its codes' count; it only
falls ([a count the tree cannot yet bring to zero is a ceiling]) and a rewrite
lowers it. every error has a code, a fix and a catalogue row from the PR that
adds it. the translator ([`lang/translate.tl`]), the scope builder and the
speed harness exist already.

- **the store.** forms, interning, union normal form, display. property
  tests: interning is idempotent, a union does not depend on member order, an
  encoded type decodes to the same type in a second store.
- **the relation.** every rule above, with the refused programs of the plan
  (the pinned holes of [`build/teal_test.tl`], translated). property tests:
  reflexive, transitive, `never` below everything, only `nil` and optionals
  admit nil, a `mut` collection is invariant.
- **declarations.** lowering of every declaration and annotation with its
  checks (agreement, tags, keys, dense arrays); the tree check lowers every
  declaration of the tree and pins what fails.
- **rows.** encoding, Merkle hashes, interface hashes, decoding. a test checks
  a module in a second process from rows alone and compares every verdict.
- **expressions without flow.** operators, calls, overloads, literals, fields,
  writes, returns. the ceilings for nil, indexes, views, mutable fields,
  records as maps, conditions, `or`/`and`, concatenation and numeric keys
  start here.
- **flow.** facts, narrowing, definite assignment, reachability, with the fuzz
  and checked narrowing of [strict-teal-narrowing.md] run against it.
- **generics, then `match`, tagged unions, protected calls and coroutines.**
  `table.insert`, `ipairs`, `assert`, `pcall` and `Coroutine` lose their
  special cases to declarations.
- **incremental.** the trace, the worker split that replaces
  [`build/shards.tl`], and the speed workloads.

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

[a count the tree cannot yet bring to zero is a ceiling]: strict-teal.md#decisions
[annotated parameters]: strict-teal.md#annotated-parameters
[an index read may be nil]: strict-teal.md#an-index-read-may-be-nil
[arrays are dense]: strict-teal.md#arrays-are-dense
[collections are views unless declared mutable]: strict-teal.md#collections-are-views-unless-declared-mutable
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
[strict-teal-narrowing.md]: strict-teal-narrowing.md
[strict-teal.md]: strict-teal.md
[tagged unions]: strict-teal.md#tagged-unions
[the new checker]: strict-teal.md#the-new-checker
[the decisions]: #decisions
[varargs end in nil]: strict-teal.md#varargs-end-in-nil
[what the types leave out]: #what-the-types-leave-out

[`bin/perf`]: ../../bin/perf
[`build/alias_members.tl`]: ../../build/alias_members.tl
[`build/shards.tl`]: ../../build/shards.tl
[`build/teal_test.tl`]: ../../build/teal_test.tl
[`build/tree_checks.tl`]: ../../build/tree_checks.tl
[`Capture.after`]: ../../lang/scopes.tl
[`checker/facts.tl`]: ../../checker/facts.tl
[`checker/stdlib.d.tl`]: ../../checker/stdlib.d.tl
[`cosmic.poll`]: ../../cosmic/poll.tl
[`cosmic.shape`]: ../../cosmic/shape.tl
[`cosmic.sys`]: ../../core/syscalls.h
[`cosmic/removed_example.tl`]: ../../cosmic/removed_example.tl
[`Fs.read`]: ../../cosmic/fs.tl
[`lang/ast.tl`]: ../../lang/ast.tl
[`lang/scopes.tl`]: ../../lang/scopes.tl
[`lang/scopes_speed_test.tl`]: ../../lang/scopes_speed_test.tl
[`lang/speed.tl`]: ../../lang/speed.tl
[`lang/translate.tl`]: ../../lang/translate.tl
[`Scoped.resolved`]: ../../lang/scopes.tl
[`Scopes.declared`]: ../../lang/scopes.tl
[`Var.assigned`]: ../../lang/scopes.tl
[`Var.captures`]: ../../lang/scopes.tl
[`Var.copies`]: ../../lang/scopes.tl
[`Var.id`]: ../../lang/scopes.tl
