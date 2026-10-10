# a bottom return type for Teal

this document proposes `: never`, a return list that says a function does
not return, as a series of records under `patch/tl/`. nothing here is
built. it was checked against [`vendor/tl/tl.tl`] (Teal 0.24.8, unpatched)
and the records `patch/tl/21` through `39d`; where the code differs from
the first sketch, the text says so.

## the problem

Teal cannot say "this function never returns", so a helper that only
raises narrows nothing:

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
and [`Proc.exit`] ([`cosmic/proc.tl`]) has the same problem: it is a wrapper
over [`sys.exit`], and code after `if bad then Proc.exit(2) end` does not
see `bad` handled.

two corrections to the first sketch. `#x` on `string | nil` is not
refused by this compiler, nor is `local y: string = x`: only an index, a
method call or a call of the value is, so the probe uses `x:len()`. And
`return fail(x)` already compiles in any function (below).

## syntax

`never` is accepted only as the whole of a return list, in the places that
call `parse_return_types` (tl.tl, 2890): a function type, a function or
method declaration, and a `macroexp`.

```teal skip=intended
local function fail(m: string): never
  error(m)
end

local record Guard
  die: function(self: Guard, why: string): never
end
```

`never` is not reserved. no type of that name exists in the tree (`grep -w
never` finds only prose), and the parser reads the word as the bottom type
only where it is the single item after the `:` of a return list, with or
without parentheses. elsewhere (`(never, string)`, `{never}`, a parameter)
it is an ordinary name and the checker says it is unknown, the right
refusal. a program that declares its own type `never` loses only this one
spelling; the parser cannot see scopes, so the rule is syntactic.
reserving the word would be easier to explain and would break such a
program everywhere.

the representation is a flag, not a type: `FunctionType` (tl.tl, 1992)
gains `never: boolean`, and the parser gives the function an empty `rets`
tuple, as for a function that declares no returns. emitted Lua is
unchanged, since it never mentions return types. the flag must be copied
where the checker copies a function type (`resolve`, tl.tl, 8265, which
copies each field by hand) and printed where it shows one
(`show_type_base`, 7225), or a never-function is forgotten after one
generic instantiation.

## the call site

patch 25 sets `node.block_returns` on a call spelled `error` whose name is
the global or a `<const>` local. the general rule: after
`type_check_function_call` (tl.tl, 10542) resolves the callee, a
`@funcall` whose resolved `FunctionType` has `never` sets `block_returns`
on the call node. the function already returns the chosen callee beside
the result (`return ret, f`), and for an overloaded callee `f` is the
overload `check_poly_call` picked, so the flag is per overload. a method
call reaches the same function (`type_check_funcall` only inserts the
receiver), so `guard:die(why)` ends a block too. the rule must test for a
`@funcall`: `__call` and operator metamethods reach the same function and
are never statements.

`pcall(fail, x)` does not end a block, and the code already gives that:
`special_pcall_xpcall` (tl.tl, 11594) checks the inner call on a synthetic
`@funcall` node, so the flag lands there, and the real `pcall` call has
the type `boolean, any...`.

### what replaces 25's rule

25 trusts a call only when it is spelled `error` and `error` is scope 1 or
a `<const>` local, because a name is not a type: a variable holding the
function could be assigned another function later, and the handler would
narrow on a call that returns. with the flag on the type, the guarantee is
checked where the variable is written, which is sound under Teal's
assignment rules:

- `local f = error` gives `f` the type of `error`, flag included. `f =
  print` is then a function that may return assigned to a never-function,
  which the subtype rule below refuses. today it is accepted, which is
  why 25 needs the scope test.
- `error = print` on the global is refused the same way.
- passing a never-function where `function(): T` is expected loses the
  flag, the safe direction.

so 24a (`error` joins `SpecialFunctionName`), 24b (`set_special_function`
for `error`) and 25's handler and scope test go, and one stdlib line
(`error: function(? any, ? integer)`, tl.tl, 442) gains `: never`. the
tests of 25 in [`test/narrowing_test.tl`] (`test_error_narrows_below_the_guard`,
`test_a_local_error_does_not_narrow`,
`test_a_reassignable_local_error_does_not_narrow`) should pass unchanged.

