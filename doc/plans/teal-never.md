# a bottom return type for Teal

this document proposes `: never`, a return list that says a function does
not return, as a series of records under `patch/tl/`. nothing here is
built. every claim was checked against [`vendor/tl/tl.tl`] (Teal 0.24.8,
unpatched; line numbers are its) and the records `patch/tl/21` through
`39d`.

## the problem

Teal cannot say "this function never returns", so a helper that only
raises narrows nothing. the example is refused today and is accepted once
the series lands:

```teal skip=intended
local function fail(m: string) error(m) end

local function f(x: string | nil): integer
  if x == nil then fail("no") end
  return x:len() -- refused: 'x' may be nil
end
```

with `error("no")` in place of `fail("no")` it compiles, because
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
function or method declaration, and a `macroexp`.

```teal skip=intended
local function fail(m: string): never
  error(m)
end

local record Guard
  die: function(self: Guard, why: string): never
end
```

`never` is not reserved as a word: elsewhere (`(never)`, `never, string`,
`{never}`, a parameter) it is an ordinary name, and the checker reports an
unknown type. the parenthesized form goes through `parse_type_list` (3046)
as a list and is therefore refused. no type named `never` exists in the
tree (`grep -w never` finds only prose). a program that declared one would
see `: never` silently mean "does not return", with an empty `rets`, so 40b
also refuses the declaration of a type by that name, anywhere, with a
message naming the bottom type.

the representation is a flag, not a type: `FunctionType` (1992) gains
`never: boolean`, and the parser gives the function an empty `rets` tuple,
as for a function that declares no returns. emitted Lua is unchanged, since
it never mentions return types.

every site that builds a function type from a node must carry the flag,
or the type disagrees with the declaration. in `a_function` calls: the
recursion pre-declaration `add_function_definition_for_recursion` (10878),
the local, global and record function declarations (13473, 13501, 13547,
13624), the literal (13725) and the `macroexp` (13750). the pre-declaration matters
because `local function spin(): never spin() end` sees that type, not the
final one, inside its body. `map_type`'s `resolve` (8182; its function branch, 8262,
copies each field by hand) must copy it, and `show_type_base` (7225) print
it; otherwise a never-function is forgotten after one generic
instantiation.

## the call site

patch 25 sets `node.block_returns` on a call spelled `error` whose name is
the global or a `<const>` local. the general rule lives in
`type_check_function_call` (10542), not in the `@funcall` visitor:
`type_check_funcall` (12267) returns `(self:type_check_function_call(...))`,
which drops the resolved callee, so the visitor never sees it. inside, once
`f` is resolved, `f.never` and `node_is_funcall(node)` (2460; the guard
also keeps a non-operator node, such as the `for ... in` iterator that
reaches this function at 13108, from being marked) set `block_returns` on
`node`. for an overloaded callee `f` is the overload `check_poly_call`
picked, so the flag is per overload. a method call, and a call of a record
with a never `__call`, resolve to a never `f` and end a block too. only an
operator metamethod (10659) reaches the function with a node that is no
statement, and the guard leaves it alone.

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
- `error = print` on the global is refused the same way.
- passing a never-function where `function(): T` is expected loses the
  flag, the safe direction.

so 25's scope test goes and `local error = error` narrows. in
[`test/narrowing_test.tl`], `test_error_narrows_below_the_guard` and
`test_a_local_error_does_not_narrow` (a local `error` of another type)
pass unchanged. `test_a_reassignable_local_error_does_not_narrow` (692) is
inverted: `local error = error` now narrows, and a new case shows that
assigning it a function that may return is refused.

41 cannot delete 24a, 24b and 25. 36a's find text contains 24a's `"error"`
enum entry and 36c's contains 24b's `set_special_function` line, and
`special_functions` is `<total>`, so a registered name needs a handler.
41 therefore keeps 24a and 24b and rewrites only 25's handler to a plain
`type_check_function_call`, without the scope test. `error` stays a
registered special function with no behavior of its own. dropping the
registration means rewriting 36a and 36c; that is a later cleanup, not part
of this series.

the holes. an `as` cast returns its target type unchecked (13867), so
`print as function(): never` forges the guarantee; so does `if v is
function(): never` on an `any`, with no cast. the cast policy in
[`doc/roadmap.md`] closes the first; the second needs the same restriction
on `is`. a call through `any` carries no flag, and a declaration that says
`never` and returns is a bug in the declaration.

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

this holds at the top level only. the same rule compares the parameters and
returns of two function types through `arg_check` with `"bivariant"` (9860,
9871), which accepts `is_a(a, b)` or `is_a(b, a)`. with a subtype in one
direction, the other direction would let a `function(): string` stand for
a `function(): never` inside a parameter or return, and `local h:
function(): function(): never = function(): function(): string ... end`
would pass: `h()()` would end a block that returns. so inside a function
type's parameters and returns, two function types must agree on `never`
before `arg_check` runs, as the invariant table requires. (the same hole
for a union member or a container element is closed by the invariant table
below.)

`eqtype_relations["function"]["function"]` (9535, the invariant comparison
used inside generics and containers) treats `a.never ~= b.never` as a
mismatch before it counts returns, so `{function(): never}` and
`{function()}` are not one type. one consequence: a record function is
checked against its field with `same_type` (13649), so `function
Guard.die(...): never` is refused if the field `die` is declared without
`: never`. the declaration must say it. the `typeid` shortcut in
`compare_types` is safe: ids are per allocated type, not per shape.

