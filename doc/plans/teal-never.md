# a bottom return type for Teal

this document describes `: never`, a return list that says a function does
not return, as a series of records under `patch/tl/` (`40a1` through `41b`).
the series is built; what is not (the declarations of [`Proc.exit`] and
[`sys.exit`], `refuse`, the generator and the dummy returns they let go) is
listed under "declarations". line numbers are those of [`vendor/tl/tl.tl`]
(Teal 0.24.8, unpatched).

## the problem

Teal cannot say "this function never returns", so a helper that only
raises narrows nothing. declared `: never`, a helper does:

```teal
local function fail(m: string): never
  error(m)
end

local function f(x: string | nil): integer
  if x == nil then fail("no") end
  return x:len()
end

print(f("a"))
```

declared without `: never`, `fail` returns as far as the checker knows, and
`x:len()` is refused: 'x' may be nil. with `error("no")` in place of
`fail("no")` it compiles, because
[`patch/tl/25-error-ends-a-block.txt`] marks a call to the standard `error`
as ending its block. the helper shape is common (`spec_error` in
[`cosmic/net.tl`] and [`cosmic/http/server.tl`], `fail` in [`build/flow.tl`]),
and [`Proc.exit`] has the same problem: it wraps [`sys.exit`], and code after
`if bad then Proc.exit(2) end` does not see `bad` handled.

the narrowing matters only for an index, a method call or a call of the
value: this compiler accepts `#x` and `local y: string = x` for a `string |
nil` as they are.

## syntax

`never` is accepted only as the whole of an unparenthesized return list, in
the places that call `parse_return_types` (2890): a function type, a
function or method declaration, and a `macroexp`. the word is the flag
only when the token after it cannot continue a type (not `.`, `<`, `|` or
`...`); otherwise it is read as a name, so `: never.x` still parses as a
nominal type. a `,` after it ends the return list where patch 30 ends one,
before the next parameter of an enclosing function type
(`function(f: function(): never, x: integer)`); any other `,`
(`: never, string`) is refused, since `never` is the whole list.

```teal
local record Guard
  die: function(self: Guard, why: string): never
end

local function fail(m: string): never
  error(m)
end

print(fail)
```

`never` is not reserved as a word: elsewhere (`(never)`, `never, string`,
`{never}`, a parameter) it is an ordinary name, and the checker reports an
unknown type. the parenthesized form goes through `parse_type_list` (3046)
as a list and is therefore refused. no type named `never` exists in the
tree (`grep -w never` finds only prose). a program that declared one would
see `: never` silently mean "does not return", with an empty `rets`, so 40c
also refuses the declaration of a type by that name, anywhere (`local` or
`global` `type`, `record`, `interface`, `enum`, the same nested in a record,
and a type argument), with a message naming the return list.

the representation is a flag, not a type: `FunctionType` (1992) gains
`never: boolean`, and the parser gives the function an empty `rets` tuple,
as for a function that declares no returns. emitted Lua is unchanged, since
it never mentions return types. `parse_return_types` answers the flag as a
third value; a `,` after `never` that no parameter follows is a syntax
error (`'never' is the whole return list`), and the list is then read as
types, so the parse goes on.

every site that builds a function type from a node must carry the flag,
or the type disagrees with the declaration. in `a_function` calls: the
recursion pre-declaration `add_function_definition_for_recursion` (10878),
the local, global and record function declarations (13473, 13547, 13624),
the literal (13725) and the `macroexp` (13750), whose type a record field
`f: function(): never = macroexp(): never ... end` is compared with. a
`local macroexp` needs no flag on its type: a call of it is replaced by its
expression. the pre-declaration matters
because `local function spin(): never spin() end` sees that type, not the
final one, inside its body. `map_type`'s
`resolve` (8182; its function branch, 8262, copies each field by hand)
must copy it, and `show_type_base` (7225) print it; otherwise a
never-function is forgotten after one generic instantiation.

## the call site

patch 25 sets `node.block_returns` on a call spelled `error` whose name is
the global or a `<const>` local. the general rule lives in
`type_check_function_call` (10542), not in the `@funcall` visitor:
`type_check_funcall` (12268) returns `(self:type_check_function_call(...))`,
which drops the resolved callee, so the visitor never sees it. inside, once
`f` is resolved, `f.never` and `node_is_funcall(node)` (2460; the guard
leaves a `for ... in` iterator that reaches this function at 13108 unmarked
unless the iterator expression is itself a call, which is no statement and
so harmless) set `block_returns` on
`node`. for an overloaded callee `f` is the overload `check_poly_call`
picked, so the flag is per overload. a method call resolves to a never `f`
and ends a block too. a call dispatched through a `__call` metamethod ends
none (40f2): the metamethod's function is attached at run time and checked
against nothing, so a record may declare a never `__call` and be given a
metatable whose function returns. only an operator metamethod (10659)
reaches the function with a node that is no statement, and the guard leaves
it alone.

