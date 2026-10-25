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

the work runs on two tracks. the checker forked from Teal is taken as
far as two foundations and then frozen: [the pinned-release seed]
compiles it in place of upstream's `tl.lua`, and [narrowing by
construction] narrows only what nothing else can change. beside it, [the
new checker] is written for the smaller language those leave, and holds
the strongest form of every rule from its first PR: fixed fields, records
that are not maps, no `as`, nil out of every type, conditions that are
booleans or optionals, collections that are views, and classes the
compiler writes. the tree does not obey them yet, so each rule's
violations over the translated tree are a ceiling per file and code that
only falls, and a new violation is refused ([a count the tree cannot yet
bring to zero is a ceiling]). the new checker replaces the fork once it
is at least as sound as the fork, not once every ceiling is zero ([the
switch]). the rewrites that bring each ceiling to zero come after, in the
new grammar ([the rewrites to zero]). the switch is done ([the switch]); the sections that speak of the fork describe the
state before it.

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
[captures are read-only]. the new checker adds a fixed field, which
nothing assigns after its table is made. a call then drops no fact, and
no list of what runs code is kept for narrowing. the patch format made each of these
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
  sound form. a refinement that accepts more (an escape
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
  is pinned with the error in build/teal_test.tl, as
  `test_a_value_that_may_be_nil_is_told_the_check` pins today's, and an
  error whose fix the checker cannot state is a bug in the error.
- **strict is the only mode.** a rule holds for every module from the PR
  that adds it. no module keeps a lax mode, which would be an escape
  hatch. where the tree does not yet obey a rule, its violations are
  pinned as a ceiling per file and code that only falls and that a
  rewrite brings to zero, and a new violation is refused, so code written
  after the switch meets the full rules; no file is exempt and no rule is
  switched on last. a count over the tree, taken first, sizes the
  rewrite; it is a measurement, not a gate.
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
  of upstream's `tl.lua` ([the pinned-release seed]). `vendor/tl/` has
  gone, except for the license and notice the checker inherits, and so
  have the stand-ins for `io`, `os` and `package` that `tl.lua` needed. the pin is
  already the root of trust for [`bin/zig`], [`bin/vendor`] and the
  scripts they run, so it adds no root; a seed committed to the tree would
  add one beside the pin and the pinned Zig. the checker's own source may
  use what the pinned release's checker accepts: a rule or a syntax lands
  in the tree first and reaches the checker's source one pin move later,
  as in any compiler that compiles itself, while the rest of the tree uses
  it at once. the way back from a release whose checker is broken is the
  previous pin, a one-line revert, and `COSMIC_BOOTSTRAP` runs any other
  cosmic in its place. the fixed point of `build/compiler_test.tl` keeps
  a broken checker from being released.
- **a new checker for the smaller language, started now.** the language
  a checker must handle is much smaller than Teal: structured control
  flow, no closure-assigned locals, and, in the new checker, no run-time
  metatables. a checker written for that language is smaller and faster
  than one migrated in place, and the migration's cost showed: shadow mode
  had to copy the old narrowing's quirks to agree with it. the fork gets
  only the foundations it has, and no nil work: nil in every type reaches
  into the fork's subtype table, `never`, generics and every per-site nil
  check, and the tree's nil rewrite can only be verified by a checker that
  enforces the rule, so the new checker is that checker. every rule after
  the foundations ([nil is its own type],
  [collections are views unless declared mutable], [fields are fixed
  unless declared mutable], [records are not maps], [no casts],
  [conditions are booleans or optionals], [one variance per type
  constructor], [named receivers], [narrowing declarations], [tagged
  unions], [honest `or` and `and`], [annotated parameters], [generic
  bodies compare, pass and store], [numeric keys are integers], [pcall
  and coroutines are typed], [compiler-written classes] and [dispatch only
  through declared types]) is specified here and built in [the new
  checker], not in the fork. the new checker holds the strongest of them
  from its first PR, each with a ceiling on the translated tree, rather
  than gaining them one at a time or switching them on at the end.
- **the fork is frozen.** it gets no new work except a real soundness
  bug: a program it accepts that faults at run time on a type that lied.
  a hole the new checker closes by its defaults is not closed in the fork.
  the fork narrows only locals, so the tree declares no read-only field in
  it: the fork's `readonly` syntax and its write and literal rules (#3081,
  #3083) stay unused by the tree and go with the fork, and so do the guard
  algebra and the clock it keeps. read-only field paths return as places
  in the new checker, through [fields are fixed unless declared mutable].
  classes are built once, in the new checker ([compiler-written classes,
  in the new checker]).
- **the new checker replaces the fork once it is at least as sound.**
  the aim is lower cost, accepting harder transitions while keeping a
  high bar for soundness and correctness. the gate is not every ceiling
  at zero but the conditions of [the switch], and the rewrites that
  bring each ceiling to zero happen after it, in the new grammar.
- **rows and incremental checking come after the switch,** if checking
  the whole tree in one process is fast enough for the test suite. that
  is measured once expressions exist; if it is not fast enough, rows come
  back before the switch ([the order the pieces land in]).
- **declarations are the trust boundary.** a `.d.tl` signature is the
  only typing the checker takes without proof. a narrowing declaration
  ([narrowing declarations]) is taken on trust too, but a test run
  verifies it: checked narrowing covers a read narrowed by a declaration
  as it covers one narrowed by a test, so a declaration that lies fails a
  run, within what checked narrowing covers ([the switch]). the standard
  library's Lua declarations live in `.d.tl` files, so auditing them
  changes no checker logic. a bare `any` in a `.d.tl` is
  legal only on a declared untrusted-data entry point: `string.unpack`
  and the [`cosmic.sys`] bindings. a callback in a standard library
  declaration is typed with generics, not `any`, and `{string:any}` is
  not a type outside an entry declaration. a `require` of a module with no
  types is a build error, not an `any`: a Lua module needs a `.d.tl`
  that types it. a table parameter of a C binding in a `.d.tl` is a view
  unless it is declared `mut` ([collections are views unless declared
  mutable]), so what a binding may write is the declaration's word and
  no hand audit of the bindings is needed.
- **the rules are tested against programs that must be refused.** every
  hole found becomes a refused program in build/teal_test.tl, which
  already pins today's known holes (`test_as_and_is_forge_a_never_function`,
  `test_a_function_index_serves_any`,
  `test_a_callback_field_with_a_record_parameter_is_the_known_limit`). a
  step that closes a hole flips its pin from accepted to refused.
- **a test run reports the types it was promised.** under the test runner,
  the compiler can emit a run-time check of each declared parameter,
  return and record field write against the declared type's nil-ness and
  primitive kind (records are erased, so a record is checked as a table).
  it reports, and does not fail the run, until nil is out of every type:
  before then it flags legal code. the number of reports is a ceiling
  ([a count the tree cannot yet bring to zero is a ceiling]). the check
  mode is part of every compile cache key, a test proves no built
  executable carries a check, and a report names the caller's line, not
  the callee's.
- **a count the tree cannot yet bring to zero is a ceiling that only
  falls.** the run-time reports and each rule's violations over the
  translated tree are each counted per file and code, and each count is a
  ceiling kept in the build database, filled from [`build/ceilings.txt`] (data, not Teal compiled into the tool): `cosmic fix --check .`
  and a compile through [`build/driver.tl`] read the same file and refuse a count above its ceiling with the same words
  (`pinned N`). a rise fails the build, so a change cannot add what the
  tree is working to remove, and a rewrite that lowers a count lowers its
  ceiling with it. `build/compiler_test.tl` pins the frozen fork's own
  count as an exact number in its source, and the pin goes with the
  fork; the new checker's source is part of the tree and under the same
  ceilings.
