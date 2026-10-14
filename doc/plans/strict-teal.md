# strict teal

this document is the plan for the language cosmic checks: Teal held to
stricter rules, plus the extensions that correct typing needs and Teal
cannot express. it is a subset of Teal in what it refuses and a superset
in what it adds. it states the stance, the rules the checker is to hold,
what the tree measured against them, the order the work lands in, and the
questions still open. once a step merges its section is marked done, and
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
construction. a patch finds and replaces text in one
15,000-line file, so a change of one idea lands as dozens of local hunks,
and a change to a foundation, such as nil's place in the subtype table,
touches more places than a patch stack can carry. the hints in
[`build/teal.tl`] match on the text of the checker's messages, about 42
patterns, for the same reason: the checker cannot be given a structured
error without another patch.

## the stance

- **restrictions, plus named extensions.** a restriction refuses a program
  upstream Teal accepts. an extension adds syntax or a typing upstream
  lacks, and is admitted only where the typing it gives cannot be written
  otherwise. a shorter spelling of a type the language already has is not
  an extension: `T?` for `T | nil` is a spelling. a cosmic program need not
  be valid upstream Teal. the compiler emits plain Lua for the 5.5 runtime
  either way.
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
  dropped it.
- **strict is the only mode.** a rule moves through the tree in report
  mode, then lands for every module at once. no module keeps a lax mode,
  which would be an escape hatch.

## decisions

- **the checker is the tree's own source, split by concern as each
  concern lands.** it moves out of `vendor/tl/` into `checker/`, outside
  the module closure it compiles, and is edited directly from then on. a
  step that gives a concern its rule gives it a module of its own
  (`checker/flow.tl`, `checker/narrowing.tl`), so no step exists only to
  split. the patches are not proposed upstream and are not
  rebased onto a newer release, so the patch format buys nothing and costs
  every foundational change.
- **the seed is upstream's `tl.lua` until the stage-2 seed (step 11).**
  `vendor/tl/` keeps `tl.lua` alone, unedited: it compiles the checker at
  boot, and [`build/compiler_test.tl`] holds the checker to compiling its
  own source to exactly itself. so the checker's own source is valid
  upstream 0.24.8: it obeys the restrictions, which upstream accepts, and
  uses none of the extensions. that already costs it: it cannot write
  `name?: T` or `: never`, and a cast stands where `never` would. seeding from the release [`ci/cosmic-driver.pin`] names
  would not let the checker use an extension in the change that adds it
  (the pin lags the tree), and would make a binary the root of trust for
  the language, with no way back from a release whose checker is broken.
  when the checker wants an extension, one deliberate change moves its
  seed to a compiler that accepts it (step 11).
- **declarations are the trust boundary.** a `.d.tl` signature, and a
  narrowing declaration (rule 8), is the only typing the checker takes
  without proof. the standard library's Lua declarations move out of the
  checker into `.d.tl` files, so auditing them changes no checker logic.
  a declaration answers `any` only at a named untrusted-data entry point:
  `load`, `require` of an untyped module, `string.unpack`, the raw `io`
  reads, `getmetatable`, and the [`cosmic.sys`] bindings.
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
- **the runtime changes only where normal runs pay nothing.** the
  guarantees are type-level restrictions, plus Lua VM changes only where
  they cost a normal run nothing. a locked metatable reuses `__metatable`,
  so it is free. the strict-record and frozen-table checks run only in
  debug and test runs, as `--check-types` does. there is no always-on write
  check.
- **type-level syntax is allowed; statement and expression syntax is not.**
  an annotation that is erased when compiling to Lua may be added: a
  `readonly {T}` view (rule 7, variance) and a guard signature (rule 8,
  narrowing declarations). the Lua a file compiles to is unchanged by it.
  no new statement or expression form is added, no `pure` annotation and no
  new metatable construct. purity, if it is ever needed, is inferred and
  defaults to impure, and the standard library's purity lives in
  `checker/stdlib.d.tl`. `<const>` is Lua syntax and stays.
