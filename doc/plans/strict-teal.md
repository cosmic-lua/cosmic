# strict teal

this document is the plan for the language cosmic checks. it starts from
Teal's syntax and compiles to Lua 5.5, and it is cosmic's own: where Teal
or a Lua idiom costs soundness, simplicity or speed, the language breaks
with it. this tree is the only cosmic code there is, so a break is paid by
rewriting the tree in the change that makes it, with no compatibility
mode, deprecation or migration tool for anyone else. it states the
stance, the rules the checker is to hold, how the language rests on the
database, what the tree measured, the order the work lands in, and the
questions still open. rules, decisions and steps go by their names, never
by a number.

the work runs on two tracks from now. the checker forked from Teal is
taken as far as three foundations: [the pinned-release seed] compiles it
in place of upstream's `tl.lua`, [narrowing by construction] narrows only
what nothing else can change, and [compiler-written classes] leave no
metatable but the compiler's. beside it, [the new checker] is written for
the smaller language those leave. it replaces the fork once it gives the
fork's verdicts, and then the rules the fork never holds land in it, [nil
out of every type] first.

once a step merges its section is marked done, and
[design.md](../design.md)'s teal section states each rule as it lands.
once every step is done this file is deleted, as
[roadmap.md](../roadmap.md) deletes what ships.

it serves the first promise and the fourth principle in
[design.md](../design.md): types never lie, and the type layer has no escape
hatch.

## why the checker has many small gaps

`patch/tl/` carried 167 patch files against upstream Teal 0.24.8. most of
them closed one instance of a gap whose cause stayed in place, so the next
instance appeared where no patch had reached. these causes account for
most of them.

- **nil is a member of every type.** upstream's subtype table states
  `["nil"] = { ["*"] = compare_true }`. a patch each refuses a value that
  may be nil at one use site: an operand, a `for` bound, a `table.insert`
  argument, a literal's omitted field. the sites with no patch accept it:
  an argument for a parameter of type `T`, a `return` from a function
  declared to return `T`, a write to a record field of type `T`, and a
  `local x: T` declared without a value. a nil that passes one of those
  reads as `T` from then on. standard library declarations that answer `T`
  where the call can answer nil (`string.match`, `table.remove`, `rawget`,
  `select`) feed it more.
- **narrowing is a set of facts on lexical scopes.** upstream's facts
  (truthy, equal, is, and their `not`, `and` and `or`) widen a variable
  only when it is assigned. each narrowing form is a patch of its own, and
  so is each statement that ends a block. no fact is dropped when a call, a
  closure or another reference to the same table can change the value it
  is about. both of these are accepted and fail at run time:

  ```text
  if r.n then clear() print(r.n + 1) end         -- clear sets r.n = nil
  if r.n then local c = r c.n = nil print(r.n + 1) end
  ```

- **one comparison with no notion of variance.** `is_a` compares a nested
  type in the same direction as its container, so `{integer}` is a
  `{number}` and a callee given one can store a float in it. the variance
  patches fix function parameters, returns and field comparisons one
  relation at a time, with an exemption for a method's receiver, and carry
  `: never` through nested types the same way. arrays, maps and interface
  fields are still covariant.
- **`: never` is a flag, because nil holds the bottom of the lattice.** a
  real bottom type would make `function(): never` a subtype of
  `function(): T` by ordinary return covariance. as a flag it took 37
  patch files to keep it sound.
- **the type language cannot describe the standard library.** `assert`,
  `type`, `coroutine.wrap` and `setmetatable` are special cases in the
  checker, each because its declaration cannot say what the call does:
  `assert` and `type` narrow their argument, `assert` answers it without
  nil, `coroutine.wrap` answers a type made from its argument's. a helper
  of the tree's own that narrows, such as a [`cosmic.shape`] validator,
  cannot say it either. `: never` is the one such typing a declaration
  gained, and it lets `error` be declared rather than special.

## why the narrowing holes keep coming

[checker fuzzing] keeps finding holes in narrowing, each closed by a local
fix, and the cause sits in upstream's design, not in any one fix.

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

