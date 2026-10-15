# strict teal

this document is the plan for the language cosmic checks. it starts from
Teal's syntax and compiles to Lua 5.5, and it is cosmic's own: where Teal
or a Lua idiom costs soundness, simplicity or speed, the language breaks
with it, and the error, its doc and its rewrite carry the break. it states
the stance, the rules the checker is to hold, what the tree measured
against them, the order the work lands in, and the questions still open.

the work has two phases. in the first, the checker forked from Teal is
taken as far as four foundations: it compiles from the pinned release
rather than upstream's `tl.lua`, its narrowing is the facts of step 7a and
narrows only what cannot change behind its back, nil is in no type that
does not name it, and classes have no metatable but the one the compiler
writes. in the second, a new checker is written for the smaller language
those leave, and the remaining rules land in it.

once a step merges its section is marked done, and
[design.md](../design.md)'s teal section states each rule as it lands.
once every step is done this file is deleted, as
[roadmap.md](../roadmap.md) deletes what ships.

it serves the first promise and the fourth principle in
[design.md](../design.md): types never lie, and the type layer has no escape
hatch.

## why the checker has many small gaps

`patch/tl/` carries 167 patch files against upstream Teal 0.24.8. most of
them close one instance of a gap whose cause stays in place, so the next
instance appears where no patch has reached. these causes account for most
of them.

- **nil is a member of every type.** upstream's subtype table states
  `["nil"] = { ["*"] = compare_true }`. patches 50c to 50f, 51b, 51c, 51f,
  52a and 52b refuse a value that may be nil at one use site each: an
  operand, a `for` bound, a `table.insert` argument, a literal's omitted
  field. the sites with no patch accept it: an argument for a parameter of
  type `T`, a `return` from a function declared to return `T`, a write to a
  record field of type `T`, and a `local x: T` declared without a value. a
  nil that passes one of those reads as `T` from then on. standard library
  declarations that answer `T` where the call can answer nil
  (`string.match`, `table.remove`, `rawget`, `select`) feed it more.
- **narrowing is a set of facts on lexical scopes.** upstream's facts
  (truthy, equal, is, and their `not`, `and` and `or`) widen a variable
  only when it is assigned. each narrowing form is a patch of its own (02,
  03, 07 to 14, 35, 36, 51a), and so is each statement that ends a block
  (21 to 25, 39, 43f, 43g). no fact is dropped when a call, a closure or
  another reference to the same table can change the value it is about.
  both of these are accepted and fail at run time:

  ```text
  if r.n then clear() print(r.n + 1) end         -- clear sets r.n = nil
  if r.n then local c = r c.n = nil print(r.n + 1) end
  ```

- **one comparison with no notion of variance.** `is_a` compares a nested
  type in the same direction as its container, so `{integer}` is a
  `{number}` and a callee given one can store a float in it. the 48
  patches fix function parameters, returns and field comparisons one
  relation at a time, with an exemption for a method's receiver (48e);
  43e5 carries `: never` through nested types the same way. arrays, maps
  and interface fields are still covariant.
- **`: never` is a flag, because nil holds the bottom of the lattice.** a
  real bottom type would make `function(): never` a subtype of
  `function(): T` by ordinary return covariance. as a flag it took 37
  patch files (43a1 to 43h5) to keep it sound.
- **the type language cannot describe the standard library.** `assert`,
  `type`, `coroutine.wrap` and `setmetatable` are special cases in the
  checker (15 to 19, 36, 45, 47), each because its declaration cannot say
  what the call does: `assert` and `type` narrow their argument, `assert`
  answers it without nil, `coroutine.wrap` answers a type made from its
  argument's. a helper of the tree's own that narrows, such as a
  [`cosmic.shape`] validator, cannot say it either. `: never` (44a) is the
  one such typing a declaration gained, and it lets `error` be declared
  rather than special.

the patch format adds one more.

## why the narrowing holes keep coming

the fuzz test (step 6) keeps finding holes in narrowing, each closed by a
local fix, and the cause sits in upstream's design, not in any one fix.

- **narrowing overwrites a declared type and undoes it.** upstream
  narrows by replacing a variable's type in place (`specialize_var`) and
  restoring it with scope markers (`narrow`, `widen` and `localizing`
  entries, `widened_from`). every construct must remember to undo, and
  four of the last five holes were an undo that a construct forgot.
- **a fact persists until something removes it.** the list of removers (an
  assignment, a call, a loop, a label) is a blacklist, and a blacklist is
  never complete: the next construct is a remover nobody listed.
- **there is no control-flow graph.** the checker is a single in-order
  walk over the syntax tree, and each construct merges the facts of its
  branches by hand.
- **Lua gives no effect information.** a table has aliases, a closure
  assigns the locals it captures, and a metatable adds dispatch at run
  time, with nothing in a type that says which call does any of it.
- **nil is a member of every type,** so a fact "not nil" is the only
  thing standing between a read and a nil, and one lost fact is a run-time
  fault.
- **upstream had no soundness oracle.** nothing generated programs and
  ran them against what the checker accepted until the fuzz test did.