`pcall(fail, x)` does not end a block: `special_pcall_xpcall` (11594)
checks the inner call on a synthetic `@funcall` node, so the flag lands
there, and the real `pcall` call has the type `boolean, any...`.

### what replaces 25's rule

25 trusts a call only when it is spelled `error` and `error` is scope 1 or
a `<const>` local, because a name is not a type: a variable holding the
function could be assigned another function later. with the flag on the
type, the guarantee is checked where the variable is written:

- `local f = error` gives `f` the type of `error`, flag included. `f =
  print` is then a function that may return assigned to a never-function,
  which the subtype rule refuses. today it is accepted, which is why 25
  needs the scope test.
- `error = print` on the global is refused as an assignment to a `<const>`
  (the standard library's globals are), so the tests assign `print` to a
  `local f = error` instead.
- passing a never-function where `function(): T` is expected loses the
  flag, the safe direction.

so 25's scope test goes and `local error = error` narrows. in
[`test/narrowing_test.tl`], `test_error_narrows_below_the_guard` and
`test_a_local_error_does_not_narrow` (a local `error` of another type)
pass unchanged. `test_a_reassignable_local_error_does_not_narrow` is
inverted into `test_a_local_holding_error_narrows`, and
`test_a_local_holding_error_cannot_be_given_a_function_that_returns` shows
that assigning such a local a function that may return is refused.

41 cannot delete 24a, 24b and 25. 36a's find text contains 24a's `"error"`
enum entry and 36c's contains 24b's `set_special_function` line, and
`special_functions` is `<total>`, so a registered name needs a handler.
41 therefore keeps 24a and 24b and rewrites only 25's handler to a plain
`type_check_function_call`, without the scope test. `error` stays a
registered special function with no behavior of its own. dropping the
registration means rewriting 36a and 36c; that is a later cleanup, not part
of this series.

the series accepts one hole, the first entry; the others say what is closed and what stays as it is:

- an `as` cast returns its target type unchecked (13867), and so does `is`
  on an `any`. any target that contains a never-function forges the
  guarantee, not only `print as function(): never`: a record whose field is
  one (`q as P`, with `P.die` never and `Q.die` returning) or a container of
  one. the cast policy in [`doc/roadmap.md`], which covers `as` and `is`,
  closes it; until then `test_as_and_is_forge_a_never_function` in
  [`build/teal_test.tl`] pins the accepting behavior.
- `never` survives only where a declaration writes it, never through a type
  variable (40e7): a type variable bound to a never-function is bound to
  the function type without the flag, because a generic declared
  `function<F>(F): F` is right for a function that answers its argument and
  wrong for one that does not (`coroutine.wrap`, whose result returns to its
  caller whenever the coroutine yields), and the checker cannot tell them
  apart. every way to reach `coroutine.wrap` is closed by it: a direct call,
  a generic that applies it (`ap(coroutine.wrap, nv)`), a record field or
  parameter that holds it, `id(coroutine.wrap)(nv)`, and a signature that
  gives it a never result, `function(function(): never): function(): never`,
  which the comparison refuses (the bivariant fallback of a parameter or
  return does not cross a never disagreement, 40e8). the cost is that a
  generic over a never-function loses `never`: `id(fail)` does not narrow,
  and `pcall(fail, x)` never did.
- `coroutine.create`, `resume`, `pcall` and `xpcall` take a function and
  answer values that no call can mistake for it; `table.sort` and the
  string functions take callbacks and answer none. `setmetatable` answers
  the type of its table, which is sound now that a call through `__call`
  ends no block.
- a call through `any` carries no flag, and a declaration that says `never`
  and returns is a bug in the declaration.

## subtyping

`subtype_relations["function"]["function"]` (9853) serves assignment and
argument passing. it refuses `#ar < #br` ("incompatible number of
returns"), so a never-function, with no returns, cannot today be given
where `function(): string` is expected. the rule:

- `a.never`, not `b.never`: skip the return check. a never-function is a
  subtype of every `function(...): T`, including `pcall`'s parameter.
- `b.never`, not `a.never`: an error. without it, `local f: function():
  never = print` makes `f("x")` end a block that `print` returns from.
- both: arguments compare as before.
- a poly value (an overloaded function) given where a never-function is
  expected: `subtype_relations["poly"]["*"]` (9942) asked for `b <: t` of
  some overload `t`, the reverse of what its comment says, which accepted
  a poly with an overload that returns, and any function an overload
  accepts. 40e6 asks for `t <: b` of some overload, as the comment says
  (the tree compiles and its tests pass with it), and 40e4 asks for every
  overload to be never first. the other poly row (`a <: poly`, all
  overloads) needs nothing: each overload is compared with the function
  rule.

this must hold at the root of a comparison only. Teal compares nested
types with `is_a` in whichever direction passes: `arg_check` is
`"bivariant"` for the parameters and returns of two function types (8993,
9860, 9871) and falls back to `is_a(b, a)`, and arrays, maps, records and
unions compare their elements covariantly through `is_a` (`subtype_array`
9224, `compare_map` 9310, the union rows 9615-9640, the nominal and alias
rows); none uses `same_type`. so `{function(): never}` is an `is_a` of
`{function(): string}`, and `local h: function(): {function(): never} =
function(): {function(): string} ... end` would pass, and `h()[1]()` would
end a block that returns. refusing only the bivariant fallback is not
enough: the forward direction forges too, since a function whose parameter
is a never-function, assigned where a `function(cb: function(): string)` is
expected, is called with a callback that returns.

the rule, chosen over making `arg_check` non-bivariant for such pairs
(which would also change how every ordinary pair compares): the outermost
`is_a` or `same_type` (40e5; a depth counter, `compare_depth`, tells it
from the comparisons its relations make) walks the two types in step,
through names already resolved, aliases, generics' bodies, function
parameters and returns, tuple entries, array elements, map keys and
values, record fields and metafields, union members and the type
arguments of a name, with a seen-set for recursive records. a pair of
function types that disagrees on `never` anywhere but the root pair is an
error, in either direction. the root pair is the comparison's own to
judge, and names and unions at the root keep their members at the root,
so `local g: nil | function(): integer = fail` is fine. an overloaded
function counts as a never-function when every overload is. the walk
is cheap where a type has no structure (it returns at once, and the
wrapper skips two types that both have none), and it is not memoized: types change while they are checked (a record
gains a function field), so a negative answer kept per type could go
stale and let a forged pair through. a name not resolved when the walk
reaches it is not looked into, since resolving it there could report an
error the comparison reports itself or settle it for the wrong scope. the
compatibility cost is that never-ness must agree under every nested comparison, so
`{function(): never}` no longer converts to `{function()}` and
`function(): {function(): never}` no longer converts to `function():
{function(): string}`, though both are sound for a value never written
through. a table literal checked against its declared type is not
affected, since each of its items is checked against the field's type
directly.

`eqtype_relations["function"]["function"]` (9535) is reached only through
`same_type`: generic type arguments, invariant `arg_check`, and the record
field check. it treats `a.never ~= b.never` as a mismatch before it counts
returns. a record function is checked against its field with `same_type`
(13648), so `function Guard.die(...): never` is refused if the field `die`
is declared without `: never`: the declaration must say it. the `typeid`
shortcut in `compare_types` is safe: ids are per allocated type, not per
shape.

one use shows the rule biting. [`build/invoke.tl`] replaces [`sys.exit`] in a
test seam with `function(_?: integer) refuse("sys.exit") end`. once
[`sys.exit`] is `never`, that literal must be one. 37d and 37f give a literal
that omits its return list the returns of its context; 40h makes that
include the flag. its body ends in `refuse(...)`, so `refuse` must be
declared `: never`. the `execve` and `attach` stubs below it keep a dummy `return` after
`refuse(...)`; Teal accepts a declared-returns function that falls through,
so they compile either way.

## defining a never-function

a function declared `never`:

- contains no `return`, not even a bare one. the function visitor sets
  `@return` (10865) and the `return` visitor reads it with `find_var_type`
  (13183), which walks outward. every function therefore sets its own
  `@never`, true or false, so that a closure inside a never-function checks
  its own `return`s against its own declaration.
- must not reach its end: its last statement must have `block_returns`, the
  test 37f applies to a literal whose context expects values (now the
  local function `body_ends`, which `end_function_scope` applies to every
  declaration, and the `function` visitor to a literal). 21 through 25,
  39a through 39d and the call rule put that flag on a statement, so a body
  may end in a never-call, a `while true` with no `break`, a `do` that
  ends, or an `if` with an `else` whose every block ends. an `if` without
  an `else` does not count (21), nor does `assert(false)` (decision 3).

37f checks only `required > 0`, and only for a literal with a context. 40g4
moves the end test into `body_ends`, and 40h4 calls it also for a literal
whose context is a never-function (required is 0 there).
a macroexp's body is one expression, so a macroexp declared `never` must
be a call that never returns (its `exp.block_returns`): the call of the
macroexp is replaced by that expression, which then ends the block. a
`local macroexp` is checked on its `local_macroexp` node, whose children
are the definition's parts. a
recursive call counts, once the pre-declaration carries the flag (above):
`local function spin(): never spin() end` is accepted, and does not return.

the declaration is the contract: nothing infers `never` for an undeclared
helper, since a function's type would then change with an edit to its last
line, and callers in another module would need the body.

## what stays as it is

`return fail(x)` is accepted in any function already: the `return`
visitor's loop (13222) runs `for i = 1, n_got`, and a never-call gives no
values, so nothing is checked, as with `return print()` today. `local x =
fail()` is refused today for any function with no returns (`assignment in
declaration did not produce an initial value`) and stays so. emitted Lua is
unchanged.

## declarations

- stdlib `error` (442): `function(? any, ? integer): never` (41a). `os.exit`
  (320) stays undeclared: [`cosmic/removed.tl`] bans it, and the checker
  withholds `os` from the tree's code.

what is left, for a change of its own after this series lands:

- [`Proc.exit`] ([`cosmic/proc.tl`], 73): `(status: integer): never`; its body
  `sys.exit(status)` is then a never-call that ends it.
- `sys.exit`: [`core/syscalls.h`] declares it with no `@return`, which
  [`build/gen_syscalls.tl`] already reads as "never returns (0)". `signature`
  writes `: never` for zero results instead of no list. `exit` is the only
  binding without `@return` in `syscalls.h`, `process.h` and `socket.h`.
- `refuse` in [`build/invoke.tl`] declared `: never`, and the dummy `return`s
  after calls of the helpers above removed.
- deleting this plan.

## patch list

continuing after `39d`, each a record in `patch/tl/` with a `note:`. a
record holds one find and one replace, so the series is split into one
record per edit, a digit after the group's letter (the names sort in the
order they apply):

```text
40a1  FunctionType.never
40a2  Node.never
40b1  starts_parameter, the test of 30 as a function
40b2  parse_trying_list uses it
40b3  parse_return_types reads `: never`, answers the flag
40b4  a function type takes it        40b5  a declaration takes it
40b6  a macroexp takes it
40c1  refuse_type_named_never, and a typearg named never
40c2  local/global type               40c3  local/global record, interface, enum
40c4  a type nested in a record
40d1  the recursion pre-declaration   40d2  local function
40d4  global function
40d5  record function and method      40d6  function literal
40d7  macroexp (its type is compared with the declared one)
40d8  map_type's copy
40d9  show_type prints `: never`
40e1  TypeChecker.compare_depth
40e2  subtype row: a.never skips the returns, b.never alone is an error
40e3  eqtype row: both or neither
40e4  the poly row: every overload never
40e5  never_mismatch, the outermost walk, is_a and same_type wrapped
40e6  the poly row asks for an overload below b, not b below an overload
40e7  a type variable bound to a never-function drops the flag
40e8  the bivariant fallback does not cross a never disagreement
40f1  the call rule in type_check_function_call
40f2  a call through `__call` is not a never call
40g1  @never in every function's scope
40g2  a `return` in a never-function is an error
40g3  body_ends, and end_function_scope refuses a reachable end
40g4  37f's test calls body_ends
40h1  Node.context_never              40h2  the literal reads it from its context
40h3  @never for such a literal       40h4  its end test
40h5  its type carries the flag
41a   stdlib error: never
41b   25's handler only forwards
```

until 41a lands `error` is not declared `never`, so 25 alone handles it.
the records from 40f1 on need nothing before them but the flag (40a through
40d); 40e5 needs 40e1.

tests, in [`test/narrowing_test.tl`]'s style (a one-file project compiled
with [`build.importer`]) for what narrows, and [`build/teal_test.tl`]'s
(`built.gen` on a string) for what parses and what is refused:

- 40b, 40c: `test_never_is_a_return_list`,
  `test_never_is_only_the_whole_return_list`,
  `test_never_followed_by_a_dot_or_arguments_is_a_name` and
  `test_no_type_is_named_never`.
- 40e: `test_a_never_function_is_a_subtype_of_any_function`,
  `test_a_record_function_agrees_with_its_field_on_never`,
  `test_a_poly_function_is_never_only_when_every_overload_is`,
  `test_never_agrees_when_nested` (six kinds, in a parameter and in a
  return, both directions refused, and the agreeing pairs compiled),
  `test_never_agrees_in_a_callback_parameter` and
  `test_as_and_is_forge_a_never_function`.
- 40f: `test_a_never_function_narrows_below_its_guard` (a local function,
  a record field, a method, a generic, a recursive one, a poly overload and
  a macroexp) and
  `test_what_does_not_end_a_block_keeps_its_guard_open` (a function that may
  return, the overload that returns, an inner `if`, `pcall`, a `for`
  iterator, an operator metamethod, a `__call`, a generic over a
  never-function, and `coroutine.wrap` reached by a call, a generic, a
  field, a parameter, `id` and a constant).
- 40g, 40h: `test_a_never_function_neither_returns_nor_reaches_its_end`,
  `test_a_literal_takes_never_from_its_context` and
  `test_a_never_macroexp_is_a_never_call`,
  `test_a_never_macroexp_field_is_a_never_call`.