- **a checker PR gets one adversarial review, and the automated gates
  carry the rest.** the review is one round, and a second only when the
  first finds a soundness bug. the fuzz properties are the automated
  gate, with mutation testing in the review, and each PR also runs a differential against
  the fork over the common idioms of the tree, which measures
  over-refusal as well as soundness: a rule that refuses what the fork
  accepted and the tree writes is a bug in the rule or a missing rewrite.
  random programs and differential runs find what review does not (see
  "what the first steps taught"). reviews and fixes cover soundness and
  correctness reachable from source, and the missing tests for them, not
  hardening against a misuse of an internal API that no caller makes. a
  prose nit rides with the next change and never starts a round of its
  own. a piece is briefed to its builder in a page, not the whole plan.
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
  the tree (build/compiler.d.tl) are designed for the language, and
  the `build/` modules that read the syntax tree are rewritten beside it.
  the fork takes only type-level syntax that is erased in the emitted
  Lua, as its `readonly` marker is, and no new statement or expression form.
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
  them. a `mut` field or collection, `T?`, a class and its methods are
  written into `decls` and the stubs as the source declares them, so a checker typing
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
  caller passed a string for a number, which then fails, as intended; a
  number passed for text fails the same way. a named-parameter table is a
  map: a record is not a map, so code that binds a record's fields builds
  the map, counted in the ceiling of [records are not maps]. an SQL function a program registers runs program code
  inside a query; under [narrowing only what nothing else can change] a
  call changes no place, so a query is an ordinary call.
- **rows decode at the accessor.** a typed accessor checks each value's
  SQLite kind, and NULL, against the type it answers, and returns the
  typed value or an error: the caller asserts no type. the row it answers
  is a table literal checked against its record type, so its fields are
  fixed, and the code that reads rows narrows them without copies. typed
  queries stay deferred (below).

### what the language builds on

- **types cross processes as rows, after the switch.** [the new checker]
  writes each module's exported types, canonicalised, as a row beside its
  stub, and a module is checked against its requirements' rows rather
  than by checking their sources again. a worker can then check any
  module, so the sharding by import closure in build/shards.tl, which
  exists because "the checker's types cannot leave a process", goes, and
  the hash of that row is what a requiring module's compile key reads: an
  edit that leaves a module's exported types alone recompiles nothing
  that requires it. only a test verdict's key keeps the source closure.
  this waits on a measurement: if checking the whole tree in one process
  is fast enough for the test suite, rows come after the switch, and if
  it is not, before ([the order the pieces land in]).
- **a module is rechecked for what it uses,** also after the switch.
  `uses` already records
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
  verdicts and the new checker's into tables, and the gate's triage is a
  join: each difference a row with the name of the rule that explains it,
  and the gate is the query that finds a row with none. the tables are
  data under [`testdata/gate/`], so that they outlive the fork: `verdicts.json`
  holds a row for each program build/teal_test.tl pins and each input
  of the checker corpora, with what the fork said (frozen) and what the
  new checker says and with which codes; `retired.json` holds a row for
  each program the fork refuses and the new checker takes, with the code
  of the rule that makes it right and a twin that the rule refuses;
  `rules.json` names the rule of each code of the lexer, the parser and
  the scope builder, which no catalog holds yet. [`lang/check_verdicts_test.tl`]
  runs the query and fails on a difference with no rule, on a program the
  fork refuses that is taken without a retired row, and on a row that is no
  longer what the checker says; `bin/cosmic build/gate_record.tl` writes the
  table again, and `cosmic sql --from` asks it anything else.
