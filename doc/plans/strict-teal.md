# strict teal

this document is the plan for the language cosmic checks: a strict subset of
Teal, plus the extensions that correct typing needs and Teal cannot express.
it states the stance, the rules the checker is to hold, the order the work
lands in, and the questions still open. once a step merges its section is
marked done; once every step is done the rules live in
[design.md](../design.md)'s teal section and this file is deleted, as
[roadmap.md](../roadmap.md) deletes what ships.

it serves the first promise and the fourth principle in
[design.md](../design.md): types never lie, and the type layer has no escape
hatch.

## why the checker has many small gaps

`patch/tl/` carries 167 patches to upstream Teal 0.24.8. most of them close
one instance of a gap whose cause stays in place, so the next instance
appears where no patch has reached. five causes account for most of them.

- **nil is a member of every type.** upstream's subtype table states
  `["nil"] = { ["*"] = compare_true }`. patches 50c to 50f, 51b, 51c, 51f,
  52a and 52b refuse a value that may be nil at one use site each: an
  operand, a `for` bound, a `table.insert` argument, a literal's omitted
  field. the sites with no patch accept it: an argument for a parameter of
  type `T`, a `return` from a function declared to return `T`, a write to a
  record field of type `T`, and a `local x: T` declared without a value. a
  nil that passes one of those reads as `T` from then on.
- **narrowing is a set of facts on lexical scopes.** upstream's facts
  (truthy, equal, is, and their `not`, `and` and `or`) widen a variable
  only when it is assigned. each narrowing form is a patch of its own (02,
  03, 07 to 14, 35, 36, 51a), and so is each statement that ends a block
  (21 to 25, 39, 43f, 43g). no fact is dropped when a call or a closure can
  change the value it is about: inside `if r.n then clear() print(r.n + 1)
  end`, `r.n` stays narrowed when `clear` sets it to nil.
- **one comparison with no notion of variance.** `is_a` compares a nested
  type in the same direction as its container, so `{integer}` is a
  `{number}` and a callee given one can insert a float. the 48 patches fix
  function parameters, returns and field comparisons one relation at a
  time, with an exemption for a method's receiver (48e); 43e5 carries
  `: never` through nested types the same way. arrays, maps and
  interface fields are still covariant.
- **`: never` is a flag, because nil holds the bottom of the lattice.** a
  real bottom type would make `function(): never` a subtype of
  `function(): T` by ordinary return covariance. as a flag it took 37
  patches (43a1 to 43h5) to keep it sound.
- **the type language cannot describe the standard library.** `assert`,
  `type`, `coroutine.wrap` and `setmetatable` are special cases in the
  checker (15 to 19, 36, 45, 47), each because its declaration cannot say
  what the call does: `assert` and `type` narrow their argument, `assert`
  answers it without nil, `coroutine.wrap` answers a type made from its
  argument's. a helper of the tree's own that narrows, such as a
  [`cosmic.shape`] validator, cannot say it either. `: never` (44a) is the
  one such typing a declaration gained, and it lets `error` be declared
  rather than special.

the patch format adds a sixth. a patch finds and replaces text in one
15,000-line file, so a change of one idea lands as dozens of local hunks
(43 is 37 patches), and a change to a foundation, such as nil's place in
the subtype table, touches more places than a patch stack can carry. the
hints in [`build/teal.tl`] match on the text of the checker's messages
for the same reason: the checker cannot be given a structured error
without another patch.

## the stance

- **a subset, plus named extensions.** a restriction refuses a program
  upstream Teal accepts. an extension adds syntax or a typing upstream
  lacks, and is admitted only where the typing it gives cannot be written
  otherwise. the compiler emits plain Lua for the 5.5 runtime either way.
- **a category is closed by a rule, never by sites.** each rule is stated
  once in the checker: one subtype relation with its variance, one flow
  analysis. a change that adds a check for one more syntactic form is the
  sign that a rule is missing.
- **a restriction is preferred to an analysis.** where soundness needs
  either a cleverer checker or a narrower language, the narrower language
  wins when the idiom it costs has a plain rewrite. narrowing a field and
  then calling a function is refused rather than tracked through the
  callee: copy the field to a local first.