- 40e7, 40e8: `test_a_wrapped_never_function_may_return` (a call, and each
  signature, field and parameter that asks for a never result) and
  `test_a_generic_over_a_never_function_loses_never`.
- 41: `test_error_is_a_never_function`; in [`test/narrowing_test.tl`] the first
  two tests of 25 pass unchanged and the third is inverted (above).
- generator ([`build/gen_syscalls_test.tl`]), with the follow-up: a block
  with no `@return` writes `: never`; one with a return does not.

## open edges

generics work once `resolve` copies the flag, which lives on the inner
`FunctionType`. an `unknown` callee in lax mode (`.lua` files) carries no
flag, and a lax-mode function type gets its empty `rets` as `unknown...`
(`get_rets`), which the flag makes no difference to.

## cost, unlocks, alternatives

the cost is a rebase against the 21 through 39 records, which edit the same
parts of tl.tl; 40c touches seven sites, 40d adds three rules, and there is
no runtime or C change. it unlocks narrowing through `spec_error`, `fail`
and [`Proc.exit`], one raising helper per module instead of `error(...)`
inlined at each guard, and a `main` that ends in `Proc.exit(code)` with no
dummy `return`.

alternatives: the status quo (inline `error(...)`, or an unreachable
`return` after the helper, both in the tree now); extending 25's name list
to [`Proc.exit`], which needs a `SpecialFunctionName` entry, a scope test for
the reassignment hole and a patch per name, and leaves a project's own
`fail` uncovered; a full bottom type (`local x: never`, `T | never`), which
nothing here needs and which reaches every table in the checker; inferring
`never` from a body, rejected above.