one use shows the rule biting. [`build/invoke.tl`] replaces [`sys.exit`] in a
test seam with `function(_?: integer) refuse("sys.exit") end`. once
[`sys.exit`] is `never`, that literal must be one. 37d and 37f give a literal
that omits its return list the returns of its context; 40g makes that
include the flag. its body ends in `refuse(...)`, so `refuse` must be
declared `: never`. the same annotation lets the `execve` and `attach`
stubs below it drop the dummy `return` they keep after `refuse(...)`: their
bodies now end a block.

## defining a never-function

a function declared `never`:

- contains no `return`, not even a bare one. the function visitor sets
  `@return` (10865) and the `return` visitor reads it with `find_var_type`
  (13183), which walks outward. every function therefore sets its own
  `@never`, true or false, so that a closure inside a never-function checks
  its own `return`s against its own declaration.
- must not reach its end: its last statement must have `block_returns`, the
  test 37f applies to a literal whose context expects values. 21 through 25,
  39a through 39d and the call rule put that flag on a statement, so a body
  may end in a never-call, a `while true` with no `break`, a `do` that
  ends, or an `if` with an `else` whose every block ends. an `if` without
  an `else` does not count (21), nor does `assert(false)` (open question 3).

37f checks only `required > 0`, and only for a literal with a context. 40f
moves the end test into a local function, and 40g calls it also for a
literal whose context is a never-function (required is 0 there). a
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

- stdlib `error` (442): `function(? any, ? integer): never`. `os.exit` (320)
  could be too; [`cosmic/removed.tl`] bans it (open question 2).
- [`Proc.exit`] ([`cosmic/proc.tl`], 73): `(status: integer): never`; its body
  `sys.exit(status)` is then a never-call that ends it.
- `sys.exit`: [`core/syscalls.h`] declares it with no `@return`, which
  [`build/gen_syscalls.tl`] already reads as "never returns (0)". `signature`
  writes `: never` for zero results instead of no list. `exit` is the only
  binding without `@return` in `syscalls.h`, `process.h` and `socket.h`.

## open edges

generics work once `resolve` copies the flag, which lives on the inner
`FunctionType`. assigning a poly value to a `function(): never` should
require every overload to be never; the poly row of `subtype_relations`
must be read before this is promised. an `unknown` callee in lax mode (`.lua`
files) carries no flag.

## patch list

continuing after `39d`, each a record in `patch/tl/` with a `note:`:

```text
40a-a-function-type-can-never-return.txt          FunctionType.never, Node.never
40b-never-is-a-return-list.txt                    parse_return_types; no type named never
40c-a-never-function-is-copied-and-shown.txt      every a_function site, resolve, show_type
40d-a-never-function-is-a-bottom-subtype.txt      subtype, eqtype and the nested rule
40e-a-never-call-ends-a-block.txt                 the rule in type_check_function_call
40f-a-never-function-does-not-return.txt          own @never, no return, no reachable end
40g-a-literal-takes-never-from-its-context.txt    37d and 37f read the flag
41-error-is-never.txt                             stdlib error: never; 25's handler forwards
```

until 41 lands `error` is not declared `never`, so 25 alone handles it.
[`sys.exit`], [`Proc.exit`] and `refuse` change in the tree after it.

tests, in [`test/narrowing_test.tl`]'s style (a one-file project compiled
with [`build.importer`]; [`build/teal_test.tl`] holds compiler tests of the
same shape):

- 40b: `: never` parses on a declaration, a method and a function type;
  `(never)`, `never, string`, `{never}`, a `never` parameter and `local
  record never` are refused.
- 40d: `local g: function(string) = fail` and `pcall(fail, "x")` compile;
  `local f: function(): never = print`, `f = print` after `local f = error`,
  `{function(): never}` for `{function()}`, a `function(): function():
  never` given a `function(): function(): string` (and the same through a
  parameter), and `function Guard.die(): never` against a field without
  `: never` are each refused. `if v is function(): never` on an `any` is
  accepted, and the test says so (open question 6).
- 40e: a `fail` helper narrows below `if x == nil then fail("no") end` as a
  local function, a record field, a method, a `__call` and a generic; a
  poly overload narrows only where the chosen overload is never; a never
  iterator in a `for ... in` and a never operator metamethod do not mark
  the loop or the expression as ending a block; an `if` without an `else`
  still does not end the block; `pcall(fail, ...)` does not narrow.
- 40f: a bare `return`, `return 1`, a body falling off its end, and a last
  `if` without an `else` are refused; a body ending in a never-call, `while
  true` or a recursive call is accepted; a closure with a `return` inside a
  never-function is accepted, and a `return` in the never-function itself
  is refused.
- 40g: the `sys.exit = function(_?: integer) refuse(...) end` shape; a
  literal under a never context whose body falls through is refused.
- 41: the first two tests of 25 pass unchanged; the third inverted;
  `error = print` is refused.
- generator ([`build/gen_syscalls_test.tl`]): a block with no `@return`
  writes `: never`; one with a return does not.

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

## open questions

1. is a flag on the function enough, or is a bottom type wanted later, such
   as `T | never` in a generic's return?
2. should `os.exit` be declared `never` for programs outside the tree, or
   left alone since [`cosmic/removed.tl`] bans it?
3. should `assert(false, msg)` end a block? it would need a handler of its
   own, since `assert`'s type does not carry the fact.
4. should `local x = fail()` say that `fail` never returns instead of the
   generic missing-initializer message?
5. is refusing the declaration of a type named `never` acceptable to
   downstream projects, or should the bottom type take another spelling?
6. should `is` on a function type be restricted along with `as`, or is the
   hole accepted until the cast policy lands?

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
[`test/narrowing_test.tl`]: ../../test/narrowing_test.tl
[`vendor/tl/tl.tl`]: ../../vendor/tl/tl.tl