- **a pin the new rules retire is a row, not a refusal.** a program of
  build/teal_test.tl that the fork refuses because of what the fork
  lacks (`never` as a flag, joins that keep the declared type, fields that
  are never places, a receiver that is not the interface's) and that the
  new checker takes by a rule of this plan is not refused again to keep the
  pin: it is a row of `retired.json`, run in
  [`lang/check_verdicts_test.tl`], with the twin that the same rule
  refuses, one for each form the row is about, so that a change of that
  form is seen; and the program is run. a refusal at the lexer, the parser
  or the scope builder (a form the grammar cut) shows the verdict only, not
  that the rule a pin is about is held. the table leaves out the programs of
  the four parser-timing tests of build/teal_test.tl: 15 distinct
  programs of one line repeated 2000 times, which say nothing of a rule
  and whose lines name a variable `record` or `enum`, which the new grammar reserves (`unknown_variable`).
- **an optional field is a plain value, never a metamethod and never a
  generic function.** the fork refused `metamethod __index?: T` ("a
  metamethod cannot be optional") and `pick?: function<T>(T): T` ("an
  optional field cannot have a generic type"); the new checker took both for
  want of a rule, and the owner's decision is to refuse them, with the
  stricter reading: the codes `optional_metamethod` and `optional_generic`
  of [`lang/declarations.tl`], in any spelling that admits nil (`name?:`,
  `T?`, `T | nil`), and when a type parameter that a declaration makes
  optional is filled with a generic function (`Box<function<T>(T): T>` for
  `v?: X`). it is a choice and no hole: the checker narrows and calls a
  generic function that a local or a parameter holds, and lifting the decision
  is the removal of the two codes.
- **errors are catalogued.** an uncaught run-time error is already looked
  up in `catalog` and answered with the doc comment of the function that
  raised it. a checker error is catalogued the same way: each code a row
  with its rule's name, why it holds and how to fix it, indexed by FTS5, so
  `cosmic docs <code>` and the error itself read one text, and the fix an
  error prints is pinned once.

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
generic body a `T` may be nil. a nil test of a place typed `T` or `T | nil`
narrows it to `T`, never to "T without nil", which no type can say. the
standard library's declarations are audited, each of these named:
`string.match` and `string.find` (each capture `string | nil`),
`table.remove`, `rawget`, `next`, `select` and `math.tointeger`.
[pcall and coroutines are typed] states the other two families.

### an index read may be nil

a restriction. `m[k]` and `m.k` on a `{K:V}` are `V | nil`. `t[i]` on a
`{T}` is `T | nil`, because Lua answers nil for an index out of range
rather than trapping, and no refinement answers `T`: any other reference
to the array may change it between a length test and the read. a loop
over the elements is `for i, v in ipairs(t)`, which gives `v: T`, and the
error for a nil-guarded index read in a numeric `for` suggests it. an
index is not a place: a test of `t[k]` narrows nothing, and the rewrite
is `local v = t[k] if v then ... end`. a test file is held to the rule like
any module, with no exemption: it reads an index into a local and
asserts it, or uses a general accessor that raises on a miss.

a tuple type indexed by a literal in range is its member's type, and out
of range is refused. length facts (`#t > 0` giving `t[1]`) are not
tracked.

### arrays are dense

a restriction. `{T | nil}` is refused as an array type: `#`, `ipairs` and
`table.insert` are defined on a sequence, and a hole makes each
unreliable. sparse data is a map, `{integer:T}`, and `#` on a map is
refused. a map's value type does not name nil either: `{K: V | nil}` is
refused, and `m[k] = nil` is the deletion of the key, typed as such, not a
write of a value. which writes may make a hole in an array is an open
question ("open questions").

### narrowing only what nothing else can change

a restriction, with fixed fields as its extension in the new checker. one
flow analysis decides narrowing and reachability.

- a place is a local. in the new checker it is also a path of fixed
  fields from a local (`r.a.b`, with `a` and `b` each not declared `mut`):
  a field given its value by the table literal that makes the record and
  never assigned after, through any reference ([fields are fixed unless
  declared mutable]). the fork narrows only locals, since no field there
  is known never to be assigned. a global, a `mut` field and an index are
  not places, and a test of one narrows nothing; the rewrite is a local
  copy, `local n = r.n if n then ... end`, which the error gives.
- inside a function, a local of the code around it is a place only if
  nothing assigns it after the function is made. [captures are read-only]
  stops the closure assigning it, but the code that declares it can while
  the closure is suspended in a coroutine, or between two calls, so a
  test inside the closure narrows only a local that is fixed from then
  on.
- in the new checker, a fixed field is set only by the table literal that
  makes its record, and a literal with no expected type is never a record
  ([fields are fixed unless declared mutable]), so no second reference to
  it can write the field.
- a module's fixed fields are never seen before they are set: the build
  refuses a cycle of imports (compilation.ordered reports "a cycle of
  imports"), and only declarations, which run no code, may form one, so a
  module's body has run before any module that requires it.
- a `.d.tl` declaration promises that its C writes only a table parameter
  declared `mut`: a table parameter is a view otherwise ([collections are
  views unless declared mutable]). this replaces a hand audit of the
  [`cosmic.sys`] bindings, and a binding that fills a table takes a `mut`
  map or returns a fresh one.
- nothing forges a writer: there is no cast ([no casts]), and a record
  is never a map ([records are not maps]), both in the new checker. data
  typed `any` becomes a record through a [`cosmic.shape`] validator, and
  a class through `is`.
- a guard is a condition of an optional (`if x then`), `== nil` and
  `~= nil`, `==` with a literal, `is`, `type(x) == "..."`, their `not`,
  `and` and `or`, a call of a narrowing declaration, and a branch that
  ends its block. a condition is a boolean or an optional
  ([conditions are booleans or optionals]), so a truthiness test of
  anything else is refused before it can narrow.
- an assignment to a local drops what was known of it and of every path
  from it. an assignment that names the same target twice (`x, x = a, b`)
  is refused, since Lua leaves its order open. nothing else drops a fact:
  a closure cannot assign a local it does not declare, and no reference
  can assign a fixed field, so neither a call, a write through an
  alias, an operator nor a metamethod can change a place. the analysis
  keeps no list of what runs code for narrowing; [assigned before read]
  keeps the one it needs.
- a statement with no successor (`return`, `break`, a `goto` out of the
  block, a loop with no exit, a call of a `: never` function) ends its
  block. a `goto continue` to a label in the same loop does not end the
  path.

this replaces upstream's facts and the per-form narrowing and
block-ending patches; [narrowing by construction] gives it its form. the
fork's `readonly` syntax, its write refusal, its literal rules and its
interface agreement (#3081, #3083) are type-level and erased in the
emitted Lua, and go unused by the tree and with the fork. the new checker
carries the same agreement under `mut`: a record declares a field `mut`
exactly when the interface does, checked before [one variance per type
constructor] makes field types exact. [records are not maps] refuses a
record where a map is expected, so no view of the table can assign the
field.

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

### collections are views unless declared mutable

a restriction, in the new checker. a collection type in a parameter, `{T}`
or `{K:V}`, is a read-only view, deep and covariant; a callee that changes
the collection declares `mut {T}` or `mut {K:V}`. there is one `mut`
vocabulary for a field ([fields are fixed unless declared mutable]) and
for a collection, and the safe choice is the one that needs no word.

- `{T}` accepts a `{U}` when `U` is a `T`, and a `mut {U}` likewise; a
  view is never passed as `mut`. `mut {T}` accepts only `mut {T}`, since a
  callee could store a different element type through it ([one variance
  per type constructor]).
- a view is deep: an element read through `{{T}}` is itself a view of
  `{T}`, and a view of a record has fixed fields as every record does.
- through a view a program reads (`#`, an index read, `ipairs`, `pairs`,
  `next`, `table.concat`, `table.unpack`) and passes it where a view is
  expected. it never assigns an index, and never passes it as `mut`:
  `table.insert`, `table.remove` and `table.sort` declare `mut`.
- a view is erased in the emitted Lua and applies to arrays and maps only.
- a function that returns the collection it was given declares the
  parameter `mut` and answers `mut` of the same type, with a generic
  ([`Json.array`]).
- a `.d.tl` C binding's table parameter is a view unless declared `mut`,
  so the declaration states what its C writes ("declarations are the
  trust boundary").

the cost is a count of the parameters that change their collection, taken
by query before the rule lands: a parameter whose function assigns an
index, calls a `mut` function on it, or passes it on as `mut`. the
translator writes `mut` on each, as it writes it on a field the tree
assigns after creation, so the count sizes the rewrite and is no gate.

### one variance per type constructor

a restriction.

- a function is contravariant in its parameters and covariant in its
  returns.
- a `mut` array or map is invariant: `mut {T}` accepts only `mut {T}`,
  and `mut {K:V}` only `mut {K:V}`. a view is covariant ([collections are
  views unless declared mutable]).
- a record is compared by name. a field of a record that implements an
  interface has exactly the interface's type. a method, a field whose
  function names its receiver, cannot be assigned, and is compared as a
  function.
- a generic record is invariant in its type arguments. variance stays
  invariant by default: declaration-site variance is not adopted.

### generic bodies compare, pass and store

a restriction. inside a generic body a value of a type variable may be
compared with `==`, passed and stored, and nothing else: any other
operation (an order, an arithmetic operator, a call, a `..`) needs a
constraint on the type variable, and a constraint is an interface that
declares the operation. the body works on its type variable without
naming an instance, so it needs no cast ([no casts]), and a `T` may be
nil in it ([nil is its own type]).

### narrowing declarations

an extension. a function type may say that it narrows an argument to a
type when it returns true, or that it returns only when an argument is
not nil or false. `assert` and the [`cosmic.shape`] validators are then
ordinary declarations, and their special cases in the checker go. the
checker takes such a declaration on trust, as it does a `.d.tl`
signature, so it is legal in a `.d.tl`, and in Teal only where the
function's returned expression is itself a guard the checker verifies.
`type` stays special, but answers through the same narrowing.

### pcall and coroutines are typed

a restriction, in the new checker. `pcall` and `xpcall` answer a tagged
union ([tagged unions]): a success that carries the call's returns as
one tuple value, or a failure that carries the error as untrusted data, the one
`any` the call lets in ("declarations are the trust boundary"). a
coroutine is a typed `Coroutine<Y, R, S>`: `Y` is the type it yields, `R`
the type it returns, and `S` the type sent to it by a resume. a program
cannot reach raw `coroutine.*`; the standard library declares the typed
operations, and the special cases of `pcall`, `xpcall`, `coroutine.resume`
and `coroutine.wrap` in the checker go.

### tagged unions

an extension. a union of records is legal when each member has the same
field typed by a distinct single-member enum, and comparing that field
with a literal narrows the union. a chain of tests that covers every
member leaves `never` in its final branch, so a function that must return
can end there. `is` applies to primitive types, enums, `nil`, function and
table kinds, and classes; `v is R` for a record `R` that is not a class is
refused, since Lua erases the record, and the error names a tag field or
a [`cosmic.shape`] validator. `is` on a parenthesized name or field is
`paren_is`: the parentheses make it a value, so the test narrows nothing; on
any other expression it is a test of that value, which narrows nothing either.

### unions of enums are told apart by is

an extension. `E1 | E2`, a union of string enums, is a type: a value of it is
a string that is a member of one of them, and `x is E1` tells the members
apart at run time by the strings of `E1`, narrowing `x` to `E1` where it
holds and to the other enums where it does not. an enum is a nominal type,
so the union is not assignable to one of its members (`local e: E1 = x` is
`not_assignable`), and a test of an enum the union lacks is `is_disjoint`.
the fork refused the declaration, since it can tell the members of a union
apart only by `type()`, which answers "string" for all of them; `is` on an
enum tests the membership of the string, which does.

a method call on a value of an enum, of a union of enums, or of enums and
`string` resolves in `string` (`k:upper()` is a `string`, never the enum),
while the read of a member as a value (`k.upper`), a field (`k.x`), an index
and a write to a member stay refused.

### literals of the string library are read

a restriction. the pattern of `find`, `match`, `gmatch` and `gsub`, the
replacement string of `gsub`, the format of `string.format` and the format of
`string.pack`, `unpack` and `packsize`, when written as string literals, are
read as Lua reads them, and a literal Lua raises on is refused where it is
written (`pattern_malformed`, `format_malformed`, `pack_malformed`): an
unclosed capture or set, a `)` that closes none, a `%` that ends the pattern,
`%b` or `%f` without what they need, a back reference to a capture that is
not closed; a conversion `string.format` does not know, flags, a width or a
precision it does not take, or no value for a conversion; a size or an
option `string.pack` does not know, or a `packsize` of an option whose size
depends on the value. a `find` given `true` as its plain argument takes its
pattern as text and is not read. a literal is read where it is written, in a
local that is given it and never assigned, and through a local that is given
the library function and never assigned (`local find = string.find`). the
literal also types the call: each argument of `format` and `pack` has the type
its conversion or option takes (`%d` and `i4` an integer, `%f` and `d` a
number, `%s` any, `s`, `z` and `c` a string), so a call that gives another
type, too few values or too many is refused as any call is; the captures of
`find`, `match` and `gmatch` are strings, and an integer for a position `()`;
the results of `unpack` are those of its format and the position; and a
`gsub` callback takes the captures, not more than the pattern has. the table a
`gsub` looks matches up in is
keyed by the first capture, a string for the whole match or a captured text
and an integer for a position `()`, and a table keyed the other way is
`gsub_key`. a literal that is not written in the call is not read.

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
new checker makes class types nominal from its first PR, before [one
variance per type constructor] does it for every record.

the literal that makes a class's value names every field, a field not yet
known taking its empty value (`fd = -1`), or nil where the field is a `?`
field, since nothing can attach the metatable to a table built another
way. a class's fields and methods
have distinct names, since an absent field would read as the method of
its name through `__index`. `__close` takes the value and `__tostring`
returns a string, both checked; a `<close>` local holds a class that
declares `__close`, or nil. there is no inheritance. the compiler emits
the literal as one reserved form, which the patched parser compiles to a
table made with its metatable in one opcode.

### fields are fixed unless declared mutable

a restriction, in the new checker. a field of a record or class is given
its value by the table literal that makes the value (or the class's
constructor) and is never assigned after, unless the field is declared
`mut`, the same word that declares a mutable collection. a field read is then a place for narrowing by default, and a
mutable field is the visible exception: a test of one narrows nothing, and
the error gives the local copy. of the tree's narrowed field reads, 79%
are on fields never written after creation ("what the tree measured"), so
most records need no marker. the error for a write to a fixed field names
the field and its record, and says to declare it `mut` or to make a new
value. the translator that moves the tree to the new grammar writes `mut`
on each field the tree assigns after creation, read from the fork's
`uses` rows, and on each collection parameter its function changes
([collections are views unless declared mutable]). the literal rules carry over unchanged: a literal with no
expected type is never a record, and a literal of a record gives every
field a value, except a `?` field. interface agreement carries over too:
a record declares a field `mut` exactly when the interface does.

### records are not maps

a restriction, in the new checker. a record is never passed where a map
is expected, and `pairs`, `next` and `rawset` refuse it, because its
fields have types of their own. `{string:any}` is no type outside an entry
declaration, so it is no way around the rule. a record type is not an
index type: `r[k]` is legal only where `k`'s type is a literal, an enum or
a union of them naming fields of the record.

### an enum index reads the union of its fields

an extension. `r[k]` on a record, where `k` is an enum, or a union of
enums, each of whose values names a field of the record, reads the field the
value names, and its type is the union of the types of those fields. the
union is below neither field's type alone, so the read is compared or tested
before it stands where one of them is wanted (`local n: integer = r[k]` is
`not_assignable`), and a value of the enum that names no field of the record
is `field_unknown`. a write through such an index is `record_index`, since
it names no one field and a value of one field's type could land in another.
the fork refused the index when the fields had different types; the union
loses no information, since a read can only answer the field its value
names.

### conditions are booleans or optionals

a restriction. the condition of an `if`, `while` or `repeat ... until`,
the operand of `not`, and an operand of `and` or `or` that is tested must
be a `boolean` or a `T?` where `T` is not a boolean. a string, a number, a
table or any other type is refused, and the error gives the explicit test:
`s ~= ""`, `n ~= 0`, `x ~= nil`. a `boolean?` is refused too, since nil
and false would not be told apart; the error gives `== true` or `== nil`.
a condition of a `T?` is a nil test and narrows as one. the count of
tests of other types is taken by query before the rule lands, and the
rewrite writes the explicit test each error names.

### honest `or` and `and`

a restriction. an operand `or` or `and` tests is a condition
([conditions are booleans or optionals]). `a or b` with both operands
`boolean` is logical or and is accepted. `a or b` with `a: T?` for a `T`
that is not boolean is the default-value form and is accepted. any other
mix is refused, since `or` replaces false as well as nil: `a` that may be
`false` with a `b` that is not boolean, or `a: boolean?`. the error gives
the explicit form, `if a == nil then` or `== nil`. `c and x or y` stays
refused as a ternary, since the expression answers `y` when `x` is false
or nil; the `if` expression replaces it, and the error says to use one.

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

### no casts

a restriction: the new grammar has no `as`. a type changes only by a
check the checker can see: `is` (a class, a tagged union's tag, a
primitive kind), a guard, a narrowing declaration, or a function that
checks and answers the type, such as a [`cosmic.shape`] validator for data
typed `any`. a value of a userdata record comes typed from its `.d.tl`
declaration, and a generic's body works on its type variable without
naming the instance. of the tree's 1,624 casts, 666 are from `any` and
become validators, and most of the 958 others exist to get past nil,
narrowing and variance, which the other rules make unnecessary;
230 of the 290 outside tests are in the checker's own source, which [the
new checker] replaces. until the switch the translated tree is only
checked, never committed. the translator writes each remaining cast as a
form the new checker parses only to refuse as a cast, counted under the
no-casts ceiling, and its error names the check that replaces it. the
new checker's verdicts on the translated tree then guide the rewrite of
the source: a cast becomes a validator, `is` or a guard, or is deleted
once nil, narrowing and variance make it unneeded. the translation form
goes when the no-casts ceiling reaches zero: the final grammar has no
`as`.

### numeric keys are integers

a restriction. a key of a map and an index into an array are `integer`,
never `number`: a float key faults on NaN, and `1.0` folds to `1`, so a
key read back is not the key written. a float is converted by
`math.tointeger` or `math.floor` before it indexes, and the error says so.

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

- a string is never a number, and a number is never a string:
  arithmetic on a string and a string `for` bound fail in the VM, not only
  in the checker, so data typed `any` fails at the operation, and `..`
  takes strings only: a number needs `tostring` or `string.format`
  (`"line " .. tostring(n)`). Lua already has the switches,
  `LUA_NOCVTS2N`, which also drops the string metatable's arithmetic, and
  `LUA_NOCVTN2S`, which also changes the C API's `lua_tolstring` so it
  answers no string for a number; a `patch/lua/` record sets both in
  `luaconf.h`, which every unit that includes Lua sees, the core's C
  included. the cost is about 100 to 200 `..` sites outside tests, and
  those in tests besides, and the core's C that reads a number as a string.
- a program's globals are exactly what a `.d.tl` declares, and the
  surface [`core/surface.c`] opens is those names and no others. anything
  undeclared is not reachable by a program, among it `debug`, `loadfile`,
  `dofile`, `package` (its searchers and loaders), `rawequal`, `rawlen`
  and `collectgarbage`. the checker refuses an undeclared name; where a
  removed name once existed, [`core/surface.c`] answers with the stand-in
  it gives `io` and `os` now, whose error names what to use instead.
- a program has no `setmetatable`, `getmetatable`, `rawset`, `rawget`,
  text `load` or `string.dump`, since a `.d.tl` declares none of them for
  a program. code the compiler emits reaches the VM through its reserved
  form; the build's compile and test harness, and the validators of
  untrusted data ([`cosmic.shape`], [`build/confine.tl`]), reach `load`
  and a raw field read through a raw value only a trusted module receives.
  so everything a program runs came through `require` and the checker.
  until the pin carries [compiler-written classes], the checker's own
  Lua, compiled by the seed, still calls `setmetatable`, `rawset` and
  `load`, and the boot keeps them in its environment.
- `_ENV` is a reserved name: a program cannot declare it (`local _ENV`, a
  parameter, a field of a record) or assign it, and the new checker
  refuses both. a file run by `cosmic --standalone` is checked before it
  runs and is refused on a type error, so no file a program runs escapes
  the checker; the check is cached by content hash in the build database
  like any compile, so a repeated run pays nothing. the runtime cut lands
  that check.
- a table a program makes has no `__gc` and no `__mode`, which needs no
  change to `lgc.c` once only the compiler and C attach metatables; a C
  userdata keeps its `__gc`, and a weak table is made in C.
- `_G` cannot be replaced, assigned through, or given a metatable.

each is counted over the tree first, and a build with the switch on runs
the whole test suite before the rewrite starts, since a removed coercion
fails at run time, in Teal or in the core's C, not at compile time. each
lands with the rewrite of what it finds.

### not adopted

`any` is legal only where untrusted data enters, and the checker refuses
to assign it, call it or index it. data only enters it: a record, a
class is never assigned to `any`, so no round trip through `any` can write
a field behind its type. code that needs a value of any type uses a type
variable or a tagged union, and an encoder takes the type it encodes.

rejected, so nobody proposes them again: a non-nil assertion `x!` (an
escape hatch; `assert(x)` says why), `a?.b` (the tree's field paths are
almost all non-nil), a `??` operator ([honest `or` and `and`] refuses the
hazard instead), bounded generics over primitive types, declaration-site
variance (`record Box<out T>`), narrowing a mutable field (a local copy
is the rewrite), narrowing only stable locals (1,070 error lines in 203
files, and assignment already drops a local's fact precisely),
locals that are immutable by default (considered and not adopted, since
narrowing a reassigned local is already sound: an assignment drops its
facts), a typed `setmetatable` ([compiler-written classes] removes it),
and the compiler writing bytecode. each waits for a measured need.

deferred until the new checker replaces the fork, and decided then:
typed queries, in which SQLite's own parser checks each literal query
against the schema of the database it runs on and types the row it
answers. how a handle names its schema is the question it waits on.

## what the tree measured

the numbers below come from the reviews of this plan, by running the
checker over the tree with logging, or by heuristics where stated. they
size the steps; once [every count is a query](#what-the-language-builds-on),
each step measures again with the checker's own rows before it lands.

- **array index ([an index read may be nil]).** 10,719 index reads: 6,310
  on arrays, 4,613 of them in tests. about 27% are already nil-checked
  where they stand. the loop and guard patterns covered about 13% of the
  rest; the loop reads are rewritten to `ipairs`, which gives `T`, since no
  loop refinement remains. the largest remainder outside tests was a fixed-width row read by
  a constant index (`row[1]` from a [`Sqlite.rows`] result, about 520
  reads). rows are read through typed accessors, so these reads are gone.
  about 4,613 test reads by index remain, each rewritten to a local and
  an `assert` or a general accessor that raises.
- **variance ([one variance per type constructor]).** about 1,420 places
  compared a container covariantly. 1,344 are `table.concat` of a
  `{string}` against its `{string | number}` declaration; three option
  signatures (`fds`, `gsub`'s table, `flags`) hold most of the rest.
  every callee reads only, except [`Json.array`], which returns its
  argument and needs a generic. no array of records passes as an array of
  an interface. the parameters that change their collection, which
  [collections are views unless declared mutable] marks `mut`, are not yet
  counted; a query over the type report counts them before the rule lands.
- **narrowing a field ([narrowing only what nothing else can change]).**
  of about 1,080 guards on a field path, at most 76 call a function in the
  guarded body and read the path again (heuristic). the fork copies all of
  the 752 narrowed field reads below (609 outside tests) to locals. 79% of
  them are on fields never written after the table is made, which fixed
  fields keep as places in the new checker; the rest, about 160 reads,
  keep their local copy. parsed syntax nodes, filled after they are made,
  and `self` state are most of the rest.
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
  sites outside tests join a number with `..`, mostly in error messages,
  and each takes a `tostring` or a `string.format`; tests add more. string
  arithmetic cannot be counted by text and is counted by a build with the
  switch on.
- **not yet counted.** tests of a condition that is neither a boolean nor
  an optional ([conditions are booleans or optionals]), float map keys
  ([numeric keys are integers]) and uses of raw `coroutine.*` and `pcall`
  ([pcall and coroutines are typed]) are counted by query over the type
  report before each rule's rewrite.
- **narrowing by construction,** measured on `origin/main` at e95cd66f4:
  12,513 narrowed reads, 752 of them field reads (609 outside tests) on 557
  places, 79% of them on fields never written after creation; 1,182
  function literals that assign an outer local, all since rewritten for
  [captures are read-only]; `setmetatable` 163 calls (67 on a record that
  declares metamethods, 70 on one that declares none, 64 of them the
  class-method `__index = R` pattern, and 25 untyped); casts 1,624, of
  which 958 are not from `any`: 290 outside tests (230 in the checker)
  and 668 in tests; `rawset` 11, `rawget` 29, `debug.*` 3 (all in the
  checker).
- **the checker's own source.** 314 type errors under its own rules,
  pinned as an exact count by `build/compiler_test.tl` until the fork
  goes. it has about 94 free locals, short of Lua's limit of 200.
- **nil ([nil is its own type], [assigned before read]).** the rewrite of
  every directory outside `checker/` cost less than planned.
  `--check-types` finds what a call or return passes, but not a local or a
  field omitted from a table literal; those stay honest only once the new
  checker counts them ([the rewrites to zero]). heuristic floors: about 80 `return nil` in
  functions declared to return non-nil, about 460 `local x: T` with no
  value, and 39 `table.remove` and 36 `select` calls. the uncounted class
  is nil passed as an argument or written to a field. the tree already
  writes about 3,000 `| nil` types and 1,100 `?:` fields. the checker's
  own source writes none and relies on nil being in every type.

## the steps, in order

each step is one or more PRs that follow
[doc/contributing.md](../contributing.md): each stands alone, passes CI,
and has a test that fails without it. a rule of the new checker is held
from the PR that adds it, and its step after the switch is the rewrite
that brings its ceiling to zero. each PR states the change in boot time
and in the checker's self-compile time. every checker PR follows the
review practice in "decisions": one adversarial review round, and a
second only when the first finds a soundness bug. a piece is briefed to
its builder in a page, not the whole plan.

### done

- the checker moved into the tree, compiled at boot (#3032).
- structured errors, and the Lua library's declarations in `.d.tl` files
  (#3033, #3039).
- run-time checks in test runs (#3040).
- the flow analysis as checker modules: reachability, places and guards,
  drops (#3041, #3044, #3050).
- [assigned before read] (#3061), [captures are read-only] (#3067) and
  [goto only as continue] (#3066).
- checker fuzzing: random programs through the checker, and a
  differential against a pinned corpus, on [`build.fuzz`] (#3060, #3062).
- checked narrowing and the program shapes narrowing bugs lived in
  (#3077, #3078).
- the row-accessor pin move (#3051, #3056).
- [the switch]: the new checker replaced the fork, and the tree is written in the new grammar.

### narrowing by construction

done: the verdict harness (#3070), the facts module (#3069), shadow mode
(#3074), the narrowed field reads copied to locals (#3088), the old
narrowing restricted to locals (#3089), reads from the facts (#3092) and
the old narrowing deleted (#3096). shadow mode found four unsound
acceptances in the old narrowing, fixed in #3071, #3072, #3073 and #3075.

what landed in the fork:

- declared types are never mutated. an immutable map from a binding's
  identity to its narrowed type (`checker/facts.tl`) is one register of
  the checker's in-order walk, so a shadowing name is a new binding. a
  read is the declared type met with its fact.
- a place is a local, and a fact is dropped only by an assignment to it.
  a call, an alias, an operator or a metamethod drops nothing, and a
  field narrows nothing: the 752 narrowed field reads (609 outside
  tests) were copied to locals. a function body keeps a local of the code
  around it only if nothing assigns it after the function is made.
- `specialize_var`, the scope markers and the shadow comparison are gone.
  the verdicts the switch moved are pinned in
  build/checker_facts_reads_test.tl.

what was dropped: the refinements that accept more (one flow pass,
function declarations keeping local facts, joins that unite types, the
loop edge rule) are built once, in the new checker, and the guard algebra
and the clock stay in the frozen fork until it goes.

### the pinned-release seed

done: a compile verb in the release (#3079), the pin move (#3080), boot
from the seed (#3082), and `vendor/tl/` and the standalone shims removed
(#3084). boot compiles the checker in two stages, the seed's and then
the checker's own, and the tool carries the second. `checker/SEED_DIFFERS`
lists the files the emitter has moved ahead of the pin.

### compiler-written classes, in the new checker

[compiler-written classes] and [dispatch only through declared types],
built once, here and not in the fork. the new checker compares classes by
name from its first PR and checks a class literal that names every
field; its code generator emits the reserved class literal, and the
patched parser gains that form and its opcode. the translator writes the
tree's class pattern (`setmetatable(o, R)` with `R.__index = R`) as a
class where it can, and the sites it cannot are the rule's ceiling.

the tree's other metatables are few outside tests: four `__mode` tables,
two proxies with function `__index`, one `__tostring`, two `__gc` safety
nets on process handles, and the array marker the JSON decoder attaches
in C ([`core/json.c`]). a rewrite after the switch gives each its class
form, except the two process handles ([`Child.Handle`] and the
connector's process), which become C userdata with a `__gc` that kills
and reaps a child its handle was dropped without closing; the class form
holds only Teal state, and a handle that must not leak is a resource C
owns. the JSON array marker stays: `core/json.c` attaches
[`cosmic.json.array`] to a decoded array, and `Json.array` to a table a
program marks, so an empty `[]` encodes back as `[]`. it has no
metamethods, and once a program has no `getmetatable` it cannot see it.
then `setmetatable`, `getmetatable`, `rawset` and `rawget` leave the
surface a program sees ([the runtime cut]). the new checker's own source
keeps the `setmetatable` dialect until the pin names a release that
carries it.

### the new checker

written for the language the foundations leave, not forked from
`checker/tl.tl`, at about 10,000 to 13,000 lines against the fork's
22,000. it starts now, beside the frozen fork, and holds each
foundation's final form. it holds the strongest default of every other
rule from its first PR: fixed fields, records that are not maps, no `as`,
nil out of every type, conditions that are booleans or optionals,
collections as views, and classes the compiler writes are its only
relations. a sketch, not a design:

- its grammar is designed first ([the draft](new-checker-grammar.md)), with the syntax tree and the interface
  that about twenty `build/` modules read (`build/ast/`, the analyzer,
  stubs, docs, links, scopes); those modules are rewritten to it beside
  the checker, not after. what it keeps of the fork's contract is what the
  rest of the tree relies on: tokens with comments, warnings, error codes,
  line-preserving output, the `--check-types` and checked-narrowing code,
  and every row the checker writes into the database ("what the language
  keeps working").
- its type system is drafted in [the types draft](new-checker-types.md).
- the grammar holds `mut` on a field ([fields are fixed unless declared
  mutable]) and on a collection ([collections are views unless declared
  mutable]), and no `as` ([no casts]); the translator writes a remaining
  cast as a form the checker refuses and counts, so a cast never survives
  the gate. beyond that, provisionally, beyond Teal's: an `if` expression
  (`if n == 1 then "item" else "items" end`), which gives the 800 or so
  `and`/`or` ternaries a form that cannot answer the wrong branch when
  the middle value is false or nil; `match` over a tagged union, refused
  when a member is missing, so exhaustiveness is checked in one place,
  not in `if` chains; a `class` declaration holding a class's fields,
  `mut` markers and methods in one place, which [compiler-written
  classes] needs to read plainly; and `T?` as syntax of its own. it drops
  `goto` (a `continue` takes its one allowed use) and the `and`/`or`
  ternary. each of these is confirmed or dropped when the grammar is
  written. files in the
  new grammar keep `.tl`: the tree holds one language, and no path rule,
  glob or importer changes with the grammar.
- a translator comes with the grammar: it rewrites a Teal module into the
  new grammar, and is how the tree moves to it. it runs from the first PR
  as a build step whose output is not committed, and the new checker's
  counts are taken over that output; the change that replaces the fork
  commits it. it writes `mut` on each field the tree assigns after
  creation and on each collection parameter its function changes, and
  writes each cast as a form the checker refuses. it is also the oracle a drop-in parser
  would have been: where the new grammar only respells a construct, the new
  checker's Lua for the translated module is byte-identical to the fork's
  Lua for the original, over the whole tree, so the parser and code
  generator are checked before any type rule is. the oracle is needed
  only until the switch. a construct whose meaning
  changes is listed, and its emitted Lua is compared by the test suite
  instead.
- one pass builds a control-flow graph that narrowing and definite
  assignment both read, with facts keyed by binding; there is no
  metamethod or "runs code" reasoning, because the foundations left
  nothing for it to decide.
- one subtype relation with its variance. nil is a type of its own and
  `never` is below it from the first PR, so `T` admits no nil, and a
  collection is a view unless `mut`, from the first PR. the tree does not
  obey these yet; the rules count their violations as ceilings.
- one ceiling per rule: the new checker writes each rule's violations over
  the translated tree into the build database, per file and code, and
  each count is a ceiling that only falls, a new violation being refused
  ([a count the tree cannot yet bring to zero is a ceiling]). the rewrites
  ([the rewrites to zero]) bring each to zero after the switch.
- each error a code, its places and the fix, catalogued, from the first
  PR.
- after the switch, and only if checking the whole tree in one process is
  fast enough for the test suite, types cross processes as rows, and a
  requiring module is recompiled only when the hash of what it reads
  moves ("what the language builds on").
- its gate to replace the fork is [the switch].
- its own source is written in Teal, in what the pinned release's checker
  accepts, since the seed compiles it and the seed parses only Teal until
  a release carries the new checker. once the pin moves to that release,
  its source is translated like the rest of the tree, and from then on it
  compiles itself to a fixed point, one pin move behind its own grammar as
  the fork is behind its own rules.

### the switch

done. the new checker replaced the fork in one change, on the branch `the-switch`, after it met the gate below, and the
tree is written in the new grammar. the fork is gone from the tree: `checker/`, the forked checker's modules
(`build.teal`, `build.ast`, `build.analyzer`, `build.compilation` and what read them), its formatter, the refusal gate
and the worker that compared the two. what the change did, and what it decided:

- **the gate.** the new checker was at least as sound as the fork, not at every ceiling zero. every program pinned in
  the fork's corpus was refused by a rule of this plan or accepted because a sound rule of this plan admits it (a row of
  [`testdata/gate/retired.json`] with the rule's code); every verdict it gave differently was a row of the verdict tables
  tied to a named rule; the fuzz soundness properties and checked narrowing ran against it; the C bindings are typed from
  the `.d.tl` declarations the build derives, so the error-slot rules see the calls into [`cosmic.sys`]; and the calls
  the contracts judge have a callee or are counted under the `[untyped]` ceilings of [`build/ceilings.txt`], which
  follow from the pinned `[checked]` errors and fall with them. the gate's evidence stays in the tree: the verdict
  tables, the retired pins, [`lang/check_flow_fuzz_test.tl`], [`lang/check_total_fuzz_test.tl`],
  [`lang/check_assigned_fuzz_test.tl`] and [`bin/gate-sweep`], whose result is [`testdata/gate/sweep.txt`]. the fork's
  answers to the programs the tests compared are kept as text beside the cases ([`lang/forked.tl`]).
- **one grammar.** the tool reads the new grammar and no other. `COSMIC_GRAMMAR` takes `new` or nothing; `teal` and
  `cosmic compile --grammar teal` are refused, naming `cosmic migrate`, which translates a project and is kept for one
  release as a user-facing verb and then goes. a project outside the tree is a hard cutover: it compiles with the
  new checker, with no fork to fall back to, against the declarations of the standard library the tool carries
  ([`lang/stdlib.d.tl`], [`lang/prelude.d.tl`]), and has no ceilings, so every error refuses. a form of the old grammar
  that it meets carries the new checker's fix ([`build/error_catalog.tl`], [`build/removed_fix.tl`]).
- **the tree.** the translated tree was committed: every file is in the new grammar, and the ceilings were derived again
  over it (`[checked]`, `[declared]`, `[scoped]`, `[untyped]` and `[examples]`), so a new violation is refused and the
  rewrites that bring each ceiling to zero are free of the fork's grammar. the islands (`ci/`, the bootstrap scripts
  of `build/` and `bin/`) are read by the pinned release in the new grammar ([`bin/cosmic-bootstrap`] and the CI driver's
  wrapper set `COSMIC_GRAMMAR=new`), and what they cannot yet spell waits on the pin (`bin/cosmic todos
  '"cosmic-driver.pin"'`).
- **the boot.** the bridge compiles the files of [`build/seed.txt`] with the pinned release as the seed, compiles them
  again from the tree, and builds the tool with the second; `lang/SEED_DIFFERS` names the files a generator change
  ahead of the pin makes differ. no stage reads the fork.
- **the readers.** `cosmic fix`, the tree checks, the language server, the doc and link readers, coverage, the
  sandbox's closure and the template compiler read the syntax tree of the new grammar. `cosmic fix` reads and checks
  and has no layout for the new grammar: the owner's decision is to delete the fork's formatter with it and to write
  one over the new tree later (a `TODO:` in [`build/fix/init.tl`]), so `cosmic fix --check` cannot tell a badly laid-out
  file until then.
- **a declaration beside its source** (`foo.d.tl` and `foo.tl`) is one module, as in a build: a `require` reads the
  declaration and the source is compiled as its implementation. two sources or two declarations for one module are
  refused (`cosmic compile` names both).
- **a `#!` first line** is accepted by the lexer and skipped, as Lua skips it:
  it is no token and no comment, so every later token keeps its line.
- **the rehearsal is gone.** the CI job that booted a second tool with the new checker, ran the suite on it and held its
  failures to `testdata/gate/rehearsal.txt` was deleted with that list, its phases of the CI driver and the cancel job's
  exemption for it: the suite runs on the tool itself, on every leg. the projects it built (`testdata/projects/`) are
  fixtures of the tool tests.
- **the bill of materials** keeps tl for the standard library's declarations, which were written from tl's.
- **found by the port.** running the new checker over the whole suite's fixtures showed a real defect, fixed: the
  analyzer split lines at LF alone where the lexer breaks at CR and CRLF too, which crashed `analysis_of` on a file with
  a lone CR (`lines_of`, and the language server's columns, now follow the lexer's breaks). the rest were fixtures
  written in forms only the fork read, ported to the new grammar with the new checker's words asserted.

what remains of the switch is bookkeeping with a home of its own: the `where` clauses of [`lang/ast.tl`] and
[`lang/types.tl`] become tags (about 900 tests of a node kind, a `TODO:` in each file); `cosmic migrate` goes in the
release after this one; and the TODOs that wait on the pin move are listed by `bin/cosmic todos '"cosmic-driver.pin"'`.

#### owner decisions

decided; the code follows in the changes that name them, and a gap that remains carries a `TODO:` in the code.

- **the error-handling contract rules hold for every project, not only
  cosmic's own tree.** the rules of the error-slot discipline
  ([`build/syntax_contracts.tl`], the third principle of
  [design.md](../design.md)) are part of the language the tool checks, not a
  house rule of the tree: a project that the tool compiles, tests or checks is
  held to them by default, with the same words and the same fix. a project has
  no ceilings ([the switch]), so every breach refuses. the exemptions of
  [`build/contract_rules.tl`] name functions of cosmic's own files and give a
  project none: a project has no exemption, and fixes the code. the same
  holds for `ci/`, which [`build/contract_rules.tl`] leaves out.
- **`cosmic fix` checks and does not reformat until the formatter lands.**
  see "the readers" above. the language server offers no formatting either
  ([`build/lsp/session.tl`]), and no stand-in layout is written, so no file is
  laid out twice. the formatter is written over the syntax tree
  ([`build.syntax_node`]).
- **the formatter.**
  - it keeps the tree's style exactly.
  - a block is written on one line only if it ends by column 100; nothing else
    is wrapped.
  - the author's spacing inside a type is kept.
  - an if-expression authored flat stays flat; otherwise its `elseif` and
    `else` go on continuation lines. match arms are laid out like if arms.
    class members are indented like record members.
  - the redundant parentheses of `(x.kind == "K")` that the translator wrote
    are stripped in a separate rewrite that changes no layout.
  - line endings are `\n` and a run of blank lines is capped at one.
  - the change that lays the tree out is a single PR, named in
    `.git-blame-ignore-revs`, under a short merge freeze. right after it
    `cosmic fix --check` fails a file whose layout differs; before it, it only
    notes it.
- **tagged unions.** the tag enum of a member may have several values,
  provided no value is in two members ([`Types.Atom`] is one such member). the
  wording of the rule is with the change that implements it.
- **tag aliases.** an alias of a tag (`local kind = n.kind`) and a dispatch
  table keyed by one are written as direct compares. nothing narrows through
  an alias.
- **enum methods.** a method call on a value of an enum, or of a union of
  enums, resolves in `string`. a `.` read of a string function, an index and a
  write stay refused.
- **boundary checks.** `--check-types` checks declared parameters, returns and
  field writes as a report that fails nothing, first, to count the real
  violations over the suite. the level set after that is the strictest that is
  honest: zero tolerance everywhere if the count is small; otherwise a ratchet
  that fails above a ceiling per file, with zero for `cosmic/` and for a new
  file, driven to zero. the tests of declared boundaries skip until the checks
  are compiled in ([`build/type_watch.tl`]).
- **the docs pointer.** the pointer to the documentation on an argument's type
  error applies to a call of any function, not only of the standard library's.
- **`pcall(require, "<literal>")`.** it is a dependency edge, followed as a
  `require` is. a `require` of a computed name of a project module is refused
  at build time, with an error that says what to write (the `TODO:` in
  [`build/embed.tl`]).

### the rewrites that bring each ceiling to zero

the new checker counts each rule's violations over the translated tree,
per file and code, and each count is a ceiling that only falls. after the
switch, a rewrite is one or more PRs that bring one ceiling to zero. it
counts the sites by query first, which sizes the rewrite and is no gate,
rewrites the tree in the new grammar, one directory at a time with its
tests, and lowers the ceiling in the same PR. the rewrites are
independent and land in the order their counts allow; the language is
whole when all are at zero.

- **nil out of the tree.** [nil is its own type], [an index read may be
  nil], [arrays are dense], [never is the bottom type] and [varargs end in
  nil]. the declarations audit comes first, then the count from the new
  checker; the arrays whose element
  type names nil are in it. `--check-types` cannot see a local or a field
  a literal leaves out, so the new checker is what verifies the rewrite.
  the nil error names the call that answered nil and its declaration,
  since the rule multiplies it.
- **collections as views.** [collections are views unless declared
  mutable] and [one variance per type constructor]. the count of
  parameters that change their collection comes first. the translator
  writes `mut` on them, `table.concat` and the three option signatures
  take views, and each `.d.tl` C binding declares `mut` on a table its C
  fills.
- **fixed fields and records that are not maps.** [fields are fixed unless
  declared mutable] and [records are not maps]: the translator writes
  `mut` where the tree assigns a field after creation, and the
  record-as-map sites are counted and rewritten.
- **conditions that are booleans or optionals.** [conditions are booleans
  or optionals]: each test of another type is counted and written as the
  explicit test its error names.
- **receivers, narrowing declarations and tagged unions.** [named
  receivers], [narrowing declarations] and [tagged unions], each with its
  count over the tree first.
- **honest operators, numeric keys, parameters and generic bodies.**
  [honest `or` and `and`], [numeric keys are integers], [annotated
  parameters] and [generic bodies compare, pass and store], each with its
  count first.
- **typed protected calls and coroutines.** [pcall and coroutines are
  typed]: each `pcall` site handles the tagged union, and each use of raw
  `coroutine.*` moves to a `Coroutine<Y, R, S>`.
- **no casts.** [no casts]: the new checker's refusals of the translated
  casts guide the rewrite of the source, to validators, `is` or
  guards, or deletion where nil, narrowing and variance make them
  unneeded, until the no-casts ceiling is zero.
- **rows decode at the accessor.** the typed row accessors check each
  value's SQLite kind and NULL against the type they answer ("what the
  language keeps working"), and the caller's assertions of a row's types
  go.

### the runtime cut

it lands [no implicit conversion or hidden code], in parts:
string-to-number and number-to-string coercion out of the VM, the surface cut to the globals a
`.d.tl` declares (no text `load` or `string.dump` for a program among
them), a standalone run that checks its file, no `__gc` or `__mode` on a
program's tables, and a fixed `_G`. it depends on the classes, which the
new checker builds ([compiler-written classes, in the new checker]), and
on no piece after them. so the parts that take `setmetatable`, `__gc` and
`__mode` from a program wait for the classes and land after the switch,
while coercion and the checked standalone run wait on neither. each part
lands with the rewrite of the sites it counts; the checker's own source
is free of string arithmetic and of `..` on numbers before the switch,
since the seed's Lua runs on the tree's VM.

## open questions

- **`defer`.** whether the grammar earns a `defer` form for the six
  per-call `__close` guards, revisited once they have been written as
  small classes with `__close` and a `<close>` local.
- **the narrowing declaration's syntax.** it must read in a `.d.tl` and in
  `cosmic docs` as plainly as a return type does.
- **collections outside parameters.** whether `{T}` as a local, a field or
  a return type is a view too, and the type of an array or map literal,
  since a collection a function builds and changes must be `mut`.
- **multiple returns as a value.** how the grammar and the type language
  represent a call's returns as one tuple value, which the success case of
  `pcall` needs ([pcall and coroutines are typed]).
- **the constraint's syntax.** how a generic declares the interface its
  type variable satisfies ([generic bodies compare, pass and store]).
- **strict-record checks in debug runs.** whether they come before or
  after the switch.
- **holes made by an index write.** whether an array write is only
  `t[#t+1]`, `table.insert` or an index proven in range, since any other
  write can make a hole in a sequence ([arrays are dense]).

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
- **a rule sees only what is typed.** the contracts the fork enforces on C
  bindings are invisible to a checker that leaves the bindings untyped,
  and a call with no callee is judged by nothing. hence the bindings typed
  and the calls without a callee counted in [the switch].

[a count the tree cannot yet bring to zero is a ceiling]: #decisions
[annotated parameters]: #annotated-parameters
[collections are views unless declared mutable]: #collections-are-views-unless-declared-mutable
[conditions are booleans or optionals]: #conditions-are-booleans-or-optionals
[generic bodies compare, pass and store]: #generic-bodies-compare-pass-and-store
[numeric keys are integers]: #numeric-keys-are-integers
[pcall and coroutines are typed]: #pcall-and-coroutines-are-typed
[the rewrites to zero]: #the-rewrites-that-bring-each-ceiling-to-zero
[arrays are dense]: #arrays-are-dense
[assigned before read]: #assigned-before-read
[captures are read-only]: #captures-are-read-only
[checker fuzzing]: #done
[compiler-written classes]: #compiler-written-classes
[compiler-written classes, in the new checker]: #compiler-written-classes-in-the-new-checker
[no casts]: #no-casts
[fields are fixed unless declared mutable]: #fields-are-fixed-unless-declared-mutable
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
[no implicit conversion or hidden code]: #no-implicit-conversion-or-hidden-code
[one variance per type constructor]: #one-variance-per-type-constructor
[records are not maps]: #records-are-not-maps
[tagged unions]: #tagged-unions
[the new checker]: #the-new-checker
[the order the pieces land in]: new-checker-types.md#the-order-the-pieces-land-in
[the runtime cut]: #the-runtime-cut
[the switch]: #the-switch
[the pinned-release seed]: #the-pinned-release-seed
[varargs end in nil]: #varargs-end-in-nil
[`bin/perf`]: ../../bin/perf
[`bin/vendor`]: ../../bin/vendor
[`bin/zig`]: ../../bin/zig
[`build.fuzz`]: ../../build/fuzz/init.tl
[`ci/islands.txt`]: ../../ci/islands.txt
[`build/pipeline.tl`]: ../../build/pipeline.tl
[`build/error_catalog.tl`]: ../../build/error_catalog.tl
[`build/removed_fix.tl`]: ../../build/removed_fix.tl
[`lang/stdlib.d.tl`]: ../../lang/stdlib.d.tl
[`lang/prelude.d.tl`]: ../../lang/prelude.d.tl
[`lang/ast.tl`]: ../../lang/ast.tl
[`lang/types.tl`]: ../../lang/types.tl
[`lang/forked.tl`]: ../../lang/forked.tl
[`build/seed.txt`]: ../../build/seed.txt
[`build/fix/init.tl`]: ../../build/fix/init.tl
[`build/paths.tl`]: ../../build/paths.tl
[`build/perf.tl`]: ../../build/perf.tl
[`build/vendor.tl`]: ../../build/vendor.tl
[`build/verify_codesign.tl`]: ../../build/verify_codesign.tl
[`build/zig.tl`]: ../../build/zig.tl
[`build/ceilings.txt`]: ../../build/ceilings.txt
[`lang/check.tl`]: ../../lang/check.tl
[`lang/fact_wraps.tl`]: ../../lang/fact_wraps.tl
[`build/driver.tl`]: ../../build/driver.tl
[`build/confine.tl`]: ../../build/confine.tl
[`bin/gate-sweep`]: ../../bin/gate-sweep
[`testdata/gate/`]: ../../testdata/gate
[`testdata/gate/sweep.txt`]: ../../testdata/gate/sweep.txt
[`lang/check_verdicts_test.tl`]: ../../lang/check_verdicts_test.tl
[`lang/declarations.tl`]: ../../lang/declarations.tl
[`lang/check_flow_fuzz_test.tl`]: ../../lang/check_flow_fuzz_test.tl
[`lang/check_total_fuzz_test.tl`]: ../../lang/check_total_fuzz_test.tl
[`lang/check_assigned_fuzz_test.tl`]: ../../lang/check_assigned_fuzz_test.tl
[the verdict harness is tables]: #decisions
[a pin the new rules retire is a row, not a refusal]: #decisions
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

[`bin/cosmic-bootstrap`]: ../../bin/cosmic-bootstrap
[`build.syntax_node`]: ../../build/syntax_node.tl
[`build/contract_rules.tl`]: ../../build/contract_rules.tl
[`build/embed.tl`]: ../../build/embed.tl
[`build/lsp/session.tl`]: ../../build/lsp/session.tl
[`build/syntax_contracts.tl`]: ../../build/syntax_contracts.tl
[`build/type_watch.tl`]: ../../build/type_watch.tl
[`Child.Handle`]: ../../cosmic/child.tl
[`cosmic.json.array`]: ../../cosmic/json.tl
[`testdata/gate/retired.json`]: ../../testdata/gate/retired.json
[`Types.Atom`]: ../../lang/types.tl