- **strict is the only mode.** a per-module switch exists while a rule is
  migrated through the tree and is deleted when the migration ends. no
  module keeps the lax mode, which would be an escape hatch.

## decisions

- **the checker is the tree's own source.** `tl.tl` moves out of
  `vendor/tl/` into the tree, with the patches applied, and is edited
  directly from then on. the patches are not proposed upstream and are
  not rebased onto a newer release, so the patch format buys nothing and
  costs every foundational change. `vendor/tl/` keeps `tl.lua` alone,
  unedited, as the seed: it compiles the tree's checker at boot,
  and [`build/compiler_test.tl`] still holds the checker to compiling its
  own source to exactly itself. the seed means the checker's own source is
  written in what upstream 0.24.8 accepts. the subset is, by being a
  subset; the extensions are not, so the checker's source uses none of
  them.
- **the rules are tested against programs that must be refused.** every
  hole found becomes a refused program in [`build/teal_test.tl`], which
  already pins today's known holes (`test_as_and_is_forge_a_never_function`,
  `test_a_function_index_serves_any`,
  `test_a_callback_field_with_a_record_parameter_is_the_known_limit`). a
  step that closes a hole flips its pin from accepted to refused.
- **a test run checks the types it was promised.** under the test runner,
  the compiler emits a run-time check of each declared parameter, return
  and record field write against the declared type's nil-ness and
  primitive kind (records are erased, so a record is checked as a table).
  a check that fails during `cosmic test` is a hole in the checker, found
  without anyone writing the probe. it is never emitted into a built
  executable.

## the rules

each rule is a restriction (R) or an extension (E). the step that lands it
is in the next section.

1. **nil is a type of its own (R).** `T` admits no nil. `T | nil` and a
   `name?: T` field are the only ways to admit it. an argument, a return,
   a field write and an initializer are checked by the same subtype
   relation as every other value, so the use-site rules of patches 50c to
   50f, 51b, 51c, 51f, 52a and 52b become that relation. the standard library's declarations answer
   `T | nil` wherever the call can: `string.match`, `table.remove`,
   `select`, an element read from `...`, and the rest a review of its
   declarations finds.
2. **indexing a map answers `T | nil` (R).** `m[k]` and `m.k` on a
   `{K:V}` are `V | nil`. what an array index answers is an open question
   below.
3. **a local is assigned before it is read (R).** `local x: T` with no
   value is legal only where every path assigns `x` before its first read.
4. **one flow analysis decides narrowing and reachability.** narrowing
   applies to places: a local, or a field path from a local (`r.a.b`). a
   guard narrows a place. an assignment to a place, or to a prefix of it,
   drops what was known of it. a call drops what was known of every field
   path, and of every local a closure assigns. a statement that has no
   successor (`return`, `break`, `goto`, a loop that never ends, a call of
   a `: never` function) ends its block. this replaces upstream's facts
   and the per-form narrowing and block-ending patches. it narrows what
   they narrow (R for what it drops after a call).
5. **`never` is the bottom type (E).** with nil out of the bottom of the
   lattice, `never` takes it, and a function declared `: never` is a
   subtype of every function with its parameters by return covariance.
6. **each type constructor has one variance (R).** a function is
   contravariant in its parameters and covariant in its returns. a mutable
   array, map or field is invariant. a record is compared by name, as now.
   whether a covariant read-only view exists is an open question below.
7. **a declaration can narrow (E).** a function type may say that it
   narrows an argument to a type when it returns true, or that it returns
   only when an argument is not nil or false. `assert` and the
   [`cosmic.shape`] validators are then ordinary declarations, and the
   special cases of patches 15 to 19 go. `type` stays special, but answers
   through the same narrowing.
8. **a union of records is told apart by a tag (E).** a union of records
   is legal when each member has the same field typed by a distinct
   single-member enum, and comparing that field with a literal narrows the
   union. `v is R` for a record `R` is refused (R) wherever `v` is not
   already an `R`: Lua erases the record, so `is` cannot tell it from
   another table. this widens the lint [design.md](../design.md)'s teal
   section plans, which refuses it on an `any` or a union of records.