[narrowing by construction] replaces the first three with a design that is
sound by construction. the fourth is answered by narrowing only what no
other code can change: a local, which only its own function assigns once
[captures are read-only], and a read-only field, which nothing assigns
after its table is made. a call then drops no fact, and no list of what
runs code is kept for narrowing. the patch format made each of these
worse: a patch finds and replaces text in one 15,000-line file, so a change
of one idea lands as dozens of local hunks, and a change to a foundation,
such as nil's place in the subtype table, touches more places than a patch
stack can carry.

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
  it emits (a class's metatable, [compiler-written classes]), where that is
  the price of a sound rule.
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
- **every error says how to fix it.** this holds for every error the
  checker and compiler give, not only a new rule's. an error is
  structured (a code and the places involved, not text a hint re-parses)
  and says what is wrong, where, why the language refuses it, and the
  change that fixes it, written against the program's own names: "copy
  `r.n` to a local: `local n = r.n if n then ... end`", not "cannot
  narrow a field". where two places are involved it names both, as a
  refusal of a narrowing names the assignment that dropped it, and a nil
  error names the call that answered nil and where it is declared. the fix
  is pinned with the error in [`build/teal_test.tl`], as
  `test_a_value_that_may_be_nil_is_told_the_check` pins today's, and an
  error whose fix the checker cannot state is a bug in the error.
- **strict is the only mode.** a rule lands for every module at once, in
  the change that rewrites the tree to obey it. no module keeps a lax
  mode, which would be an escape hatch. a count over the tree, taken
  first, sizes the change; it is a measurement, not a phase the tree
  passes through.
- **names, not numbers.** a rule, a decision, a step and a part of a step
  is named for what it does, and is referred to by that name.

## decisions

- **the checker is the tree's own source, split by concern as each
  concern lands, until the new checker replaces it.** it lives in
  `checker/`, outside the module closure it compiles, and is edited
  directly. a step that gives a concern its rule gives it a module of its
  own (`checker/flow.tl`, `checker/narrowing.tl`, `checker/facts.tl`), so
  no step exists only to split.
- **the seed is the pinned release.** the release [`ci/cosmic-driver.pin`]
  names compiles the checker's source to Lua, and boot loads that in place
  of upstream's `tl.lua` ([the pinned-release seed]). `vendor/tl/` goes,
  except for the license and notice the checker inherits, and so do the
  stand-ins for `io`, `os` and `package` that `tl.lua` needs. the pin is
  already the root of trust for [`bin/zig`], [`bin/vendor`] and the
  scripts they run, so it adds no root; a seed committed to the tree would
  add one beside the pin and the pinned Zig. the checker's own source may
  use what the pinned release's checker accepts: a rule or a syntax lands
  in the tree first and reaches the checker's source one pin move later,
  as in any compiler that compiles itself, while the rest of the tree uses
  it at once. the way back from a release whose checker is broken is the
  previous pin, a one-line revert, and `COSMIC_BOOTSTRAP` runs any other
  cosmic in its place. the fixed point of [`build/compiler_test.tl`] keeps
  a broken checker from being released.
- **a new checker for the smaller language, started now.** with the three
  foundations, the language a checker must handle is much smaller than
  Teal: structured control flow, no closure-assigned locals, no run-time
  metatables. a checker written for that language is smaller and faster
  than one migrated in place, and the migration's cost is visible already:
  shadow mode had to copy the old narrowing's quirks to agree with it. the
  fork gets only what the three foundations need, and no nil work: nil in
  every type reaches into the fork's subtype table, `never`, generics and
  every per-site nil check, and the tree's nil rewrite can only be
  verified by a checker that enforces the rule, so the new checker is that
  checker. every rule after the foundations ([nil out of every type] first,
  then [one variance per type constructor], [named receivers], [narrowing
  declarations], [tagged unions], [honest `or` and `and`], [confined
  casts], [annotated parameters], [typed queries]) is specified here and
  built in [the new checker], not in the fork.
- **declarations are the trust boundary.** a `.d.tl` signature, and a
  narrowing declaration, is the only typing the checker takes without
  proof. the standard library's Lua declarations live in `.d.tl` files,
  so auditing them changes no checker logic. a declaration answers `any`
  only at a named untrusted-data entry point: `require` of an untyped
  module, `string.unpack`, and the [`cosmic.sys`] bindings.
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
  it reports, and does not fail the run, until nil is out of every type:
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
  code.** rewrite cost is not a reason to choose a weaker rule. a rule is
  chosen for soundness and simplicity, and the tree is rewritten to it.
- **the checker, the compiler and the Lua VM are one target.** cosmic
  vendors and patches its Lua, so the compiler emits for exactly that VM,
  the patches included, and never for a range of Lua versions: the
  generator's 5.1, 5.3 and 5.4 branches, `gen_target`, `gen_compat` and
  the compat entries go, and so does any shim for a Lua the tree does not
  run. a rule may rest on a VM change ([no implicit conversion or hidden
  code]), and the VM may gain what the compiler needs, as a form only the
  compiler emits: a reserved token in the Lua the compiler writes, which
  the patched parser compiles to an opcode, such as the one that makes a
  class's value with its metatable. Lua text cannot name an opcode and a
  program's source cannot hold the token, so a program cannot reach it.
  the compiler keeps emitting Lua text rather than bytecode: Lua's own
  parser does register allocation, constant folding and line information
  that coverage and traces read, and loading text costs about 20 ms per
  megabyte. every opcode or bytecode format change bumps `LUAC_FORMAT`, so
  a stored chunk from an older VM fails at its header rather than
  misrunning. the compiler's identity already holds the Lua pin and
  patches, so a VM change rekeys every compile. the one boundary is the
  seed: the pinned release emits Lua source for the checker, not
  bytecode, because the tree's VM may have moved past the release's, and
  the checker's own source stays in the dialect the pinned release
  compiles and the tree's VM still runs.
- **speed is measured, not assumed.** [`bin/perf`] gains the workloads the
  plan's speed claims rest on: the checker's self-check on a cold
  database; the split of check, load and dump time per module; a million
  instances of a four-field class with three method calls each; a method
  call through `__index` against a direct call; number formatting; and a
  leaf edit at the bottom of a deep dependency chain, a body edit against
  a signature edit. a step that claims speed states its numbers on them.
  the compiler's largest free gain is a direct method call: a value whose
  static type is a class (not an interface) calls the method table's
  function directly, skipping the instance miss and the `__index` hop.
- **the runtime changes only where normal runs pay nothing, and loses
  what the language does not need.** the guarantees are type-level
  restrictions, plus Lua VM and surface changes that cost a normal run
  nothing; removing a coercion buys soundness, not speed. a program has no
  `setmetatable`, `getmetatable`, `rawset` or `rawget`. the code the
  compiler emits for a class reaches the VM through its reserved form; the
  standard library and the build reach them through a raw value
  [`core/store.c`] hands only to a trusted module, as it hands the raw C
  modules now. the strict-record and frozen-table checks run only in debug
  and test runs, as `--check-types` does. there is no always-on write
  check.
- **the new checker has its own grammar from its first PR.** it is not a
  drop-in for the fork: its grammar, its syntax tree and its interface to
  the tree ([`build/compiler.d.tl`]) are designed for the language, and
  the `build/` modules that read the syntax tree are rewritten beside it.
  the fork takes only type-level syntax that is erased in the emitted
  Lua, as a read-only field is, and no new statement or expression form.
  `<const>` is Lua syntax and stays.
- **what the claim excludes.** types do not track integer overflow,
  division by zero, or code a C userdata's finalizer runs. each is a
  run-time fault, not a type that lied. a table a program makes has no
  finalizer: a resource that must be released even when its handle is
  dropped, such as a child process, is a C userdata whose `__gc` C owns,
  and `<close>` releases everything else.

## the database

cosmic runs out of SQLite. `require` reads modules, as bytecode, from the
binary's database and nothing else; the build is a working database
(`build.db`) that stages the tree, keys every compile and records every
verdict; and the checker's output is rows: `stubs`, `decls`, `docs`,
`uses`, `links`, `examples`, the error `catalog` and the compiler itself
([design.md](../design.md)'s database section). the language is checked
and compiled into that database and is read back out of it, so the plan
keeps every part of it working and builds on it where it helps.

### what the language keeps working

- **the checker's rows are part of its contract.** [the new checker]
  writes `stubs`, `decls`, `docs`, `uses`, `links`, `examples`,
  `references`, the type report and the error `catalog` with the schema
  the fork writes, and the frozen contract it is built against includes
  them. a read-only field, `T?`, a class and its methods are written into
  `decls` and the stubs as the source declares them, so a checker typing
  another tree from the binary's rows sees the same types the tree's own
  checker did, and the build's refusal of a stub whose type differs from
  its source's goes on holding.
- **one bytecode column.** a stored chunk serves every target, and the
  bytecode header check is the safety net. the reserved class form's
  opcode bumps `LUAC_FORMAT`, so every stored module, the shared compile
  cache's included, rekeys with the compiler's identity, and a project's
  `cosmic.db` recompiles; nothing stale loads.
- **the module door stays C.** [`core/store.c`] loads a module's bytecode
  with `luaL_loadbufferx` in binary mode, and `inflate()` is a C function
  every handle knows, so taking text `load` and `string.dump` from
  programs changes neither. the self-rebuild reads the compiler's row as
  it does now.
- **the SQLite binding under no coercion.** [`cosmic.sqlite`] already
  binds by kind, with `lua_isinteger` and `TEXT` apart from `BLOB`, so
  turning off string-to-number coercion changes a binding only where a
  caller passed a string for a number, which then fails, as intended.
  a named-parameter table is a map: a record is not a map, so code that
  binds a record's fields builds the map, counted when [records are not
  maps] lands. an SQL function a program registers runs program code
  inside a query; under [narrowing only what nothing else can change] a
  call changes no place, so a query is an ordinary call.
- **rows become records once.** a typed accessor's row is a table literal
  checked against its record type, so its fields can be read-only, and
  the code that reads rows narrows them without copies.

### what the language builds on

- **types cross processes as rows.** [the new checker] writes each
  module's exported types, canonicalised, as a row beside its stub, and a
  module is checked against its requirements' rows rather than by checking
  their sources again. a worker can then check any module, so the
  sharding by import closure in `build/shards.tl`, which exists because
  "the checker's types cannot leave a process", goes, and the hash of
  that row is what a requiring module's compile key reads: an edit that
  leaves a module's exported types alone recompiles nothing that requires
  it. only a test verdict's key keeps the source closure.
- **a module is rechecked for what it uses.** `uses` already records
  which declarations of another module each module refers to. keying a
  module by the hashes of the declarations it uses, and of the types they
  reach, rather than by its requirements' whole interfaces, means an edit
  to a declaration nobody uses rechecks nothing. it is measured on the
  deep-chain workload against the whole-interface key before it is kept.
- **every count is a query.** the checker writes what the plan counts
  (narrowed reads by kind of place, casts by what they cast from,
  metatables by pattern, operators on strings, nil answered where `T` was
  declared) as rows in `build.db`'s type report, and each count a step
  states is a `cosmic sql` statement over them, which the step's PR
  quotes. the reviews of this plan had to count by regex; a measurement
  the checker writes is exact and is taken again by running it.
- **the verdict harness is tables.** the harness writes the fork's
  verdicts and the new checker's into tables of the working database, and
  the gate's triage is a join: each difference a row with the name of the
  rule that explains it, and the gate is the query that finds a row with
  none.
- **errors are catalogued.** an uncaught run-time error is already looked
  up in `catalog` and answered with the doc comment of the function that
  raised it. a checker error is catalogued the same way: each code a row
  with its rule's name, why it holds and how to fix it, indexed by FTS5, so
  `cosmic docs <code>` and the error itself read one text, and the fix an
  error prints is pinned once.
- **queries are typed against their schema.** SQLite's own parser checks a
  literal query and types the row it answers ([typed queries]), so the
  language's types reach into the SQL the tree is built on.

## the rules

each rule is a restriction, which refuses what upstream accepts, or an
extension, which adds what upstream lacks. the step that lands it is in
"the steps".

### nil is its own type

a restriction. `T` admits no nil. `T | nil`, its spelling `T?`, and a
`name?: T` field are the only ways to admit it. `nil` is a unit type;
`never` is below it. an argument, a return, a field write and an
initializer are checked by the same subtype relation as every other
value, so the per-site nil patches become that relation. a method call or
an index on `T | nil` is refused, as an index key that may be nil is. a
type variable ranges over all types, unions with nil included: inside a
generic body a `T` may be nil, and `x as T` removes no nil. a nil test of
a place typed `T` or `T | nil` narrows it to `T`, never to "T without
nil", which no type can say. the standard library's declarations are
audited, each of these named: `string.match` and `string.find` (each
capture `string | nil`), `table.remove`, `rawget`, `next`, `select`,
`math.tointeger`, `pcall`, `xpcall`, `coroutine.resume`.

### an index read may be nil

a restriction. `m[k]` and `m.k` on a `{K:V}` are `V | nil`. `t[i]` on a
`{T}` is `T | nil`, because Lua answers nil for an index out of range
rather than trapping. one refinement answers `T`, and only this: in
`for i = a, #t` (or `#t - d`) and `for i = #t, 1, -1`, with `a` a literal
of at least 1, `t[i]` (and `t[i + c]` for `c <= d`) is `T` when `t` is a
local the body neither assigns nor passes to a call. an index is not a
place: a test of `t[k]` narrows nothing, and the rewrite is
`local v = t[k] if v then ... end`.

a tuple type indexed by a literal in range is its member's type, and out
of range is refused. length facts (`#t > 0` giving `t[1]`) are not
tracked. a further pattern waits for a measured need.

### arrays are dense

a restriction. `{T | nil}` is refused as an array type: `#`, `ipairs` and
`table.insert` are defined on a sequence, and a hole makes each
unreliable. sparse data is a map, `{integer:T}`, and `#` on a map is
refused.

### narrowing only what nothing else can change

a restriction, with read-only fields as its extension. one flow analysis
decides narrowing and reachability.

- a place is a local, or a path of read-only fields from a local
  (`r.a.b`, with `a` and `b` each declared read-only). a field of a record
  is read-only when the record declares it so: it is given a value by the
  table literal that makes the record and is never assigned after,
  through any reference. a global, a mutable field and an index are not
  places, and a test of one narrows nothing; the rewrite is a local copy,
  `local n = r.n if n then ... end`, which the error gives.
- inside a function, a local of the code around it is a place only if
  nothing assigns it after the function is made. [captures are read-only]
  stops the closure assigning it, but the code that declares it can while
  the closure is suspended in a coroutine, or between two calls, so a
  test inside the closure narrows only a local that is fixed from then
  on.
- a record with a read-only field is made only by a table literal checked
  against that record type. a literal with no expected type has a type of
  its own, which is not a record with a read-only field, so no second
  reference to it can write the field. a literal of such a record gives
  every read-only field a value.
- a `.d.tl` declaration that takes a record with a read-only field
  promises that its C does not write it; the step that adds read-only
  fields audits every [`cosmic.sys`] binding that takes a table, and a
  binding that fills a table takes a map or returns a fresh one.
- a cast cannot forge a writer: `x as T` to a record with a read-only
  field, to a class, or from a record to a map or an interface is refused,
  in the fork from the step that adds read-only fields. data typed `any`
  becomes such a record through a [`cosmic.shape`] validator, and a class
  through `is`.
- a guard is a truthiness test, `== nil` and `~= nil`, `==` with a
  literal, `is`, `type(x) == "..."`, their `not`, `and` and `or`, a call
  of a narrowing declaration, and a branch that ends its block.
- an assignment to a local drops what was known of it and of every path
  from it. an assignment that names the same target twice (`x, x = a, b`)
  is refused, since Lua leaves its order open. nothing else drops a fact:
  a closure cannot assign a local it does not declare, and no reference
  can assign a read-only field, so neither a call, a write through an
  alias, an operator nor a metamethod can change a place. the analysis
  keeps no list of what runs code for narrowing; [assigned before read]
  keeps the one it needs.
- a statement with no successor (`return`, `break`, a `goto` out of the
  block, a loop with no exit, a call of a `: never` function) ends its
  block. a `goto continue` to a label in the same loop does not end the
  path.

this replaces upstream's facts and the per-form narrowing and
block-ending patches; [narrowing by construction] gives it its form. a
read-only field is type-level syntax, erased in the emitted Lua. a record
that implements an interface declares a field read-only exactly when the
interface does, which the step that adds read-only fields checks before
[one variance per type constructor] makes field types exact, and [records
are not maps] refuses a record where a map is expected, so no view of the
table can assign the field.

### captures are read-only

a restriction (done, #3067). a function literal may read but not assign a
local declared outside it. it makes the closure-assigns-a-narrowed-local
class of hole impossible, and with it the pending-function machinery of
[assigned before read] for assignments.

### goto only as continue

a restriction (done, #3066). a `goto` is a forward jump to a label at the
end of the enclosing loop body.

### assigned before read

a restriction (done, #3061). `local x: T` with no value is legal only
where every path assigns `x` before its first read. a loop body may run
zero times. an assignment inside a function literal does not count, and
creating a function literal reads every variable it names. `local x: T |
nil` with no value is legal and is nil. a bare `local x` with no type and
no value is refused, and the error says to declare `local x: T | nil`.

### never is the bottom type

an extension. with nil out of the bottom of the lattice, `never` takes
it, and a function declared `: never` is a subtype of every function with
its parameters by return covariance.

### one variance per type constructor

a restriction, with read-only views as its extension.

- a function is contravariant in its parameters and covariant in its
  returns.
- a mutable array or map is invariant: `{T}` accepts only `{T}`, and
  `{K:V}` only `{K:V}`.
- a record is compared by name. a field of a record that implements an
  interface has exactly the interface's type. a method, a field whose
  function names its receiver, cannot be assigned, and is compared as a
  function.
- a generic record is invariant in its type arguments.
- `readonly {T}` and `readonly {K:V}` are views. `{T}` is a `readonly {U}`
  when `T` is a `U`, and so is a `readonly {T}`; a view is never a `{U}`.
  through a view a program reads (`#`, an index read, `ipairs`, `pairs`,
  `next`, `table.concat`, `table.unpack`) and passes it where a view is
  expected; it never assigns an index or passes it as `{T}`. a view is
  shallow (`readonly {{T}}` has mutable elements), is erased in the
  emitted Lua, and applies to arrays and maps only. a function that only
  reads declares its parameter a view; one that returns or stores the
  container uses a generic.

### narrowing declarations

an extension. a function type may say that it narrows an argument to a
type when it returns true, or that it returns only when an argument is
not nil or false. `assert` and the [`cosmic.shape`] validators are then
ordinary declarations, and their special cases in the checker go. the
checker takes such a declaration on trust, as it does a `.d.tl`
signature, so it is legal in a `.d.tl`, and in Teal only where the
function's returned expression is itself a guard the checker verifies.
`type` stays special, but answers through the same narrowing. `pcall`,
`xpcall`, `coroutine.resume` and `coroutine.wrap` stay special until the
language has variadic generics.

### tagged unions

an extension. a union of records is legal when each member has the same
field typed by a distinct single-member enum, and comparing that field
with a literal narrows the union. a chain of tests that covers every
member leaves `never` in its final branch, so a function that must return
can end there. `is` applies to primitive types, enums, `nil`, function and
table kinds, and classes; `v is R` for a record `R` that is not a class is
refused, since Lua erases the record, and the error names a tag field or
a [`cosmic.shape`] validator.

### compiler-written classes

a restriction, with the class literal as its extension. a method is a
`function R:name()` declaration or a field whose function names its
receiver. a record that declares one is a class, and each method it
declares is defined in its module. the compiler writes the class's one
metatable: `__index` is its method table, and `__close` and `__tostring`
are the methods of those names it declares. a value of a class is made by
a table literal typed as the class, which the compiler emits with the
metatable attached; there is no other way to make one, and a program
cannot call `setmetatable`. no other metamethod exists on a table a
program makes, except a marker C attaches that has no metamethods (the
JSON array marker), which runs no code and which no program can read:
an operator other than `==` on a record, an interface or a class is
refused, `==` on two tables is identity, and a function
`__index`, `__newindex`, `__call`, `__len`, `__concat`, `__pairs` and the
arithmetic and comparison metamethods have no form. what the tree does
with them now becomes a method (`v:call(...)`, `v:len()`) or, for
`__mode`, a weak table from the standard library. because the metatable
is the compiler's, `v is C` for a class `C` is a check of it, so classes
are told apart without a tag. this needs classes compared by name, so the
classes step makes class types nominal before [one variance per type
constructor] does it for every record.

the literal that makes a class's value names every field, a field not yet
known taking its empty value or nil (`fd = -1`), since nothing can attach
the metatable to a table built another way. a class's fields and methods
have distinct names, since an absent field would read as the method of
its name through `__index`. `__close` takes the value and `__tostring`
returns a string, both checked; a `<close>` local holds a class that
declares `__close`, or nil. there is no inheritance. the compiler emits
the literal as one reserved form, which the patched parser compiles to a
table made with its metatable in one opcode.

### records are not maps

a restriction. a record is never passed where a map or `{string:any}` is
expected, and `pairs`, `next` and `rawset` refuse it, because its fields
have types of their own.

### honest `or` and `and`

a restriction. `a or b` is refused when `a` may be `false`, since `or`
replaces false as well as nil; the error says `if a == nil then`.
`c and x or y` is refused when `x` may be false or nil, since the
expression then answers `y`; the error says to use an `if`.

### named receivers

a restriction. interfaces declare methods with `self: I`, `self` is
always the declaring type, and the receiver exemption goes, with the hole
it brings (a callback field `function(Event)` taking a
`function(KeyEvent)`). [roadmap.md](../roadmap.md) holds the item for
[`cosmic.stream`].

### varargs end in nil

a restriction. an element of `...: T` read by `local a, b = ...`,
`select(n, ...)` or `({...})[i]` is `T | nil`. a call that may answer no
values, used where one value is wanted, answers `T | nil`.

### confined casts

a restriction. as [design.md](../design.md)'s teal section states:
`x as T` only from `any`, from a userdata record declared in a `.d.tl`, or
from the enclosing generic's type variable. 230 of the 290 non-test casts
not from `any` are in the checker's own source, which [the new checker]
replaces.

### annotated parameters

a restriction. a parameter of a function declaration, or of a function
literal with no expected function type, has a type. a literal passed
where a function type is expected takes its parameter types from it, as
the fork does now, so a `table.sort` comparator needs none.

### dispatch only through declared types

a restriction. with [compiler-written classes] it holds by construction:
the only metatables on tables a program makes are the compiler's, and the
only code they run is a class's `__close` at a block's end and its
`__tostring` under `tostring`. a C userdata declared in a `.d.tl`
dispatches through the metamethods its declaration names.
[roadmap.md](../roadmap.md) holds the item.

### no implicit conversion or hidden code

a restriction. the patched Lua and the surface [`core/surface.c`] opens
are cut to what the language needs.

- a string is never a number: arithmetic on a string and a string `for`
  bound fail in the VM, not only in the checker, so data typed `any` fails
  at the operation. Lua already has the switch, `LUA_NOCVTS2N`, which also
  drops the string metatable's arithmetic; a `patch/lua/` record sets it
  in `luaconf.h`, which every unit that includes Lua sees, the core's C
  included. a number still converts to a string, so `"line " .. n` stays
  legal: it cannot go wrong, and removing it (`LUA_NOCVTN2S`) would
  rewrite about a thousand sites and change the C API's `lua_tolstring`
  for no soundness.
- a program has no `setmetatable`, `getmetatable`, `rawset`, `rawget`,
  text `load` or `string.dump`; [`core/surface.c`] replaces each with the
  stand-in it gives `io` and `os` now, whose error names what to use
  instead. code the compiler emits reaches the VM through its reserved
  form; the build's compile and test harness, and the validators of
  untrusted data ([`cosmic.shape`], [`build/confine.tl`]), reach `load`
  and a raw field read through a raw value only a trusted module receives.
  so everything a program runs came through `require` and the checker.
  until the pin carries [compiler-written classes], the checker's own
  Lua, compiled by the seed, still calls `setmetatable`, `rawset` and
  `load`, and the boot keeps them in its environment.
- a table a program makes has no `__gc` and no `__mode`, which needs no
  change to `lgc.c` once only the compiler and C attach metatables; a C
  userdata keeps its `__gc`, and a weak table is made in C.
- `_G` cannot be replaced, assigned through, or given a metatable.

each is counted over the tree first, and a build with the switch on runs
the whole test suite before the rewrite starts, since a removed coercion
fails at run time, in Teal or in the core's C, not at compile time. each
lands with the rewrite of what it finds.

### typed queries

an extension, built in [the new checker]. a literal SQL string passed to
[`cosmic.sqlite`] is prepared at check time against the schema of the
database it is run on, by SQLite's own parser over an empty in-memory
database built from that schema: a statement that does not prepare is a
compile error that quotes SQLite's message, the parameters it names must
be the ones passed, and the row it answers is typed from its result
columns. the tree's databases declare their schemas in code already
(`build.db`, the shipped projection, the shared caches), so the checker
reads what the program already says. how a module ties a handle to its
schema is an open question, and the rule lands with a count of literal
queries first.

### not adopted

`any` is legal only where untrusted data enters, and the checker refuses
to assign it, call it or index it. data only enters it: a record, a
class or a value whose type has a read-only field is never assigned to
`any`, so no round trip through `any` and a cast to a map can write a
field behind its type. code that needs a value of any type uses a type
variable or a tagged union, and an encoder takes the type it encodes.

rejected, so nobody proposes them again: a non-nil assertion `x!` (an
escape hatch; `assert(x)` says why), `a?.b` (the tree's field paths are
almost all non-nil), a `??` operator ([honest `or` and `and`] refuses the
hazard instead), bounded generics over primitive types, declaration-site
variance (`record Box<out T>`), narrowing a mutable field (a local copy
is the rewrite), narrowing only stable locals (1,070 error lines in 203
files, and assignment already drops a local's fact precisely), a typed
`setmetatable` ([compiler-written classes] removes it), removing
number-to-string conversion, and the compiler writing bytecode. each
waits for a measured need.

## what the tree measured

the numbers below come from the reviews of this plan, by running the
checker over the tree with logging, or by heuristics where stated. they
size the steps; once [every count is a query](#what-the-language-builds-on),
each step measures again with the checker's own rows before it lands.

- **array index ([an index read may be nil]).** 10,719 index reads: 6,310
  on arrays, 4,613 of them in tests. about 27% are already nil-checked
  where they stand. the loop and guard patterns cover about 13% of the
  rest. the largest remainder outside tests was a fixed-width row read by
  a constant index (`row[1]` from a [`Sqlite.rows`] result, about 520
  reads). rows are read through typed accessors, so these reads are gone.
  about 4,613 test reads by index remain (see "open questions").
- **variance ([one variance per type constructor]).** about 1,420 places
  compared a container covariantly. 1,344 are `table.concat` of a
  `{string}` against its `{string | number}` declaration; three option
  signatures (`fds`, `gsub`'s table, `flags`) hold most of the rest.
  every callee reads only, except [`Json.array`], which returns its
  argument and needs a generic. no array of records passes as an array of
  an interface.
- **narrowing a field ([narrowing only what nothing else can change]).**
  of about 1,080 guards on a field path, at most 76 call a function in the
  guarded body and read the path again (heuristic). of the 752 narrowed
  field reads below, 79% are on fields never written after the table is
  made, so declaring those fields read-only keeps them; the rest, about
  160 reads, take a local copy. parsed syntax nodes, filled after they are
  made, and `self` state are most of the rest.
- **metatables ([compiler-written classes]),** outside tests and the
  checker, by matching assignments (heuristic): about 75 class `__index`
  tables and 14 sites that attach a metatable to a table already built;
  35 metatables with `__close`, six of them made per call to capture
  locals as a defer; four `__mode` tables, two proxies, two `__gc` safety
  nets, one `__tostring`; no `__call`, `__eq`, `__len`, `__concat`,
  `__pairs` or arithmetic, and no inheritance. the larger raw counts are
  test fixtures. about 50 `rawget`/`rawset` uses, most of them validators
  of untrusted tables.
- **coercion ([no implicit conversion or hidden code]).** about 100 to 200
  sites outside tests join a number with `..`, mostly in error messages;
  string arithmetic cannot be counted by text and is counted by a build
  with the switch on.
- **narrowing by construction,** measured on `origin/main` at e95cd66f4.
  - narrowed reads: 12,513. field reads: 752 (609 outside tests) on 557
    places; 79% of them are on fields never written after creation.
  - mutable-local narrowed reads: 1,545. turning narrowing off for them
    gives 1,070 error lines in 203 files.
  - closure-assigned narrowed reads: 153, on 105 places.
  - function literals that assign an outer local: 1,182 (436 outside
    tests, 746 in tests) over 838 captured locals, all since rewritten for
    [captures are read-only]. no forward-declared function is assigned by
    a closure. the patterns: 190 out-params declared without a value, 135
    declared `= nil`, 324 accumulators, 119 flags, 410 other.
  - `goto`: 5, all of the shape [goto only as continue] allows.
  - `setmetatable`: 163 calls. 67 attach to a record that declares
    metamethods, 70 to a record that declares none (64 of them the
    class-method `__index = R` pattern), and 25 are untyped.
  - casts: 1,624, of which 958 are not from `any`: 290 outside tests (230
    in the checker) and 668 in tests.
  - drop sites with field facts: 1,008. about 30% of their callees in the
    tree are pure one level deep.
  - `rawset` 11, `rawget` 29, `debug.*` 3 (all in the checker).
- **the checker's own source.** 320 type errors under its own rules,
  pinned as a count by [`build/compiler_test.tl`]. it has about 94 free
  locals, short of Lua's limit of 200.
- **nil ([nil is its own type], [assigned before read]).** the rewrite of
  every directory outside `checker/` cost less than planned.
  `--check-types` finds what a call or return passes, but not a local or a
  field omitted from a table literal; those stay honest only once [nil
  out of every type] lands. heuristic floors: about 80 `return nil` in
  functions declared to return non-nil, about 460 `local x: T` with no
  value, and 39 `table.remove` and 36 `select` calls. the uncounted class
  is nil passed as an argument or written to a field. the tree already
  writes about 3,000 `| nil` types and 1,100 `?:` fields. the checker's
  own source writes none and relies on nil being in every type.

## the steps, in order

each step is one or more PRs that follow
[doc/contributing.md](../contributing.md): each stands alone, passes CI,
and has a test that fails without it. a step that refuses more counts its
sites over the tree first, then rewrites the tree and turns the refusal on
for every module, in one change where its size allows. each PR states the
change in boot time and in the checker's self-compile time. every checker
step follows the review practice in "decisions", with two independent
review rounds per PR.

### done

- **the checker moved into the tree (#3032).** the patched `tl.tl` moved
  to its own root, compiled at boot, emitting byte-identical Lua; the
  compiler's identity and cache keys, the boot bridge, the bill of
  materials and [`build/compiler_test.tl`] moved with it, and `patch/tl/`
  was deleted.
- **structured errors and declarations (#3033, #3039).** the checker
  answers a code and its places with each error; the hints in
  [`build/teal.tl`] read those, not message text. the Lua standard
  library's declarations live in `.d.tl` files.
- **run-time checks in test runs (#3040).** they report, and size what the
  later steps refuse.
- **the flow analysis as checker modules.** reachability (#3041); places
  and guards in `checker/narrowing.tl` (#3044); drops at writes, calls,
  declared-metamethod operators, loops and labels (#3050).
- **[assigned before read] (#3061), [captures are read-only] (#3067) and
  [goto only as continue] (#3066).**
- **checker fuzzing (#3060, #3062).** a test runs random programs through
  the checker and fails on any crash, and a differential against a pinned
  corpus fails when what the checker accepts changes without a deliberate
  update. it runs on [`build.fuzz`], with its corpus in `testdata/fuzz/`.
- **the row-accessor pin move (#3056).** [`Sqlite.rows`] results are read
  through typed accessors (#3051), and `ci/` dropped its shim once the pin
  carried them.

### narrowing by construction

it lands before every later rule, so the flow analysis they read is the
sound one. the design is in [strict-teal-narrowing.md]; its verdict
harness, facts module and shadow mode are done (#3070, #3069, #3074), and
shadow mode found four old-narrowing bugs, fixed in #3071, #3072, #3073
and #3075. in short:

- declared types are never mutated. facts live in an immutable map from
  place to type, keyed by binding, carried along a small control-flow
  graph, and joins happen in one place.
- it retires `specialize_var` and the scope-marker bookkeeping (`narrow`,
  `widen` and `localizing` entries, `widened_from`).
- a place is a local or a path of read-only fields from one. a local's
  fact is dropped precisely by assignment, and nothing drops a read-only
  path's. the field-path and global drops, and the facts that serve them,
  go.
- read-only fields land before reads switch, in PRs small enough to
  review: the syntax and the refusal of a write outside the record's
  literal; the literal rules; interface agreement and the casts that would
  forge a writer; the [`cosmic.sys`] audit; [records are not maps],
  counted first; then one change that declares read-only each field the
  tree never writes after creation, copies the other narrowed reads to
  locals, and restricts the old narrowing to the same places, so the
  switch to the facts flips only what the facts decide differently.
- before reads switch, the fuzz generator makes coroutines that yield
  between a test and a read, literals aliased before they are typed, and
  casts, and is shown to find each hole [narrowing only what nothing else
  can change] closes on a checker without its fix.
- the refinements that accept more are not built in the fork: the new
  checker's one pass gives them.

### the pinned-release seed

it needs a release between its parts, so the first two start now, beside
narrowing by construction, and the rest land before [the new checker]
replaces the fork, which needs them; narrowing by construction does
not.

- **a compile verb in the release.** a verb or module the pinned release
  can run that compiles a list of `.tl` files to one Lua text each, for
  the tree's VM, with the compat targets off. it emits despite type errors
  and refuses only syntax errors, since the checker's source does not obey
  its own rules. it emits each file raw; the wrapper that joins the
  checker's parts lives once, in the tree, where today
  [`build/compiler_test.tl`] and the boot bridge each build it.
- **the pin move.** the pin moves to a release that carries the verb.
- **boot from the seed.** a `build.zig` step runs [`bin/cosmic-bootstrap`]
  on `checker/` and the pin before boot. boot compiles in two stages, the
  seed's checker compiling the checker's source and that checker
  compiling it again, and the tool carries the second stage, so the
  carried compiler never depends on the pin's emitter.
  [`build/compiler_test.tl`]'s fixed point is the third stage equal to
  the second; a change that leaves the emitter alone also asserts the
  first equal to the second, which catches a seed that miscompiles. a boot
  whose seed cannot parse the checker says which syntax and that the pin
  must move. the self-rebuild already uses the carried compiler and is
  unchanged.
- **`vendor/tl/` removed.** it goes, except the license and notice, which
  move beside the checker and stay in the bill of materials; the
  compiler's identity loses [`vendor/tl/PIN`].
- **the standalone shims removed.** `checker/tl.tl`'s command-line code,
  which reads `io`, `os`, `package`, `load` and `debug`, is deleted, and
  then the boot bridge's stand-ins and [`build/teal.tl`]'s copy of them
  go. the bridge's compile of the `build.*` closure stays; only its
  compiler row goes.

the checker's own source may then use `name?: T`, `: never` and the strict
rules, one pin move after each lands. it is never rewritten to a rule the
new checker replaces it before, and the self-compile's pinned type-error
count becomes a ceiling.

### compiler-written classes, in the fork

[compiler-written classes] and [dispatch only through declared types].
the tree's class pattern (`setmetatable(o, R)` with `R.__index = R`)
becomes a literal typed as the class, naming every field; class types
become nominal; the patched parser gains the reserved class literal form
and its opcode. the tree's other metatables are few outside tests: four
`__mode` tables, two proxies with function `__index`, one `__tostring`,
two `__gc` safety nets on process handles, and the array marker the JSON
decoder attaches in C ([`core/json.c`]). each gets its class form, except
the two process handles ([`Child.Handle`] and the connector's process),
which become C userdata with a `__gc` that kills and reaps a child its
handle was dropped without closing; the class form holds only Teal
state, and a handle that must not leak is a resource C owns. the JSON
array marker stays: `core/json.c` attaches [`cosmic.json.array`] to a
decoded array, and `Json.array` to a table a program marks, so an empty
`[]` encodes back as `[]`. it has no metamethods, and once a program has
no `getmetatable` it cannot see it. then `setmetatable`,
`getmetatable`, `rawset` and `rawget` leave the surface a program sees.
the checker's source keeps the `setmetatable` dialect until the pin
carries this step.

### the new checker

written for the language the foundations leave, not forked from
`checker/tl.tl`, at about 10,000 to 13,000 lines against the fork's
22,000. it starts now, beside the fork's foundations, and holds each
foundation's final form as the fork lands it. a sketch, not a design:

- its grammar is designed first, with the syntax tree and the interface
  that about twenty `build/` modules read (`build/ast/`, the analyzer,
  stubs, docs, links, scopes); those modules are rewritten to it beside
  the checker, not after. what it keeps of the fork's contract is what the
  rest of the tree relies on: tokens with comments, warnings, error codes,
  line-preserving output, the `--check-types` and checked-narrowing code,
  and every row the checker writes into the database ("what the language
  keeps working").
- the grammar holds, provisionally, beyond Teal's: an `if` expression
  (`if n == 1 then "item" else "items" end`), which gives the 800 or so
  `and`/`or` ternaries a form that cannot answer the wrong branch when
  the middle value is false or nil; `match` over a tagged union, refused
  when a member is missing, so exhaustiveness is checked in one place,
  not in `if` chains; a `class` declaration holding a class's fields,
  read-only markers and methods in one place, which [compiler-written
  classes] needs to read plainly; and `T?` and read-only fields as
  syntax of their own. it drops `goto` (a `continue` takes its one
  allowed use), the `and`/`or` ternary, and `as` (a checked `is` takes
  its place). each is confirmed or dropped when the grammar is written.
- a translator comes with the grammar: it rewrites a Teal module into the
  new grammar, and is how the tree moves to it, in the change that
  replaces the fork. it is also the oracle a drop-in parser would have
  been: where the new grammar only respells a construct, the new
  checker's Lua for the translated module is byte-identical to the fork's
  Lua for the original, over the whole tree, so the parser and code
  generator are checked before any type rule is. a construct whose meaning
  changes is listed, and its emitted Lua is compared by the test suite
  instead.
- one pass builds a control-flow graph that narrowing and definite
  assignment both read, with facts keyed by binding; there is no
  metamethod or "runs code" reasoning, because the foundations left
  nothing for it to decide.
- one subtype relation with its variance, built so that nil leaves every
  type by a change to the relation, not a rewrite: the representation
  keeps nil a type of its own and `never` below it from the first PR,
  with nil admitted everywhere only until [nil out of every type] lands.
- each error a code, its places and the fix, catalogued, from the first
  PR.
- types cross processes as rows, and a requiring module is recompiled
  only when the hash of what it reads moves ("what the language builds
  on").
- its gate to replace the fork: it accepts the whole translated tree,
  refuses every program pinned in [`build/teal_test.tl`] (translated),
  and every verdict it gives differently from the fork, file by file, is
  a row in the verdict tables tied to a rule's name; the fuzz soundness
  property and checked narrowing run against it. then it replaces
  `checker/` in one change that also translates the tree.
- its own source is written in Teal, in what the pinned release's checker
  accepts, since the seed compiles it and the seed parses only Teal until
  a release carries the new checker. once the pin moves to that release,
  its source is translated like the rest of the tree, and from then on it
  compiles itself to a fixed point, one pin move behind its own grammar as
  the fork is behind its own rules.

### nil out of every type

[nil is its own type], [an index read may be nil], [arrays are dense],
[never is the bottom type] and [varargs end in nil], the first rules the
new checker holds once it replaces the fork. the count and the
declarations audit come first, the count from the new checker run with
the rules on over everything outside `checker/`. `--check-types` cannot
see a local or a field a literal leaves out, so the new checker is what
verifies the tree's rewrite. the tree is rewritten one directory at a
time, tests with their modules, while the rules are off, then one change
turns them on. `never` becomes the bottom type as nil leaves it. the nil
error names the call that answered nil and its declaration, since the
rule multiplies it.

### variance, views and receivers

[one variance per type constructor] and [named receivers], in the new
checker. `table.concat` and the three option signatures take views first.

### narrowing declarations and tagged unions

[narrowing declarations] and [tagged unions], in the new checker, each
with its count over the tree first.

### honest `or` and `and`, casts and parameters

[honest `or` and `and`], [confined casts] and [annotated parameters], in
the new checker. most of the tree's casts exist to get past nil,
narrowing and variance, so after nil is out of every type most are
deleted rather than justified.

### typed queries, in the new checker

[typed queries], after a count of the tree's literal queries and the
answer to how a handle names its schema.

### the runtime cut

it lands [no implicit conversion or hidden code], in parts:
string-to-number coercion out of the VM, no text `load` or `string.dump` for a program, no `__gc` or
`__mode` on a program's tables, and a fixed `_G`. it depends on no checker
step after the classes, and each part lands with the rewrite of the sites
it counts; the checker's own source is free of string arithmetic before
the switch, since the seed's Lua runs on the tree's VM.

## open questions

- **`defer`.** whether the grammar earns a `defer` form for the six
  per-call `__close` guards, revisited once they have been written as
  small classes with `__close` and a `<close>` local.
- **the files' extension.** whether a module in the new grammar keeps
  `.tl`.
- **a query's schema.** how a module ties a [`cosmic.sqlite`] handle to
  the schema [typed queries] checks against: a declared schema the
  handle's type carries, or the `CREATE` statements the module runs.
- **`require` cycles.** what a cycle answers, which decides whether a
  module's read-only fields can be seen before they are set.
- **the narrowing declaration's syntax.** it must read in a `.d.tl` and in
  `cosmic docs` as plainly as a return type does.
- **variadic generics.** whether `pcall`, `xpcall` and the coroutine
  functions earn them, or stay special.
- **tests.** whether test files get a helper for an index they have
  already asserted the length of, since about 4,613 array reads are in
  tests and a nil there already fails the test.
- **strict-record checks in debug runs.** whether they come before or
  after narrowing by construction.
- **dense arrays.** what [arrays are dense] costs the tree, counted by the
  new checker before nil leaves every type.

## what the first steps taught

- **the checker was buggier than expected.** about 10% of random narrowing
  programs crashed the checker on main. `local x: integer | nil, y = 1, 2`
  crashed it, an else-branch assignment was missed in loops (`ipairs` over
  a nil hole), and the self-compile test had checked nothing. only
  throwaway differential runs and random-program generators found these,
  hence [checker fuzzing].
- **a restriction can over-refuse.** the syntactic loop rule refused common
  code that main accepted, and became a typed analysis. every review found
  at least one blocking issue, often visible only by testing against main.
- **run-time metatables are a hole,** hence [compiler-written classes].
- **migrating a forked checker in place costs more than the language it
  checks.** shadow mode had to copy the old narrowing's quirks to agree
  with it, and most of the fuzzer's finds were facts keyed by name or
  scope bookkeeping no new design would have. hence [the new checker].
- **the pinned CI driver lags the tree,** so `ci/` cannot use a new API
  until the pin moves.
- **a change can expose a bug beside it.** a deadline-rounding bug in the
  core's C was found when the row accessors (#3051) were knocked out of
  the merge queue (#3055).
- **counting by text is not counting.** the reviews of this plan counted
  field guards, casts and metatables by regex, and two disagreed by a
  factor of three on metamethods; the checker's own rows answer exactly,
  hence [every count is a query](#what-the-language-builds-on).

[annotated parameters]: #annotated-parameters
[arrays are dense]: #arrays-are-dense
[assigned before read]: #assigned-before-read
[captures are read-only]: #captures-are-read-only
[checker fuzzing]: #done
[compiler-written classes]: #compiler-written-classes
[confined casts]: #confined-casts
[dispatch only through declared types]: #dispatch-only-through-declared-types
[goto only as continue]: #goto-only-as-continue
[honest `or` and `and`]: #honest-or-and-and
[an index read may be nil]: #an-index-read-may-be-nil
[named receivers]: #named-receivers
[narrowing by construction]: #narrowing-by-construction
[narrowing declarations]: #narrowing-declarations
[narrowing only what nothing else can change]: #narrowing-only-what-nothing-else-can-change
[never is the bottom type]: #never-is-the-bottom-type
[nil is its own type]: #nil-is-its-own-type
[nil out of every type]: #nil-out-of-every-type
[no implicit conversion or hidden code]: #no-implicit-conversion-or-hidden-code
[one variance per type constructor]: #one-variance-per-type-constructor
[records are not maps]: #records-are-not-maps
[strict-teal-narrowing.md]: strict-teal-narrowing.md
[tagged unions]: #tagged-unions
[the new checker]: #the-new-checker
[the pinned-release seed]: #the-pinned-release-seed
[typed queries]: #typed-queries
[varargs end in nil]: #varargs-end-in-nil
[`bin/cosmic-bootstrap`]: ../../bin/cosmic-bootstrap
[`bin/perf`]: ../../bin/perf
[`bin/vendor`]: ../../bin/vendor
[`bin/zig`]: ../../bin/zig
[`build.fuzz`]: ../../build/fuzz/init.tl
[`build/compiler.d.tl`]: ../../build/compiler.d.tl
[`build/compiler_test.tl`]: ../../build/compiler_test.tl
[`build/confine.tl`]: ../../build/confine.tl
[`build/teal.tl`]: ../../build/teal.tl
[`build/teal_test.tl`]: ../../build/teal_test.tl
[`ci/cosmic-driver.pin`]: ../../ci/cosmic-driver.pin
[`core/json.c`]: ../../core/json.c
[`core/store.c`]: ../../core/store.c
[`core/surface.c`]: ../../core/surface.c
[`cosmic.shape`]: ../../cosmic/shape.tl
[`cosmic.sqlite`]: ../../cosmic/sqlite.tl
[`cosmic.stream`]: ../../cosmic/stream.tl
[`cosmic.sys`]: ../../core/syscalls.h
[`Json.array`]: ../../cosmic/json.tl
[`Sqlite.rows`]: ../../cosmic/sqlite.tl
[`vendor/tl/PIN`]: ../../vendor/tl/PIN

[`Child.Handle`]: ../../cosmic/child.tl
[`cosmic.json.array`]: ../../cosmic/json.tl