## choices

the questions the design left open, and how they are settled:

1. a flag on the function type is enough; no bottom type.
2. `os.exit` stays undeclared (the checker withholds `os`).
3. `assert(false, msg)` does not end a block, and has no handler.
4. a better message for `local x = fail()` comes later, as a
   [`teal.replacement`] hint, not in this series.
5. declaring a type named `never` is refused (40c).
6. the `is` hole is accepted, pinned by a test, and listed in
   [`doc/roadmap.md`]'s cast-policy entry.
7. a poly value is accepted where a never-function is expected only when
   every overload is never (40e4).
8. never-ness must agree under every nested comparison (40e5), refusing even
   the sound `{function(): never}` for `{function()}`.

[`build.importer`]: ../../build/importer.tl
[`build/flow.tl`]: ../../build/flow.tl
[`build/gen_syscalls.tl`]: ../../build/gen_syscalls.tl
[`build/gen_syscalls_test.tl`]: ../../build/gen_syscalls_test.tl
[`build/invoke.tl`]: ../../build/invoke.tl
[`build/teal_test.tl`]: ../../build/teal_test.tl
[`core/syscalls.h`]: ../../core/syscalls.h
[`cosmic/http/server.tl`]: ../../cosmic/http/server.tl
[`cosmic/net.tl`]: ../../cosmic/net.tl
[`cosmic/proc.tl`]: ../../cosmic/proc.tl
[`cosmic/removed.tl`]: ../../cosmic/removed.tl
[`doc/roadmap.md`]: ../roadmap.md
[`patch/tl/25-error-ends-a-block.txt`]: ../../patch/tl/25-error-ends-a-block.txt
[`Proc.exit`]: ../../cosmic/proc.tl
[`sys.exit`]: ../../core/syscalls.h
[`teal.replacement`]: ../../build/teal.tl
[`test/narrowing_test.tl`]: ../../test/narrowing_test.tl
[`vendor/tl/tl.tl`]: ../../vendor/tl/tl.tl