step 7a replaces the first three with a design that is sound by
construction. the fourth is answered by narrowing only what no other code
can change: a local, which only its own function assigns once closures
cannot (R2), and a read-only field, which nothing assigns after its table
is made. a call then drops no fact, and no list of what runs code is kept
for narrowing. a patch finds and replaces text in one
15,000-line file, so a change of one idea lands as dozens of local hunks,
and a change to a foundation, such as nil's place in the subtype table,
touches more places than a patch stack can carry. the hints in
[`build/teal.tl`] match on the text of the checker's messages, about 42
patterns, for the same reason: the checker cannot be given a structured
error without another patch.

## the stance

- **cosmic's own language, not a dialect of Teal.** a restriction refuses
  a program upstream Teal accepts. an extension adds syntax or a typing
  upstream lacks, and is admitted only where the typing it gives cannot be
  written otherwise. a shorter spelling of a type the language already has
  is not an extension: `T?` for `T | nil` is a spelling. a cosmic program
  need not be valid upstream Teal, and compatibility with Teal or with a
  Lua idiom is never a reason to keep a rule. the compiler emits Lua for
  the 5.5 runtime.
- **simple, strict and fast, in that order of cost.** a rule that makes
  the checker smaller or the emitted Lua faster is preferred to one that
  keeps an idiom. what the checker knows about a type may change the Lua
  it emits (a class's metatable, rule 10), where that is the price of a
  sound rule.
- **a category is closed by a rule, never by sites.** each rule is stated
  once in the checker: one subtype relation with its variance, one flow
  analysis. a change that adds a check for one more syntactic form is the
  sign that a rule is missing.
- **a restriction is preferred to an analysis.** where soundness needs
  either a cleverer checker or a narrower language, the narrower language
  wins when the idiom it costs has a plain rewrite. narrowing a field and
  then calling a function is refused rather than tracked through the
  callee: copy the field to a local first.
- **sound from the start, looser by measurement.** a rule lands at its
  sound form. a refinement that accepts more (a loop pattern, an escape
  analysis) is added later, when a measurement shows the need, and breaks
  no program that already checks. the reverse order would break the tree
  at every tightening.
- **every refusal carries its rewrite.** a rule lands with a structured
  error (a code and the places involved, not text a hint re-parses) and a
  hint that names the plain rewrite, both pinned in
  [`build/teal_test.tl`] as `test_a_value_that_may_be_nil_is_told_the_check`
  pins today's. a refusal of a narrowing names the call or write that
  dropped it. each code has a page `cosmic docs <code>` shows: the rule,
  why it holds, and the rewrite. a rewrite that is mechanical (a field
  declared read-only, a class made by its literal, a cast that becomes an
  `is`) ships as a migration in `cosmic fix`, so a break costs the tree,
  and a project outside it, one command. the error, its doc and its
  migration are what make a break affordable.
- **strict is the only mode.** a rule moves through the tree in report
  mode, then lands for every module at once. no module keeps a lax mode,
  which would be an escape hatch.

## decisions

- **the checker is the tree's own source, split by concern as each
  concern lands, until the new checker replaces it.** it lives in
  `checker/`, outside the module closure it compiles, and is edited
  directly. a step that gives a concern its rule gives it a module of its
  own (`checker/flow.tl`, `checker/narrowing.tl`, `checker/facts.tl`), so
  no step exists only to split. the patches are not proposed upstream and
  are not rebased onto a newer release, so the patch format buys nothing
  and costs every foundational change.
- **the seed is the pinned release (step 7b).** the release
  [`ci/cosmic-driver.pin`] names compiles the checker's source to Lua, and
  boot loads that in place of upstream's `tl.lua`. `vendor/tl/` goes,
  except for the license and notice the checker inherits, and so does the
  part of the boot bridge that fakes `io`, `os` and `package` for
  `tl.lua`, with its own compile cache. the pin is already the root of
  trust for [`bin/zig`], [`bin/vendor`] and the scripts they run, so it
  adds no root; a seed committed to the tree would add one beside the pin
  and the pinned Zig. the
  checker's own source may use what the pinned release's checker accepts:
  a rule or a syntax lands in the tree first and reaches the checker's
  source one pin move later, as in any compiler that compiles itself, while
  the rest of the tree uses it at once. the way back from a release whose
  checker is broken is the previous pin, a one-line revert, and
  `COSMIC_BOOTSTRAP` runs any other cosmic in its place. the fixed point
  of [`build/compiler_test.tl`] keeps a broken checker from being released:
  the checker compiled by the seed compiles its own source, and the
  checker that gives compiles it again to exactly the same Lua.
- **a new checker for the smaller language (step 10).** once the four
  foundations hold (the seed, narrowing by construction on places nothing
  else changes, nil in no type that does not name it, classes whose
  metatable the compiler writes), the language the forked checker must
  handle is much smaller than Teal: structured control flow, no
  closure-assigned locals, no run-time metatables, no nil in every type.
  a checker written for that language is smaller and faster than one
  migrated in place, and the migration's cost is visible already: shadow
  mode had to copy the old narrowing's quirks to agree with it. the
  forked checker gets only what the four foundations need. every rule
  after them (variance, views, named receivers, narrowing declarations,
  tagged unions, `or` and `and`, casts and parameters) is specified here
  and built in the new checker, not in the fork.
- **declarations are the trust boundary.** a `.d.tl` signature, and a
  narrowing declaration (rule 8), is the only typing the checker takes
  without proof. the standard library's Lua declarations move out of the
  checker into `.d.tl` files, so auditing them changes no checker logic.
  a declaration answers `any` only at a named untrusted-data entry point:
  `require` of an untyped module, `string.unpack`, and the [`cosmic.sys`]
  bindings.
- **the rules are tested against programs that must be refused.** every
  hole found becomes a refused program in [`build/teal_test.tl`], which
  already pins today's known holes (`test_as_and_is_forge_a_never_function`,
  `test_a_function_index_serves_any`,
  `test_a_callback_field_with_a_record_parameter_is_the_known_limit`). a
  step that closes a hole flips its pin from accepted to refused.