9. **a record with methods comes from its metatable (R).** a record that
   declares a method is a class: a value of it is made by `setmetatable`
   with its `metatable<R>`, and a table literal typed as it is refused,
   because the literal carries none of its methods. each method the record
   declares is defined in its module.
10. **casts are confined (R).** as [design.md](../design.md)'s teal section
    states: `x as T` only from `any`, from a userdata record declared in a
    `.d.tl`, or from the enclosing generic's type variable.
11. **a parameter is annotated (R).** an unannotated parameter is an
    error, never an implicit `any`.
12. **a method names its receiver (R).** interfaces declare methods with
    `self: I`, and the receiver exemption of patch 48e goes, with the hole
    it brings (a callback field `function(Event)` taking a
    `function(KeyEvent)`). [roadmap.md](../roadmap.md) holds the item for
    [`cosmic.stream`].

`any` stays as it is: it is legal only where untrusted data enters, and the
checker already refuses to assign it, call it or index it.

## the steps, in order

each step is one or more PRs that follow [doc/contributing.md](../contributing.md):
each stands alone, passes CI, and has a test that fails without it. a step
that changes what is refused migrates the tree in the same PR or behind the
migration switch, never leaving main red.

1. **own the checker.** move the patched `tl.tl` into the tree, seed it
   from [`vendor/tl/tl.lua`], drop `tl.tl` from `vendor/tl/`'s keep list,
   and delete `patch/tl/`. no change to what is accepted or refused.
   [design.md](../design.md)'s teal section, which reads the standard
   library's declarations from [`vendor/tl/tl.tl`], names the new place. the patches' notes become comments where they
   still say something the code does not.
2. **the run-time type checks in test runs.** land the emitted checks and
   record what the tree's own test run trips. this measures the holes
   before the rules close them.
3. **the flow analysis (rule 4).** replace the fact kinds with the
   analysis. it accepts what the tree accepts today, except a narrowing a
   call or a closure invalidates, which the tree rewrites with a local.
4. **definite assignment (rule 3).**
5. **nil as a type of its own (rules 1, 2 and 5).** behind the migration
   switch, module by module, the standard library's declarations first and
   the checker's own source last; the switch is deleted when the last
   module moves. several PRs.
6. **variance (rule 6).**
7. **narrowing declarations (rule 7).**
8. **tagged unions and classes (rules 8 and 9).**
9. **casts, parameters and receivers (rules 10, 11 and 12).** most of the
   tree's casts exist to get past nil, narrowing and variance, so after
   steps 3 to 6 most are deleted rather than justified.

## open questions

- **where the checker lives.** a module of its own under `build/`, split by
  concern (parser, subtype relation, flow, declarations), or one file
  first and split later.
- **what an array index answers.** `t[i]` as `T | nil` is sound and noisy;
  `T` is quiet and is the hole most nil escapes go through. the middle
  course is `T | nil` everywhere, with `t[i]` as `T` inside
  `for i = 1, #t` when the loop does not assign `t`. measure each on the
  tree before choosing.
- **how a function reads a container covariantly.** with invariant arrays,
  `sum(xs: {number})` refuses an `{integer}`. a read-only view
  (`xs: readonly {number}`) is an extension; a generic with a constraint
  is not, but Teal constrains a type variable only by an interface today.
- **the syntax of a narrowing declaration.** it must read in a `.d.tl` and
  in `cosmic docs` as plainly as a return type does.
- **whether a cosmic program must stay valid upstream Teal.** `: never`,
  `name?: T` and digit separators already make it not; the checker's own
  source is the one place it must (the seed).

[`build/compiler_test.tl`]: ../../build/compiler_test.tl
[`build/teal.tl`]: ../../build/teal.tl
[`build/teal_test.tl`]: ../../build/teal_test.tl
[`cosmic.shape`]: ../../cosmic/shape.tl
[`cosmic.stream`]: ../../cosmic/stream.tl
[`vendor/tl/tl.lua`]: ../../vendor/tl/tl.lua
[`vendor/tl/tl.tl`]: ../../vendor/tl/tl.tl