the holes are the ones Teal already has. an `as` cast returns its target
type unchecked (tl.tl, 13867), so `print as function(): never` forges the
guarantee; the cast policy in [`doc/roadmap.md`] closes it. a call through
`any` carries no flag. a `.d.tl` or C declaration that says `never` and
returns is a bug in the declaration.

## subtyping

Teal compares function types in two tables, and both need a rule.

`subtype_relations["function"]["function"]` (tl.tl, 9853) serves
assignment and argument passing. it refuses `#ar < #br` ("incompatible
number of returns"), so a never-function, with no returns, cannot today be
given where `function(): string` is expected. the rule:

- `a.never`, not `b.never`: skip the return check. a never-function is a
  subtype of every `function(...): T`, including `pcall`'s parameter.
- `b.never`, not `a.never`: an error. without it, `local f: function():
  never = print` makes `f("x")` end a block that `print` returns from.
- both: arguments compare as before.

`eqtype_relations["function"]["function"]` (tl.tl, 9535, the invariant
comparison used inside generics and containers) treats `a.never ~= b.never`
as a mismatch before it counts returns, so `{function(): never}` and
`{function()}` are not one type. the `typeid` shortcut in `compare_types`
is safe: ids are per allocated type, not per shape.

one use shows the rule biting. [`build/invoke.tl`] replaces [`sys.exit`] in a
test seam with `function(_?: integer) refuse("sys.exit") end`. once
[`sys.exit`] is `never`, that literal must be one. 37d and 37f give a literal
that omits its return list the returns of its context; 40g makes that
include the flag. its body ends in `refuse(...)`, so `refuse` must be
declared `: never`. the fix in `invoke.tl` is that one annotation.

## defining a never-function

a function declared `never`:

- contains no `return`, not even a bare one. the `return` visitor reads the
  declared tuple from the `@return` variable (tl.tl, 13196); a
  never-function also sets `@never`, and a `return` under it is an error.
- must not reach its end: its last statement must have `block_returns`, the
  test 37f applies to a literal whose context expects values. 21 through 25,
  39a through 39d and the call rule put that flag on a statement, so a body
  may end in a never-call, a `while true` with no `break`, a `do` that
  ends, or an `if` with an `else` whose every block ends. an `if` without
  an `else` does not count (21), nor does `assert(false)` (open question 3).

37f runs only for a literal with a context, so its check moves into a
local function both callers use. a recursive call counts: a `local
function`'s name is in scope in its body with its declared flag, so `local
function spin(): never spin() end` is accepted, and does not return.

the declaration is the contract: nothing infers `never` for an undeclared
helper, since the type of a function would then change with an edit to its
last line, and callers in another module would need the body.

## what stays as it is

- `return fail(x)` is accepted in any function, already. the `return`
  visitor's loop runs `for i = 1, n_got`, and a never-call gives no
  values, so nothing is checked against the declared returns, as with
  `return print()` today.
- `local x = fail()` is refused today for every function with no returns
  (`assignment in declaration did not produce an initial value`) and stays
  so, since a never-function has an empty `rets`.
- emitted Lua: the flag is erased with the types.

## declarations

- stdlib `error`: `function(? any, ? integer): never`. `os.exit` (tl.tl,
  320) could be too; [`cosmic/removed.tl`] bans it (open question 2).
- [`Proc.exit`] ([`cosmic/proc.tl`], 73): `(status: integer): never`. its body
  `sys.exit(status)` is then a never-call that ends it, as the definition
  check requires.
- `sys.exit`: [`core/syscalls.h`] declares it with no `@return`, which
  [`build/gen_syscalls.tl`] already reads as "never returns (0)" (the
  message for a wrong count says so). `signature` writes no return list for
  zero results; it writes `: never` instead. `exit` is the only binding
  with no `@return` in `syscalls.h`, `process.h` and `socket.h`, so no other
  declaration changes.

## open edges

- generics: the flag lives on the inner `FunctionType` of a `GenericType`,
  so `function<T>(x: T): never` works once `resolve` copies it.
- poly functions: a call reads the overload chosen. assigning a poly value
  to a `function(): never` is not analysed here; it should require every
  overload to be never.
- lax mode (`.lua` files): an `unknown` callee carries no flag.
- a never-function that yields forever or is abandoned as a coroutine does
  not return, as intended.

## patch list

continuing after `39d`, each a record in `patch/tl/` with a `note:`:

```text
40a-a-function-type-can-never-return.txt          FunctionType.never, Node.never
40b-never-is-a-return-list.txt                    parse_return_types reads a lone never
40c-a-never-function-is-copied-and-shown.txt      resolve copies it, show_type prints it
40d-a-never-function-is-a-bottom-subtype.txt      the subtype and eqtype rules
40e-a-never-call-ends-a-block.txt                 the call rule
40f-a-never-function-does-not-return.txt          no return, no reachable end
40g-a-literal-takes-never-from-its-context.txt    37d and 37f read the flag
41-error-is-never.txt                             stdlib error: never; deletes 24a, 24b, 25
```

41 is last because it deletes three records: until it lands `error` is not
declared `never`, so 25 alone handles it. [`sys.exit`], [`Proc.exit`] and
`refuse` change in the tree after it.

tests, in [`test/narrowing_test.tl`]'s style (a one-file project compiled
with [`build.importer`]; [`build/teal_test.tl`] holds compiler tests of the
same shape):

- 40b: `: never` parses on a declaration, a method and a function type;
  `(never)`, `never, string`, `{never}` and a parameter `never` are refused.
- 40d: `local g: function(string) = fail` and `pcall(fail, "x")` compile;
  `local f: function(): never = print`, `f = print` after `local f = error`,
  and `{function(): never}` given for `{function()}` are each refused.
- 40e: a `fail` helper narrows below `if x == nil then fail("no") end` as a
  local function, a record field, a method and a generic; an `if` without
  an `else` still does not end the block; `pcall(fail, ...)` does not narrow.
- 40f: a bare `return`, `return 1`, a body falling off its end, and a last
  `if` without an `else` are refused; a body ending in a never-call, `while
  true` or a recursive call is accepted.
- 40g: the `sys.exit = function(_?: integer) refuse(...) end` shape.
- 41: the three tests of 25 pass unchanged; `error = print` is refused.
- generator ([`build/gen_syscalls_test.tl`]): a block with no `@return`
  writes `: never`; one with a return does not.

## cost and what it unlocks

each of 40a through 40d and 41 is a few lines; 40e is about five and 40f
moves 37f's check into a function. all of it edits parts of tl.tl the 21
through 39 records already touch, so a rebase against them is the main
cost. there is no runtime or C change.

it unlocks: guards through `spec_error`, `fail` and [`Proc.exit`] narrow as
`error` does; a module keeps one raising helper instead of inlining
`error(...)` at each guard to get narrowing; a command's `main` ends with
`Proc.exit(code)` without a dummy `return`.

## alternatives

- status quo: inline `error(...)` at each guard that must narrow, or follow
  the helper with an unreachable `return`. both happen in the tree now.
- extend 25's name list to [`Proc.exit`]. the handler is keyed by a stdlib
  function object (24b), so each name needs a `SpecialFunctionName` entry, a
  scope test for the reassignment hole, and a patch; a project's own `fail`
  stays uncovered. the type-level flag is one rule for any function.
- a full bottom type (`local x: never`, `T | never`). nothing here needs
  it, and it would reach every table in the checker.
- inferring `never` from a body: rejected above.

## open questions

1. is a flag on the function enough, or is a bottom type wanted later, such
   as `T | never` in a generic's return?
2. should `os.exit` be declared `never` for programs outside the tree, or
   left alone since [`cosmic/removed.tl`] bans it?
3. should `assert(false, msg)` end a block? it would need a handler of its
   own, since `assert`'s type does not carry the fact.
4. should `local x = fail()` say that `fail` never returns instead of the
   generic missing-initializer message?
5. keep `never` unreserved, or reserve it and break a downstream type of
   that name?

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