- **what the claim excludes.** types do not track integer overflow,
  division by zero, or code a finalizer (`__gc`) runs. each is a run-time
  fault, not a type that lied.

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
   index out of range rather than trapping. two refinements answer `T`, and
   only these:
   - an index place narrows like a field path (rule 4): `t[k]`, with `t` a
     place and `k` a literal or a local that is never reassigned, is
     narrowed by a nil or truthiness test and by an assignment
     `t[k] = v`.
   - in `for i = a, #t` (or `#t - d`) and `for i = #t, 1, -1`, with `a` a
     literal of at least 1, `t[i]` (and `t[i + c]` for `c <= d`) is `T`
     when `t` is a local the body neither assigns nor passes to a call.

   a tuple type indexed by a literal in range is its member's type, and out
   of range is refused. length facts (`#t > 0` giving `t[1]`) are not
   tracked. a further pattern waits for a measured need.
3. **an array is dense (R).** `{T | nil}` is refused as an array type: `#`,
   `ipairs` and `table.insert` are defined on a sequence, and a hole makes
   each unreliable. sparse data is a map, `{integer:T}`, and `#` on a map
   is refused.
4. **one flow analysis decides narrowing and reachability.**
   - a place is a local, a field path from a local (`r.a.b`), or an index
     place (rule 2).
   - a guard is a truthiness test, `== nil` and `~= nil`, `==` with a
     literal, `is`, `type(x) == "..."`, their `not`, `and` and `or`, a
     narrowing call (rule 8), and a branch that ends its block.
   - an assignment to a place, or to a prefix of it, drops what was known
     of it. a write to a field `.f` through any base drops every narrowed
     path ending in `.f`, and a write to any index drops every index place,
     because another reference may name the same table.
   - a call-like expression drops what was known of every field path and
     index place, and of every local that any function literal in its
     scope assigns. a call is call-like, and so is an operator, index or
     comparison on a record, interface, userdata or `any`, which can run a
     metamethod. on a string, a number or a plain array or map, an operator
     is not call-like. a local that no closure assigns stays narrowed
     across a call.
   - a statement with no successor (`return`, `break`, a `goto` out of the
     block, a loop with no exit, a call of a `: never` function) ends its
     block. a `goto continue` to a label in the same loop does not end the
     path.

   this replaces upstream's facts and the per-form narrowing and
   block-ending patches. step 7a gives it the form described there.
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
   to primitive types, enums, `nil`, and function and table kinds; `v is R`
   for a record `R` is refused (R), since Lua erases the record. the hint
   names a tag field or a [`cosmic.shape`] validator.
10. **a record with methods comes from its metatable (R).** a method is a
    `function R:name()` declaration or a field whose function names its
    receiver. a record that declares one is a class: a value of it is made
    by `setmetatable` with its `metatable<R>`, whose table is checked as
    `R` without its methods, as it is now. a table literal typed as a
    class is refused, because it carries none of the methods. each method
    the class declares is defined in its module. a function `__index`
    serves one declared type that every field read through it satisfies.
    a metamethod is declared in the record, with its signature, or the
    operator is refused on it, and a record with `__newindex` narrows no
    field.
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
    `.d.tl`, or from the enclosing generic's type variable. the rule waits
    only on the stage-2 seed (step 11): 230 of the 290 non-test casts not
    from `any` are in the checker's own source.
16. **a parameter is annotated (R).** a parameter of a function declaration,
    or of a function literal with no expected function type, has a type. a
    literal passed where a function type is expected takes its parameter
    types from it, as patch 37 does now, so a `table.sort` comparator needs
    none.
17. **a value dispatches only through the metamethods its type declares
    (R).** the flow analysis (rule 4) treats an operator, index or
    comparison as call-like only on a type whose record declares the
    metamethod. a metatable attached at run time would add dispatch no type
    shows. so `setmetatable` attaches a metamethod only to a record type
    that declares it, with the declared signature, and refuses a metatable
    that carries any other. the one allowance besides those metamethods is
    `__index` set to the record's own method table. [roadmap.md](../roadmap.md) holds the item.

`any` stays as it is: it is legal only where untrusted data enters, and the
checker already refuses to assign it, call it or index it.