- **a test run reports the types it was promised.** under the test runner,
  the compiler can emit a run-time check of each declared parameter,
  return and record field write against the declared type's nil-ness and
  primitive kind (records are erased, so a record is checked as a table).
  it reports, and does not fail the run, until nil exclusion has landed:
  before then it flags legal code. the check mode is part of every compile
  cache key, a test proves no built executable carries a check, and a
  report names the caller's line, not the callee's.
- **a checker step is reviewed twice and measured against main.** each
  step has two review rounds. each also runs a differential against main
  over the common idioms of the tree, which measures over-refusal as well
  as soundness: a rule that refuses what main accepted and the tree writes
  is a bug in the rule or a missing rewrite. random programs and
  differential runs find what review does not (see "what the first steps
  taught").
- **optimize for the strong design; it is easy to rewrite the existing
  code.** migration cost is not a reason to choose a weaker rule. a rule is
  chosen for soundness and simplicity, and the tree is migrated to it.
- **the checker, the compiler and the Lua VM are one target.** cosmic
  vendors and patches its Lua, so the compiler emits for exactly that VM,
  the patches included, and never for a range of Lua versions: the
  generator's 5.1, 5.3 and 5.4 branches, `gen_target`, `gen_compat` and
  the compat entries go, and so does any shim for a Lua the tree does not
  run. a rule may rest on a VM change (rule 18), and the VM may gain what
  the compiler needs: an entry point that makes a class's value with its
  metatable, an opcode, a bytecode the compiler writes directly. the
  compiler's identity already holds the Lua pin and patches, so a VM
  change rekeys every compile. the one boundary is the seed: the pinned
  release emits Lua source for the checker, not bytecode, because the
  tree's VM may have moved past the release's.
- **the runtime changes only where normal runs pay nothing, and loses
  what the language does not need.** the guarantees are type-level
  restrictions, plus Lua VM and surface changes that cost a normal run
  nothing or make it faster (rule 18). a program has no `setmetatable`,
  `getmetatable`, `rawset` or `rawget`: the code the compiler emits for a
  class reaches the VM through an entry point a program cannot name. the
  strict-record and frozen-table checks run only in debug and test runs, as
  `--check-types` does. there is no always-on write check.
- **type-level syntax is allowed in the fork; statement and expression
  syntax waits for the new checker.** an annotation that is erased when
  compiling to Lua may be added to the forked checker, as a read-only
  field (rule 4) is. no new statement or expression form is added to the
  fork, and no `pure` annotation. the new checker's grammar is cosmic's
  own, and what it adds or removes is an open question. `<const>` is Lua
  syntax and stays.
- **what the claim excludes.** types do not track integer overflow,
  division by zero, or code a C userdata's finalizer runs. each is a
  run-time fault, not a type that lied. a table a program makes has no
  finalizer (rule 18).

## the rules

each rule is a restriction (R) or an extension (E). the step that lands it
is in "the steps".

1. **nil is a type of its own (R).** `T` admits no nil. `T | nil`, its
   spelling `T?`, and a `name?: T` field are the only ways to admit it.
   `nil` is a unit type; `never` is below it. an argument, a return, a
   field write and an initializer are checked by the same subtype relation
   as every other value, so the use-site rules of patches 50c to 50f, 51b,
   51c, 51f, 52a and 52b become that relation. a method call or an index
   on `T | nil` is refused, as an index key that may be nil is. a type
   variable ranges over all types, unions with nil included: inside a
   generic body a `T` may be nil, and `x as T` removes no nil. the standard
   library's declarations are audited, each of these named: `string.match`
   and `string.find` (each capture `string | nil`), `table.remove`,
   `rawget`, `next`, `select`, `math.tointeger`, `pcall`, `xpcall`,
   `coroutine.resume`.
2. **an index read can answer nil (R).** `m[k]` and `m.k` on a `{K:V}` are
   `V | nil`. `t[i]` on a `{T}` is `T | nil`, because Lua answers nil for an
   index out of range rather than trapping. one refinement answers `T`,
   and only this: in `for i = a, #t` (or `#t - d`) and
   `for i = #t, 1, -1`, with `a` a literal of at least 1, `t[i]` (and
   `t[i + c]` for `c <= d`) is `T` when `t` is a local the body neither
   assigns nor passes to a call. an index is not a place (rule 4): a test
   of `t[k]` narrows nothing, and the rewrite is
   `local v = t[k] if v then ... end`.

   a tuple type indexed by a literal in range is its member's type, and out
   of range is refused. length facts (`#t > 0` giving `t[1]`) are not
   tracked. a further pattern waits for a measured need.
3. **an array is dense (R).** `{T | nil}` is refused as an array type: `#`,
   `ipairs` and `table.insert` are defined on a sequence, and a hole makes
   each unreliable. sparse data is a map, `{integer:T}`, and `#` on a map
   is refused.
4. **one flow analysis decides narrowing and reachability, and narrows
   only what no other code can change (R, E).**
   - a place is a local, or a path of read-only fields from a local
     (`r.a.b`, with `a` and `b` each declared read-only). a field of a
     record is read-only when the record declares it so: it is given a
     value by the table literal that makes the record and is never
     assigned after, through any reference. a global, a mutable field and
     an index are not places, and a test of one narrows nothing; the
     rewrite is a local copy, `local n = r.n if n then ... end`, which the
     hint gives.
   - a guard is a truthiness test, `== nil` and `~= nil`, `==` with a
     literal, `is`, `type(x) == "..."`, their `not`, `and` and `or`, a
     narrowing call (rule 8), and a branch that ends its block.
   - an assignment to a local drops what was known of it and of every path
     from it. nothing else drops a fact: a closure cannot assign a local it
     does not declare (R2), and no reference can assign a read-only field,
     so neither a call, a write through an alias, an operator nor a
     metamethod can change a place. the analysis keeps no list of what
     runs code for narrowing; definite assignment (rule 5) keeps the one
     it needs.
   - a statement with no successor (`return`, `break`, a `goto` out of the
     block, a loop with no exit, a call of a `: never` function) ends its
     block. a `goto continue` to a label in the same loop does not end the
     path.

   this replaces upstream's facts and the per-form narrowing and
   block-ending patches. step 7a gives it the form described there. a
   read-only field is type-level syntax, erased in the emitted Lua. a
   record that implements an interface declares a field read-only exactly
   when the interface does, which the read-only field's own step checks
   before rule 7's exact field types land, and a record passed as a map is
   refused (rule 11), so no view of the table can assign the field.
5. **a local is assigned before it is read (R).** `local x: T` with no
   value is legal only where every path assigns `x` before its first read.
   a loop body may run zero times. an assignment inside a function literal
   does not count, and creating a function literal reads every variable it
   names. `local x: T | nil` with no value is legal and is nil. a bare
   `local x` with no type and no value is refused with the hint to declare
   `local x: T | nil`.
6. **`never` is the bottom type (E).** with nil out of the bottom of the
   lattice, `never` takes it, and a function declared `: never` is a
   subtype of every function with its parameters by return covariance.
7. **each type constructor has one variance (R), and a read-only view is
   covariant (E).**
   - a function is contravariant in its parameters and covariant in its
     returns.
   - a mutable array or map is invariant: `{T}` accepts only `{T}`, and
     `{K:V}` only `{K:V}`.
   - a record is compared by name. a field of a record that implements an
     interface has exactly the interface's type. a method, a field whose
     function names its receiver (rule 13), cannot be assigned, and is
     compared as a function.
   - a generic record is invariant in its type arguments.
   - `readonly {T}` and `readonly {K:V}` are views. `{T}` is a
     `readonly {U}` when `T` is a `U`, and so is a `readonly {T}`; a view is
     never a `{U}`. through a view a program reads (`#`, an index read,
     `ipairs`, `pairs`, `next`, `table.concat`, `table.unpack`) and passes
     it where a view is expected; it never assigns an index or passes it as
     `{T}`. a view is shallow (`readonly {{T}}` has mutable elements), is
     erased in the emitted Lua, and applies to arrays and maps only. a
     function that only reads declares its parameter a view; one that
     returns or stores the container uses a generic.
8. **a declaration can narrow (E).** a function type may say that it
   narrows an argument to a type when it returns true, or that it returns
   only when an argument is not nil or false. `assert` and the
   [`cosmic.shape`] validators are then ordinary declarations, and the
   special cases of patches 15 to 19 go. the checker takes such a
   declaration on trust, as it does a `.d.tl` signature, so it is legal in
   a `.d.tl`, and in Teal only where the function's returned expression is
   itself a guard the checker verifies. `type` stays special, but answers
   through the same narrowing. `pcall`, `xpcall`, `coroutine.resume` and
   `coroutine.wrap` stay special until the language has variadic generics.
9. **a union of records is told apart by a tag (E).** a union of records
   is legal when each member has the same field typed by a distinct
   single-member enum, and comparing that field with a literal narrows the
   union. a chain of tests that covers every member leaves `never` in its
   final branch, so a function that must return can end there. `is` applies
   to primitive types, enums, `nil`, function and table kinds, and classes
   (rule 10); `v is R` for a record `R` that is not a class is refused (R),
   since Lua erases the record. the hint names a tag field or a
   [`cosmic.shape`] validator.
10. **a class's metatable is the compiler's (R, E).** a method is a
    `function R:name()` declaration or a field whose function names its
    receiver. a record that declares one is a class, and each method it
    declares is defined in its module. the compiler writes the class's one
    metatable: `__index` is its method table, and `__close` and
    `__tostring` are the methods of those names it declares. a value of a
    class is made by a table literal typed as the class, which the
    compiler emits with the metatable attached; there is no other way to
    make one, and a program cannot call `setmetatable` (rule 18). no other
    metamethod exists on a table a program makes: an operator other than
    `==` on a record, an interface or a class is refused, `==` on two
    tables is identity, and a function `__index`, `__newindex`, `__call`,
    `__len`, `__concat`, `__pairs` and the arithmetic and comparison
    metamethods have no form. what the tree does with them now becomes a
    method (`v:call(...)`, `v:len()`) or, for `__mode`, a weak table from
    the standard library. because the metatable is the compiler's,
    `v is C` for a class `C` is a check of it, so classes are told apart
    without a tag (rule 9 refuses `is` only on a record that is not a
    class).
11. **a record is not a map (R).** a record is never passed where a map or
    `{string:any}` is expected, and `pairs`, `next` and `rawset` refuse
    it, because its fields have types of their own.
12. **`or` and `and` answer only what they can (R).** `a or b` is refused
    when `a` may be `false`, since `or` replaces false as well as nil; the
    hint is `if a == nil then`. `c and x or y` is refused when `x` may be
    false or nil, since the expression then answers `y`; the hint is an
    `if`.
13. **a method names its receiver (R).** interfaces declare methods with
    `self: I`, `self` is always the declaring type, and the receiver
    exemption of patch 48e goes, with the hole it brings (a callback field
    `function(Event)` taking a `function(KeyEvent)`).
    [roadmap.md](../roadmap.md) holds the item for [`cosmic.stream`].
14. **varargs answer nil past their end (R).** an element of `...: T`
    read by `local a, b = ...`, `select(n, ...)` or `({...})[i]` is
    `T | nil`. a call that may answer no values, used where one value is
    wanted, answers `T | nil`.
15. **casts are confined (R).** as [design.md](../design.md)'s teal section
    states: `x as T` only from `any`, from a userdata record declared in a
    `.d.tl`, or from the enclosing generic's type variable. 230 of the 290
    non-test casts not from `any` are in the checker's own source, which
    the new checker replaces (step 10).
16. **a parameter is annotated (R).** a parameter of a function declaration,
    or of a function literal with no expected function type, has a type. a
    literal passed where a function type is expected takes its parameter
    types from it, as patch 37 does now, so a `table.sort` comparator needs
    none.
17. **a value dispatches only through what its type declares (R).** with
    rule 10, this holds by construction: the only metatables on tables a
    program makes are the compiler's, and the only code they run is a
    class's `__close` at a block's end and its `__tostring` under
    `tostring`. a C userdata declared in a `.d.tl` dispatches through the
    metamethods its declaration names. [roadmap.md](../roadmap.md) holds
    the item.
18. **the runtime has no implicit conversion and no hidden code (R).** the
    patched Lua and the surface [`core/surface.c`] opens are cut to what the
    language needs:
    - a string is never a number: arithmetic on a string and a string
      `for` bound fail in the VM, not only in the checker, so data typed
      `any` fails at the operation. `..` joins strings; a number is
      joined through `tostring`. this removes the coercion from `lvm.c`
      and the string metatable's arithmetic.
    - a program has no `setmetatable`, `getmetatable`, `rawset`, `rawget`,
      text `load` or `string.dump`. code the compiler emits, and the
      build's own compile, reach them through bindings a program cannot
      name, so everything a program runs came through `require` and the
      checker.
    - a table a program makes has no `__gc` and no `__mode`; a C userdata
      keeps its `__gc`. `<close>` is the finalizer of a Lua value.
    - `_G` cannot be replaced, assigned through, or given a metatable.

    each lands with its count in report mode, as `--check-types` runs
    measure it, before the VM refuses it.

`any` stays as it is: it is legal only where untrusted data enters, and the
checker already refuses to assign it, call it or index it.

rejected, so nobody proposes them again: a non-nil assertion `x!` (an
escape hatch; `assert(x)` says why), `a?.b` (the tree's field paths are
almost all non-nil), a `??` operator (rule 12 refuses the hazard
instead), bounded generics over primitive types, declaration-site variance
(`record Box<out T>`), narrowing a mutable field (rule 4 refuses it; a
local copy is the rewrite), and a typed `setmetatable` (rule 10 removes
it). each waits for a measured need.

## what the tree measured

the numbers below come from the review of this plan, by running the
checker over the tree with logging, or by heuristics where stated. they
size the steps; the report modes in the steps measure each again before it
lands.

- **array index (rule 2).** 10,719 index reads: 6,310 on arrays, 4,613 of
  them in tests. about 27% are already nil-checked where they stand. the
  loop and guard patterns cover about 13% of the rest. the largest
  remainder outside tests was a fixed-width row read by a constant index
  (`row[1]` from a [`Sqlite.rows`] result, about 520 reads). rows are read
  through typed accessors, so these reads are gone. about 4,613 test reads
  by index remain (see "open questions").
- **variance (rule 7).** about 1,420 places compared a container
  covariantly. 1,344 are `table.concat` of a `{string}` against its
  `{string | number}` declaration; three option signatures (`fds`,
  `gsub`'s table, `flags`) hold most of the rest. every callee reads only,
  except [`Json.array`], which returns its argument and needs a generic.
  no array of records passes as an array of an interface.
- **narrowing a field (rule 4).** of about 1,080 guards on a field path, at
  most 76 call a function in the guarded body and read the path again
  (heuristic). of the 752 narrowed field reads below, 79% are on fields
  never written after the table is made, so declaring those fields
  read-only keeps them; the rest, about 160 reads, take a local copy.
- **metamethods (rules 10 and 18).** raw mentions in `.tl` files outside
  `vendor/`, tests and comments included (heuristic): `__call` 29, `__gc`
  18, `__add` 14, `__newindex` 9, `__eq` 8, `__tostring` 5, `__mode` 5,
  `__len` 5, `__pairs` 3, `__concat` 3. `__close` and `__index` are the
  bulk of what classes declare.
- **narrowing by construction (step 7a),** measured on `origin/main` at
  e95cd66f4.
  - narrowed reads: 12,513. field reads: 752 (609 outside tests) on 557
    places; 79% of them are on fields never written after creation.
  - mutable-local narrowed reads: 1,545. turning narrowing off for them
    gives 1,070 error lines in 203 files.
  - closure-assigned narrowed reads: 153, on 105 places.
  - R2 sites (a function literal that assigns an outer local): 1,182
    (436 outside tests, 746 in tests) over 838 captured locals. no
    forward-declared function is assigned by a closure. the patterns: 190
    out-params declared without a value, 135 declared `= nil`, 324
    accumulators, 119 flags, 410 other.
  - `goto`: 5, all of the shape R3 allows.
  - `setmetatable`: 163 calls. 67 attach to a record that declares
    metamethods, 70 to a record that declares none (64 of them the
    class-method `__index = R` pattern), and 25 are untyped.
  - casts: 1,624, of which 958 are not from `any`: 290 outside tests (230
    in the checker) and 668 in tests.
  - drop sites with field facts: 1,008. about 30% of their callees in the
    tree are pure one level deep.
  - `rawset` 11, `rawget` 29, `debug.*` 3 (all in the checker).
- **the checker's own source.** it is the hard case: 320 type errors under
  its own rules, pinned as a count by
  [`build/compiler_test.tl`]. it has about 94 free locals, short of Lua's
  limit of 200.
- **nil (rules 1 and 5).** the migration of every directory outside
  `checker/` cost less than planned. `--check-types` finds what a call or
  return passes, but not a local or a field omitted from a table literal;
  those stay honest only once the static nil rule (step 8) lands.
  heuristic floors: about 80 `return nil` in
  functions declared to return non-nil, about 460 `local x: T` with no
  value, and 39 `table.remove` and 36 `select` calls. the uncounted class
  is nil passed as an argument or written to a field. the tree already
  writes about 3,000 `| nil` types and 1,100 `?:` fields. the checker's
  own source writes none and relies on nil being in every type.

## the steps, in order

each step is one or more PRs that follow [doc/contributing.md](../contributing.md):
each stands alone, passes CI, and has a test that fails without it. a step
that refuses more first runs in report mode, then migrates the tree, then
turns the refusal on for every module in one change. each PR states the
change in boot time and in the checker's self-compile time.

1. **move the checker, unchanged (done, #3032).** the patched `tl.tl`
   moves to its own root, compiled at boot, and the Lua it emits is
   byte-identical to what `vendor/tl/` plus `patch/tl/` gave. the change
   carries the compiler's identity and cache keys
   ([`build/identity.tl`], the CI cache names), the boot bridge, the bill
   of materials, [`build/compiler_test.tl`], `vendor/tl/`'s keep list and
   [design.md](../design.md)'s teal section, and a test that an edit to the
   checker changes the key of every cached compile. the self-compile test
   checks the checker's own source, and its type-error count is pinned.
   deleting `patch/tl/` is its own commit. a later PR turns the patches'
   notes into comments where they still say something the code does not,
   and settles which of the tree's checks hold the checker's source.
2. **structured errors and declarations (done, #3033 and #3039).** the
   checker answers a code and its places with each error; the hints in
   [`build/teal.tl`] read those, not message text. the Lua standard
   library's declarations move into `.d.tl` files.
3. **run-time checks in test runs, reporting (done, #3040).** they size
   what the later steps refuse.
4. **the flow analysis (rule 4), as modules of the checker.** in three PRs:
   - 4a, reachability, with what is accepted unchanged (done, #3041).
   - 4b, places and guards, unchanged again, in `checker/narrowing.tl`
     (done, #3044). the same PR fixes crashes that random narrowing
     programs found.
   - 4c, dropping facts at writes, calls, declared-metamethod operators,
     loops and backward-goto labels (done, #3050). it refuses more and
     migrates the tree. the measured count decided that a call to a
     function that cannot reach the place keeps its narrowing.
5. **definite assignment (rule 5) (done, #3061).**
6. **checker fuzzing, permanent (done, #3060, then #3062).** a test in the
   tree runs random programs through the checker and fails on any crash. a
   differential against a pinned corpus fails when what the checker accepts
   changes without a deliberate update of the corpus. the test runs on
   [`build.fuzz`], with its corpus in `testdata/fuzz/`.
7. **pin bump for the row accessors (done, #3056).** [`Sqlite.rows`]
   results are read through typed accessors (#3051, merged).
   [`ci/cosmic-driver.pin`] moves to a release that carries them and `ci/`
   drops its `ci/cosmic_ci/text_rows.tl` shim. the pin lags the tree, so
   `ci/` cannot use a new API before a bump.
7a. **narrowing by construction (rule 4).** it lands before every later
   rule, so the flow analysis they read is the sound one. the holes the
   fuzzer found in 4c (the `or` reading, closures in inner blocks, function
   bodies keeping outer facts, `local x = x` copies) are fixed (done,
   #3065). the design is in [strict-teal-7a.md], whose PRs 0 to 2 are
   done (#3070, #3069, #3074); shadow mode found four old-narrowing bugs,
   fixed in #3071, #3072, #3073 and #3075. its PR 3, where reads switch to
   the facts, lands after the seed (step 7b). in short:
   - declared types are never mutated. facts live in an immutable map from
     place to type, keyed by binding, carried along a small control-flow
     graph, and joins happen in one place.
   - it retires `specialize_var` and the scope-marker bookkeeping
     (`narrow`, `widen` and `localizing` entries, `widened_from`).
   - a place is a local or a path of read-only fields from one (rule 4).
     a local's fact is dropped precisely by assignment, and nothing drops
     a read-only path's. the field-path and global drops of 4c, and the
     facts that serve them, go.
   - read-only fields land in the same PR series, before reads switch: the
     syntax (erased in the emitted Lua), the refusal of a write to one
     outside the literal that makes its record, and rule 11, a record is
     not a map, so no view of a record can write the field. report mode
     counts the narrowed reads of mutable fields; a migration in
     `cosmic fix` declares read-only each field the tree never writes after
     creation, and the rest take a local copy.

   three restrictions come with it, each its own PR before or alongside it:
   - R2, effectively-final captures (done, #3067). a function
     literal may read but not assign a local declared outside it. the tree
     is migrated at every site, tests included. this makes the closure-assigns-a-narrowed-local
     class impossible, and with it step 5's pending-function machinery for
     assignments.
   - R3, `goto` only as `continue` (done, #3066): a forward jump to a label
     at the end of the enclosing loop body.
   - rule 11, as above.

   rejected: narrowing only `<const>` and stable bindings (R1(b)), at 1,070
   error lines in 203 files. assignment already drops a local's fact
   precisely, and R2 removes the closure case. locals narrow fully; only
   heap places are restricted.
7b. **the seed is the pinned release.** the next step, before 7a's PR 3.
   - a script that [`bin/cosmic-bootstrap`] runs on the pinned release
     compiles `checker/*.tl` and `checker/stdlib.d.tl` to Lua for the 5.5
     runtime, as the release's own build compiles its checker, and boot
     loads that in place of running `tl.lua` through the bridge. if the
     pinned release cannot yet do this, the step starts with the change
     that lets it and the pin move that carries it.
   - `vendor/tl/` goes, except the license and notice, which move beside
     the checker and stay in the bill of materials. the bridge's faked
     `io`, `os` and `package` and its own compile cache go with it.
   - boot and the tool's self-rebuild compile the checker by one path,
     keyed the same way, so a rebuild no longer reconciles two compilers'
     identities.
   - [`build/compiler_test.tl`] checks the fixed point: the checker the
     seed compiles compiles its own source, and that checker compiles it
     again to the same Lua. its pinned type-error count only falls.
   - the checker's own source may then use `name?: T`, `: never` and the
     strict rules, one pin move after each lands.
8. **nil (rules 1, 2, 3, 5, 6 and 14).** report mode first; the
   declarations audit; then migration PRs one directory at a time, tests
   with their modules, the checker's own source last; then one change that
   turns the rules on. `never` becomes the bottom type (rule 6) in the
   type representation as nil leaves it, before the tree migrates. every
   directory outside `checker/` is already honest about nil as far as
   `--check-types` can see (#3028 to #3031, #3043, #3045, #3046). several
   PRs remain.
9. **classes (rules 10 and 17).** report mode counts the `setmetatable`
   calls and the metamethods rule 10 has no form for. a migration in
   `cosmic fix` turns the class pattern (`setmetatable(o, R)` with
   `R.__index = R`) into a literal typed as the class. the tree moves its
   `__call`, `__len`, `__eq` and arithmetic metamethods to methods, and its
   `__mode` tables to the standard library's weak tables. then the
   compiler writes each class's metatable, and `setmetatable`,
   `getmetatable`, `rawset` and `rawget` leave the surface a program sees
   (rule 18).
10. **the new checker.** written for the language steps 7a to 9 leave, not
    forked from `checker/tl.tl`; it may start from that file's lexer and
    parser, which already answer malformed input with errors. a sketch,
    not a design:
    - one pass builds a control-flow graph that narrowing and definite
      assignment both read, with facts keyed by binding; there is no
      metamethod or "runs code" reasoning, because rules 4, 10 and 17 left
      nothing for it to decide.
    - one subtype relation with its variance; nil and `never` where rules
      1 and 6 put them.
    - each error a code, its places and a doc page, from the first PR.
    - it emits for the tree's own VM only, and may write bytecode
      directly where that removes the Lua-text round trip.
    - a module's exported types hashed apart from its body, so a module
      that requires it is rechecked only when that hash moves.
    - it runs beside the forked checker until the verdict harness (#3070)
      shows no unexplained difference over the tree, the fuzz corpora and
      dumped fuzz programs; the fuzz soundness property and checked
      narrowing run against it; it compiles itself to a fixed point. then
      it replaces `checker/` in one change, and the seed moves to the
      release that carries it.
11. **variance, views and receivers (rules 7 and 13),** in the new
    checker. `table.concat` and the three option signatures take views
    first.
12. **narrowing declarations and tagged unions (rules 8 and 9),** in the
    new checker, each with its count in report mode first.
13. **`or` and `and`, casts and parameters (rules 12, 15 and 16),** in the
    new checker. most of the tree's casts exist to get past nil,
    narrowing and variance, so after step 8 most are deleted rather than
    justified.
14. **the rest of the runtime (rule 18):** string coercion out of the VM,
    no text `load` or `string.dump` for a program, no `__gc` or `__mode`
    on a program's tables, and a fixed `_G`. it depends on no checker step
    after 9, and each part lands when its report-mode count is migrated.

every checker step follows the review practice in "decisions", with two
independent review rounds per PR.

## open questions


- **the narrowing declaration's syntax.** it must read in a `.d.tl` and in
  `cosmic docs` as plainly as a return type does.
- **variadic generics.** whether `pcall`, `xpcall` and the coroutine
  functions earn them, or stay special.
- **tests.** whether test files get a helper for an index they have
  already asserted the length of, since about 4,613 array reads are in
  tests and a nil there already fails the test.
- **R2's out-param pattern in tests.** whether it is rewritten with return
  values or a one-field table, and a small shared helper only if that is
  idiomatic.
- **strict-record checks in debug runs.** whether they come before or
  after step 7a.
- **dense arrays.** what rule 3 costs the tree, measured in report mode
  before step 8.
- **the seed's interface.** what the pinned release offers the script that
  compiles the checker (a verb, or a module the script requires), and
  whether its type errors in the checker's source are reported, as the
  self-compile test counts them now, or refused.
- **the new checker's grammar.** whether it adds `continue` in place of
  `goto`, an `if` expression in place of the `and`/`or` ternary, and a
  `match` over a tagged union; and whether `as` goes entirely, a checked
  `is` (or `must(x is T)`) taking its place.
- **what a class may declare.** whether `__tostring` stays a metamethod
  or becomes a method `tostring` calls, and whether `__eq` earns a place
  beside `__close`.
- **bytecode.** whether the new checker emits bytecode for the patched
  VM directly, keeping line and name information for messages and
  coverage, or keeps emitting Lua source; and which VM entry points or
  opcodes the compiler earns (a class constructor, integer-only
  arithmetic where the types are `integer`).
- **the interface hash.** what a module's exported types hash over (the
  standard library's stubs already compute it) and whether module keys
  read it in the forked checker before step 10.

## what the first steps taught

- **the checker was buggier than expected.** about 10% of random narrowing
  programs crashed the checker on main. `local x: integer | nil, y = 1, 2`
  crashed it, an else-branch assignment was missed in loops (`ipairs` over
  a nil hole), and the self-compile test had checked nothing. only
  throwaway differential runs and random-program generators found these,
  hence step 6.
- **a restriction can over-refuse.** the syntactic loop rule refused common
  code that main accepted, and became a typed analysis. every review found
  at least one blocking issue, often visible only by testing against main.
- **run-time metatables are a hole,** hence rules 10 and 17.
- **migrating a forked checker in place costs more than the language it
  checks.** shadow mode had to copy the old narrowing's quirks to agree
  with it, and most of the fuzzer's finds were keyed by name or scope
  bookkeeping no new design would have. hence the new checker (step 10).
- **the pinned CI driver lags the tree,** so `ci/` cannot use a new API
  until the pin moves (step 7).
- **a change can expose a bug beside it.** a deadline-rounding bug in the
  core's C was found when the row accessors (#3051) were knocked out of
  the merge queue (#3055).

[strict-teal-7a.md]: strict-teal-7a.md
[`bin/cosmic-bootstrap`]: ../../bin/cosmic-bootstrap
[`bin/vendor`]: ../../bin/vendor
[`bin/zig`]: ../../bin/zig
[`build.fuzz`]: ../../build/fuzz/init.tl
[`build/compiler_test.tl`]: ../../build/compiler_test.tl
[`build/identity.tl`]: ../../build/identity.tl
[`build/teal.tl`]: ../../build/teal.tl
[`build/teal_test.tl`]: ../../build/teal_test.tl
[`ci/cosmic-driver.pin`]: ../../ci/cosmic-driver.pin
[`cosmic.shape`]: ../../cosmic/shape.tl
[`cosmic.stream`]: ../../cosmic/stream.tl
[`cosmic.sys`]: ../../core/syscalls.h
[`Json.array`]: ../../cosmic/json.tl
[`Sqlite.rows`]: ../../cosmic/sqlite.tl

[`core/surface.c`]: ../../core/surface.c