rejected, so nobody proposes them again: a non-nil assertion `x!` (an
escape hatch; `assert(x)` says why), `a?.b` (the tree's field paths are
almost all non-nil), a `??` operator (rule 12 refuses the hazard
instead), bounded generics over primitive types, declaration-site variance
(`record Box<out T>`), and read-only record fields. each waits for a
measured need.

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
- **narrowing after a call (rule 4).** of about 1,080 guards on a field
  path, at most 76 call a function in the guarded body and read the path
  again (heuristic).
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
  those stay honest only once the static nil rule (step 12) lands.
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
7a. **narrowing by construction (rule 4).** it lands before variance, so
   the flow analysis every later rule reads is the sound one. the holes the
   fuzzer found in 4c (the `or` reading, closures in inner blocks, function
   bodies keeping outer facts, `local x = x` copies) are fixed (done,
   #3065). the design is in [strict-teal-7a.md], whose PRs 0 to 2 are
   done (#3070, #3069, #3074); shadow mode found four old-narrowing bugs,
   fixed in #3071, #3072, #3073 and #3075. in short:
   - declared types are never mutated. facts live in an immutable map from
     place to type, carried along a small control-flow graph, and joins
     happen in one place. the default is pessimistic: a fact survives only
     what is known not to change its place.
   - it retires `specialize_var` and the scope-marker bookkeeping
     (`narrow`, `widen` and `localizing` entries, `widened_from`).
   - field facts keep 4c's rule: a call or a write drops them. a local's
     fact is dropped precisely by assignment.
   - field narrowing stays, because restricting it would cost every field
     read.

   three restrictions come with it, each its own PR before or alongside it:
   - R2, effectively-final captures (done, #3067). a function
     literal may read but not assign a local declared outside it. the tree
     is migrated at every site, tests included. this makes the closure-assigns-a-narrowed-local
     class impossible, and with it step 5's pending-function machinery for
     assignments.
   - R3, `goto` only as `continue` (done, #3066): a forward jump to a label
     at the end of the enclosing loop body.
   - rule 17 adjusted as stated there.

   rejected: narrowing only `<const>` and stable bindings (R1(b)), at 1,070
   error lines in 203 files. assignment already drops a local's fact
   precisely, and R2 removes the closure case.
8. **variance, views and receivers (rules 7 and 13).** `table.concat` and
   the three option signatures take views first.
9. **`setmetatable` and declared metamethods (rule 17),** after variance,
   since a metatable is typed as a record. its report mode counts the
   `setmetatable` calls that attach an undeclared metamethod.
10. **never as the bottom type (rule 6),** once nil leaves the bottom of
    the lattice in the type representation, before the tree migrates.
11. **the stage-2 seed, before the checker migrates for nil.** the
    checker's own source moves to a seed compiler that accepts the
    extensions (`?:`, `never`, the strict rules), so the checker is held to
    the rules it enforces. a sketch, not a design:
    - the seed is a compiled checker built from the tree and committed as
      a vendored artifact, in place of upstream's `tl.lua`. the checker
      compiles its own source with it, and the result must equal itself
      (the fixed point of [`build/compiler_test.tl`]).
    - a change to the checker that the seed cannot compile first moves the
      seed in a change of its own.
12. **nil (rules 1, 2, 3 and 14).** report mode first; the declarations
    audit; then migration PRs one directory at a time, tests with their
    modules, the checker's own source last, after step 11; then one change
    that turns the rules on. every directory outside `checker/` is already
    honest about nil as far as `--check-types` can see (#3028 to #3031,
    #3043, #3045, #3046). several PRs remain.
13. **narrowing declarations, tagged unions and classes (rules 8, 9 and
    10),** each with its count in report mode first.
14. **records and maps, `or` and `and`, casts and parameters (rules 11,
    12, 15 and 16).** rule 15 waits only on step 11. most of the tree's casts exist to get past nil,
    narrowing and variance, so after step 12 most are deleted rather than
    justified.

every checker step follows the review practice in "decisions".

## open questions

- **the oracles' order.** whether the widened fuzz generator and checked
  narrowing both land before step 7a's PR 3 (proposed), only the fuzz, or
  in the order the design gives.

- **the checker's root.** its directory name, and how the module scanner
  tells it from a module of the tree.
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
  before step 12.
- **the stage-2 seed.** how it is produced and kept reproducible, so a
  broken seed has a way back; whether it is committed or built from an
  earlier release; and how the fixed-point test changes when the seed is
  no longer upstream's.

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
- **run-time metatables are a hole,** hence rule 17.
- **the pinned CI driver lags the tree,** so `ci/` cannot use a new API
  until the pin moves (step 7).
- **a change can expose a bug beside it.** a deadline-rounding bug in the
  core's C was found when the row accessors (#3051) were knocked out of
  the merge queue (#3055).

[strict-teal-7a.md]: strict-teal-7a.md
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
