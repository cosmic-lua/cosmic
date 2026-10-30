# testing

How to write a test for cosmic and how `cosmic test` decides to run it.
The authoritative detail lives in the modules this doc links. This doc
gives the rules an author acts on.

## where tests live

A test is a top-level `local function test_*` in a `*_test.tl` file
([`cosmic.layout`]). Do not add a top-level `return` to a test file.

Write small regression cases that fail for the reported bug. Do not
pin incidental implementation.

Run the tests of what you changed with `bin/cosmic test <files>`: seconds
to half a minute. Run the suite, `timeout 2700 bin/cosmic test`, before
pushing. Most tests stand (below), so it takes about half a minute where
nothing has changed, and about 8 minutes in a fresh worktree, where few
verdicts stand. A run over ten seconds says `test: running n/m tests`
as it goes.

A parser that reads untrusted bytes also gets a fuzz test (below). An
example (`*_example.tl`) shows use and is held to fewer rules.

## verdicts and when a test reruns

Each test has a key. The key is made of what the test declares: its
import closure, its [`Test.policy`], their contents, the core and the
host. A test whose key has a passing verdict stands. It is not run
again.

Checkouts on Linux share passing verdicts through
`~/.cache/cosmic/verdicts/verdicts.db`. The shared key does not hold the
tree's location. A fresh worktree runs only what no checkout has run on
the same content and core. A test that failed in this checkout never
stands on another checkout's pass.

- `--all` (`COSMIC_TEST_ALL=1`) runs every test.
- `--no-shared` (`COSMIC_TEST_NO_SHARED=1`) stands on no shared verdict.
- `COSMIC_TEST_FOREIGN_FEATURES=1`, set only by CI's checked gathering run,
  also looks a test up under the key of another host in the shared cache
  that differs from this one in its kernel and processor features alone
  ([`declared_key.host_split`]), every other input as this host keys it.
  Unset, a run reuses only the rows of its own host's keys.
- The new checker is the tool's only one: [`build.pipeline`] reads the tree, checks it against its ceilings and writes
  the Lua. `COSMIC_GRAMMAR` takes `new` or nothing ([`build.grammar_mode`]); `teal`, the grammar of the fork that was
  deleted, is refused, pointing to the project guide, which says how to rewrite a project to the new one. A project outside cosmic's own
  has no ceilings: every error refuses, its globals are the declarations of the standard library the tool carries
  ([`build.checker_declarations`]), and a form of the old grammar is refused with the new checker's words and fix. A
  lone file run (`cosmic --standalone`, `cosmic sandbox`) and a file run (`cosmic <file>`) are built by it too. `cosmic
  build` compiles the project with it, and refuses one that has a module it refuses. The Teal a template compiles to is
  written in the new grammar ([`cosmic.template`]'s `Options`); the examples `fix --check` compiles as shown are compiled
  as files alone ([`build.example_checks`]); `cosmic sandbox --closure` takes a script's requires from its syntax tree; and
  the coverage of a project counts the lines of the text it read. `cosmic docs` and `cosmic uses` build the project before
  they answer ([`build.rebuild`]), so a symbol declared with `mut` or `name?: T` is found, and a call through a value of
  a record nested in its module, of the record a module returns, or of a class or record declared at the top of a
  module's file is a use of the method it calls, as is a class's method read through the class (`Counter.add(c, 1)`),
  under the class's own name where it defines the method (a value of no known type is a use of nothing); `cosmic db` and
  `cosmic sql` read the rows that build wrote. A module the build refuses leaves the last build as it was, and the lookup
  says why. A mistyped value is refused by `docs` and `uses` as by `test`. A module the checker refuses, or cannot
  read, does not stop a run: it runs no tests, nor does a module that requires it, and each is a failure of the run; a run
  that names tests (`cosmic test one_test.tl`) fails for the refusals of the files it names alone, and a named test
  module that requires a refused one is refused itself. A pool is refused with `--check-types`, which checks the facts
  alone (below).
- `COSMIC_VERDICT_CACHE` names another cache file. `0` means none.

`--bail` (`COSMIC_TEST_BAIL=1`) starts no test after the first failure.
The tests already running finish with their own verdicts, and the run
reports every failure it met and fails. A test never started keeps no
verdict, pass or fail, and the summary says how many did not run. The
merge queue's suites use it ([`ci/README.md`]). A run without it runs
every test.

A test must not depend on where the tree is. CI moves the checkout to
a path chosen by the commit and the leg to catch one that does.

### sandboxed and unsandboxed runs

Where the kernel can, each worker runs sandboxed. This is the default
on Linux. The worker gets what its module declares and nothing else.
A read it did not declare finds nothing, and the test fails with its
own error. That error is the signal to declare the read.

Where the kernel cannot (macOS, a host without user namespaces or
Landlock) or with `COSMIC_TEST_SANDBOX=0`, workers run unsandboxed. The
run says so and why. It trusts the declaration. An undeclared read
works, but its change moves no key, so the verdict goes stale. Declare
every read anyway. A sandboxed run on another host enforces it.

Unsandboxed verdicts are kept apart from sandboxed ones. Their key also
holds the tree's path. They are shared only through a file
`COSMIC_VERDICT_CACHE` names.

A worker sees the tree at `/tree`. Only an unsandboxed run meets a
moved path.

## declaring inputs

A module declares what its tests read with one top-level
`Test.policy { ... }` ([`Test.policy`]). Its fields are those of
[`cosmic.sandbox`]'s `Policy`: `profiles`, `grants`, `env`, `promises`,
`loopback` and `requires`. The harness takes only some of the rest (below).

```text
local Test = require("cosmic.test")
Test.policy {
  grants = { { path = "testdata/", letters = "r" } },
  env = { "PATH" },
}
```

The rules:

- The call is a statement at the top of the module, once, with a table
  literal. A computed value or a call inside a function fails the build.
- A test module never requires another test module that calls `policy`.
- A grant of `"r"` on a path of the tree is a read. On an absolute path
  it is a host file. A grant of an absolute directory is refused: list
  the files. The key holds a file by its contents.
- `env` passes variables through. A test sees only the variables it
  declares.
- The profile `"system"` gives /usr, /bin, /lib, /etc and the like. A
  test that starts a host program (a shell, `sleep`, a compiler, the
  `#!/bin/sh` launcher, [`bin/cosmic`]) needs it. A test that only reads a
  file or two of the system names them as absolute grants.
- The profile `"proc"` gives /proc, the kernel's process information, on
  Linux and nothing on macOS. A test that reads /proc declares
  `profiles = { "proc" }`, not a grant of /proc: on macOS the grant names
  a path that is not there.
- A grant of `"r"` on `/parent/<file>` reads a file beside the project
  root, for a project such as `ci/` that lives in another's tree: plain
  names, none empty, `.` or `..`, no `$` and no trailing `/`. The test
  reads it at the path `Test.parent("<file>")` returns (`/tree-up/<file>`
  sandboxed, `<root>/../<file>` not). The key holds the relative path and
  the contents, never where the tree is; a file the host lacks fails the
  module's tests.
- The harness refuses a field it has no key for, and the build fails
  naming it: a grant to write, run or connect to, `isolate`, `limits`,
  `set_env`, `set_env_digests`, `connect`, `database`, `tmp = false`,
  `user` and `group`. [`Test.policy`]'s doc lists them.
- Narrow a test before declaring a large set.

The key holds no file times, inode, device, link count or owner. They
differ in every checkout. A test that needs them makes its own files in
its temporary directory and sets them.

### the import closure

The closure is what the build finds `require`d by a literal name,
anywhere in the module and in each module it requires.

- A test requires a module of the tree it reads with a literal name,
  `require("m")` or `pcall(require, "m")`, anywhere in the module. A
  computed name is refused when the module is compiled, and a type-only
  require of another module fails and names the module.
- A `local type` require of a non-test module is not followed. Teal
  erases it. An edit to what it names runs no test again.
- Every require of a test module itself is followed, `local type`
  ones too.
- A test that type-checks a snippet brings the sources it needs in
  with `local type _ = require(...)`.

## the program and the store

A sandboxed worker has the store of its closure alone. `require`
refuses a module of the tree outside the closure.

- To start this program, declare the profile `"cosmic"` with the grant
  `{ path = "o/bin", letters = "rx" }` beside it (`tool`). That gives
  the program and nothing else.
- To run a Teal chunk in the program only (`-e`), the profile `"cosmic"`
  alone is enough (`lua`). `-e` checks its chunk as a file is checked, so
  the chunk is Teal. It requires `cosmic.*` modules and the tool's own
  modules, typed from their sources, but only those of the test module's
  closure are in the store its children run (a `require` of another is
  refused where the chunk is checked, naming it). The key holds the
  closure and the checker `-e` runs, not the whole program.
  It is refused beside the profile `"system"`, the `o/cosmic.db` store
  grant or a `/cache/` grant, since a host program or a cosmic a cache
  holds could start the program with no hold on what it loads. Declare
  the `o/bin` grant beside the profile instead, to run the program
  itself.
- A chunk is Teal and cannot reach what a test module reaches by a cast
  (the C bindings' raw tables) or by changing a library's table. Code that
  must run in a process of the program for that reason goes in the test
  module, registered with [`build.test_child`] at its top level and started
  with `test_child.words(tmp, "<the module>", "<name>", args)` as the
  words after the program, where the chunk is written for it.
- A test that starts cosmic's core past the launcher uses
  [`build.this_program`]'s `program` and needs no `"system"` profile.
  Build a child's environment from its `environment()` only where the
  test means to choose it.
- To read the tree's projection or rows of modules outside the closure,
  grant `{ path = "o/cosmic.db", letters = "r" }` (`store`). A test that
  does so runs again on every edit to the tree. Put it in a module of
  its own, with a comment above the grant saying why. Only a test of
  one module reads the store so. A check over the whole tree is no test:
  it goes in [`build.tree_checks`].
- `o/` in a grant names the build directory wherever it is. A test
  reaches what is there by the path [`build.paths`]'s `resolve(".")`
  names, never by `o/...`.
- To confine a process in a root of its own, or to start a
  `cosmic test` whose workers are sandboxed, declare
  `promises = { "nest" }` (`nests`). Without it the kernel refuses the
  mounts a root is made of, the start fails and names the promise.

A test needs no network. A sandboxed worker has none: its filter refuses
an inet socket. To reach a service, start one on `127.0.0.1` and declare
`loopback = { "127.a.b.c" }`. The worker then runs offline on a loopback
of its own. Any other host, `::1` and `localhost` are refused.

### a test that runs cosmic test

One `cosmic test` runs per checkout at a time. A `cosmic test` that a
test starts must run in a tree of its own, whose lock it takes. A run
in the same checkout waits on the run that started it until the test
times out.

Set `COSMIC_TEST_SANDBOX=0` for it, so it means the same on every host.
Nest its workers in a sandbox only where the assertion is about their
sandbox.

## host requirements

A test whose host lacks what it is about does not probe by hand and
return. Its module declares the need in its policy.

```text
Test.policy {
  profiles = { "system" },
  env = { "PATH" },
  requires = { "program:jq" },
}
```

Only what the module writes is required. Nothing is inferred from its
promises or grants.

The names come from the closed table in [`build.host_names`]. The
table says what each means. Read it before writing one. An unknown name
or a name written twice fails the build.

The runner asks the host once, before any worker starts.

- All requirements present: the module runs. Its key holds each answer.
- One absent: no test of the module starts, and no verdict is made.
  A platform requirement that the platform never has is counted
  `n/a`. Any other absence is counted skipped, naming it.
- A probe that cannot tell, or a refused name, fails the module.

Requirements are all or nothing for a module. A test that needs one
only some of the time goes in a module of its own.

What the worker sees is what its module grants, not what the runner
found. A `path:` needs a `host` grant of the same path, or of /proc
above it, or the profile `"proc"`. A `program:`
needs the profile `"system"` and `env = { "PATH" }`.

A test that writes a portable program (`cosmic build` without `--host`)
declares `requires = { "all_cores" }`. A bare `bin/zig build boot` writes a
tool that carries the host's core alone, which refuses to make one, so the
module is skipped there, naming the requirement; every CI leg promises it,
since CI boots `-Dboot-cores=all`. Run `bin/zig build boot -Dboot-cores=all`
to run them.

A test of what only the checked (sanitized) core reaches, such as a
refused allocation or a fault point, declares `requires = { "checked" }`.
Every other core finds it not applicable. The checked leg promises it.

### CI legs

Each CI leg promises a list of requirements in
[`ci/cosmic_ci/capabilities.json`]. Add a name to a leg's list in the same
change where a module first requires it. `bin/cosmic fix --check .`
fails a requirement no leg promises, because a module that is n/a or
skipped on every leg runs nowhere.

A run that is not held ignores the promises. A held run (below) fails a
module for an n/a or a skip of a requirement its leg promises.

## skipping

Call `Test.skip(reason)` ([`Test.skip`]) when the test learns, as it
runs, that this host cannot give it what it is about: a spawn the
kernel refused with EPERM, say. Do not `return` early. A silent return
passes having checked nothing.

- It ends the test where it is called. Nothing after it runs.
- A `pcall` or a coroutine around it must raise what it caught again.
- A test with more to check first defers the call to its end.
- It is called from a test, not as the module loads.
- A skip is counted apart (`N skipped`) and listed with its reason.
  No verdict is kept, so the test runs again every run.
- A skip waiting on what the policy path cannot give yet (a Unix
  socket by path, a mode with a setuid bit) carries a `TODO:` beside
  it naming what it waits on.

Where a fact of the host alone decides, use `requires`, not a skip.
Where no name stands for it (a native start with nothing to relaunch,
a test of what only another platform does), skip.

## assertions

A test that passes without calling `assert` shows only that it did not
raise. The worker counts calls to `assert`, through any helper or
fixture. `cosmic test` lists each such pass as `test: NO ASSERT <id>`
and keeps no verdict of it. A held run fails it.

- A test that checks through `error` or `pcall` still calls `assert`
  for what it checks.
- A test that shows something does not raise asserts on a result.
- A test that cannot check on this host declares `requires` or calls
  [`Test.skip`].
- A doc test's output is compared with `assert`.

[`Test.passed_unchecked`] is for the fuzz runner alone. `bin/cosmic fix
--check .` fails any other use.

## run-time type checks

`cosmic test --check-types` (`COSMIC_TEST_CHECK_TYPES=1`) shows where the checker's conclusion from a test is false at
run time. It compiles the tree with a check at each read of a place a test narrowed (below) and runs every test,
whatever verdict stands, since only a worker reports. The new checker keeps nil out of every declared type itself. It
writes a check at the entry of a function for each typed parameter ([`lang.boundary_checks`]): a statement on the line of
the `)` that ends the parameters, so no line moves and a tail call stays one, which hands the hook the values and the
kinds the declared types admit. A value of another kind is a row of kind `parameter` at the line of the caller. A
parameter declared under `cosmic/` raises there, "parameter violated at <caller>: ...", so the first violation fails the
test that met it: the caller or the declaration is wrong, and the fix is the declaration (`T?` where nil really flows)
or the caller, so a test cannot pass a wrong kind to a typed `cosmic/` parameter on purpose. The run fails too, in its
summary, for a violation a `pcall` swallowed, naming the first. A parameter declared elsewhere is reported, and the
function runs on. A variadic parameter, `self` and a parameter typed `any` are not checked. It writes no check of a
returned value or a field write yet, so the run reports rows of kind `fact` and `parameter`. The compile is keyed apart
from an unchecked one ([`importer.checked_tool`]).
The tests of declared boundaries (`*_declared_types_test.tl`, through [`build/type_watch.tl`]) skip in every run until a
compile writes the checks of returns and fields as well: a pass would check only the parameters.

Three tests compare the bytecode of a module with the binary's
([`build/harness_epoch_test.tl`], [`cosmic/store_seal_test.tl`],
[`build/rebuild_lock_tool_test.tl`]) and skip in a checked run, whose
modules carry checks.

The run ends with the count, the distinct violations and the commonest
ten, each with the line that sent the value: the caller for a parameter,
the `return` or the write for the others. `cosmic sql --build 'SELECT *
FROM type_violations'` lists all of them, from the latest checked run.

A module compiled with checks is another compile of the same source: it
has its own keys, and the tool and the executables `cosmic build` writes
carry none.

### checked narrowing

A checked run also tests what the checker concluded from a test. A read of
a local whose type a test narrowed (`if x then`, `x ~= nil`, `is`,
`type(x) ==`, `assert(x)`) is written as a check of what the test took out: the kinds of the type before
the test that the type after lacks (`x is string` on `string | R` takes out
`string` in the else branch and `R` in the then branch), and nil where the
place was declared to admit it and the test left it none. A value of a kind
taken out raises `fact violated at <file>:<y>:<x>: <place> is <kind>, the
checker proved not <kinds>` at the read, which fails the test. Where the type
before was `any`, the test took the value to the kinds of the type after, and
the check is that. Such a failure is the checker's: it accepted a program in
which a place it narrowed is not what it narrowed it to (a write it did not
see), so a test that meets one found a
hole in the narrowing, not a fault of the test. Report it with the smallest
program that shows it.

- An element that a length test proved (`xs[1]` after `#xs >= 1`) is checked the same way, as a read of the place `xs[1]`:
  a nil there raises `fact violated`. The flow's array property ([`lang/check_flow_fuzz_test.tl`]) draws programs that
  shorten an array behind a length test, and fails where the checker keeps the fact.
- It checks what the test took out, not what the declared type leaves: a
  nil that a map read or an optional gives a `T | R`, or a float given an
  `integer | string`, passes both branches of an `is`, and is the type
  checks' to report.
- It checks nothing of a place narrowed by the type of a value assigned or
  declared with (`x = f() or g()`), which holds nil where the checker's type
  does not say so (the TODO of [`lang.fact_wraps`] names it).
- A place that is not a local (a field, a global, `a.b.c`, `t[k]`) is not
  checked, as the narrowing does not hold one.
- The check is a call of the hook per narrowed read, which costs. A fuzz
  property's instruction budget allows a checked run four times as many
  instructions ([`build.fuzz`]).
- The tests that compare a module's bytecode with the binary's skip in a
  checked run (a TODO beside each).

The new checker records the same reads in [`Check.Checked.narrowed`] (the offset of the read and the kinds of Lua value
the checker took out). [`lang.check_programs`]'s `execute` wraps each in a check that raises `fact violated`, runs the
Lua [`lang.codegen`] writes, and the flow's fuzz properties ([`lang/check_flow_fuzz_test.tl`]) hold every program the
checker takes to run without one. Those properties run it with the hook the tool's worker defines
([`build.test_worker`]'s `install_checks`), the `__fact` that [`lang.fact_wraps`] gives each read the place, the kinds, the
enum strings, the classes and the tag of: a false conclusion raises as above and is also kept as a row of
`type_violations` of kind `fact` (the read as `<file>:<line>:<column>`, the place as written, what the checker proved,
what the value was), which survives a test that catches the error. A chunk with wraps begins by defining a `__fact` that
answers its value where there is none ([`lang.codegen`]), so a wrapped read in a `cosmic` that such a test starts, in a relay
or in a library the worker loads before it installs its hook answers its value. [`build.compile_grammar`]'s `compile`
writes the wraps given `facts` (no flag of `cosmic compile` asks for them), and `cosmic test
--check-types` has the build write them for the tree ([`build.pipeline`]'s `generate`), so a read the checker narrowed
wrongly is a failing test and a row of `type_violations` of a real run ([`build/fact_hook_tool_test.tl`] plants one).

CI runs the whole suite so in the `checked-narrowing` job of a full run
(`cosmic-driver cosmic_ci/driver.tl platform checked-narrowing`), and
`bin/cosmic test --check-types` runs it anywhere.

## fuzz tests

A parser that reads untrusted bytes gets a `*_fuzz_test.tl` beside it,
driving [`build.fuzz`]'s `run`. A generator draws each input from a
seeded source. A check must hold for all of them. The module doc of
[`build.fuzz`] has the full contract.

- `FUZZ_SEED` and `FUZZ_ITERS` (64 by default) choose the inputs.
- A failure is shrunk and kept in the test's directory.
- `FUZZ_CASE=<property>:<case>` checks the one input a report names.
  `FUZZ_SEED=<seed> FUZZ_ITERS=<iteration>` reruns the way to it.
- Draw a collection's elements with [`Fuzz.more`], not a count drawn
  first. Shrinking can then cut any one element.
- A check calls [`Fuzz.label`] for what an input reached. A property
  `requires` the labels it exists to exercise, so a generator whose
  inputs all stop at the first refusal fails. It `shares` the least
  share of drawn inputs that must reach a label, set well under what a
  run reaches. Neither is held when `FUZZ_ITERS` is below 64.
- CI runs that gate a merge set `FUZZ_ITERS=0` and draw nothing. The
  nightly `fuzz.yml` fuzzes every property on the checked core with a
  seed of its own. A failure is a red run whose summary lists it.
- Once a failure is fixed, keep its input in
  `testdata/fuzz/<property>/` as the report says. `run` checks that
  corpus before it draws.

## a change to the checker's verdicts

A change to the type checker that must not move a verdict, or must move
only the ones it says, is held by the tests of each rule
(`lang/check_*_test.tl`, which name a program and the code it gets) and
by the checker's fuzz properties ([`lang/check_flow_fuzz_test.tl`],
[`lang/check_total_fuzz_test.tl`], [`lang/check_assigned_fuzz_test.tl`]),
which run the checker on drawn programs and on the corpora in
`testdata/fuzz/checker-*`.

The tree alone is weak evidence for a change to narrowing: the tree's own
code is written to pass, and a checker that narrowed less or more leaves
most of its lines as they are. The fuzz properties carry that sensitivity,
so a narrowing change runs them with a larger `FUZZ_ITERS` as well as
reading the tree's ceilings.

## other hazards

- Every test's directory is at a path padded to macOS's length
  (`scratch_length` in [`build.test_sandbox`]). A bound on a path's
  length is met on every leg.
- The directory's name holds a `-`. Escape a path before putting it in
  a Lua pattern: `(path:gsub("%p", "%%%0"))`.
- A worker that writes to `/tmp` itself, past its `TMPDIR`, writes to a
  `/tmp` of the sandbox's own. It is gone with the worker.
- A timeout is a failure to investigate. Report it apart from an
  assertion failure. Inspect the elapsed time and the slow work first.
  Do not raise the limit silently.

## benchmarking a full run

To time full test execution, delete only the rows of the `verdicts`
table in the build directory's `build.db`, and run with
`COSMIC_VERDICT_CACHE=0`. Keep the staged database. Report the `ran`
and `stood` counts with the elapsed time. [`doc/performance.md`] covers
the repository's own timing fixtures, not this recipe.

`bin/cosmic db` names the databases by their paths.

## changing the harness

Most authors skip this section. It is for a change to the code that
runs, sandboxes or keys tests.

No key holds the harness's code. It holds `epoch` in
[`build.harness_epoch`]. An edit to the harness therefore runs no test
again by itself. [`build.harness_epoch_test`] fails until
`acknowledged` holds every harness module's digest. It prints the line
to set or add, and each stale entry to delete.

The code that makes a key, looks a verdict up or keeps one, and gives a
worker what it runs on is [`build/test_key.tl`], which the harness holds
alone. The runner around it, [`build/test.tl`], and the types they
share, [`build/test_state.tl`], are not held: an edit to either (a
progress line, the coverage, the summary) moves no digest, and needs
nothing here. Where a part of the runner could be either, it is in
[`build/test_key.tl`].

Bump `epoch` in the same edit where the change can alter a pass or a
fail:

- what a worker is given,
- how it is judged,
- how a key is computed,
- a sandbox hold or bind tightened. A pass earned through the hole
  must not stand.

A comment-only edit sets the `acknowledged` lines and does not bump.
A bump appends the old token to `retired` and draws a new one. The
guard prints both lines. On a merge conflict in `epoch`, keep neither
side. Set the bare count, and the guard prints a fresh value.

A merge-queue run whose change moves that file runs every test.

Other rules:

- A held run fails instead of falling back. Hold a run with
  `COSMIC_TEST_SANDBOX=1`, `COSMIC_SANDBOX=must` or
  `COSMIC_CI_REQUIRE_SANDBOX=1`. CI's Linux legs hold theirs.
- Never set `COSMIC_TEST_HARNESS_EPOCH` or `COSMIC_TEST_PLATFORM=other`
  to run a suite. They are for the runner's own tests
  ([`build.sandboxed_verdicts_test`]).
- Harness modules reach the host through raw bindings and the
  standard-library modules `library` in [`build.harness_epoch`] names,
  each with its reason. [`build.harness_epoch_test`] holds them to it.
- What else of the tree the runner calls, such as the sandbox probe
  ([`build.test_sandbox_probe`]), must fail loudly and never pass.
- Only the sandbox's own tests nest one sandbox in another with
  [`build.confine`]'s `confine`. Where the kernel cannot confine, it
  starts the process unconfined. `must_confine` fails the spawn
  instead.
- [`build.confine`]'s `sandbox_platform` is for the probe of the host
  alone. `bin/cosmic fix --check .` fails a use elsewhere.
- A root confines only two deep, so a root runner runs each sandboxed
  worker as a user of its own. Where the kernel refuses a sandbox that
  deep, those tests call [`Test.skip`].

[`bin/cosmic`]: ../bin/cosmic
[`build.checker_declarations`]: ../build/checker_declarations.tl
[`build.compile_grammar`]: ../build/compile_grammar.tl
[`build.confine`]: ../build/confine.tl
[`build.example_checks`]: ../build/example_checks.tl
[`build.fuzz`]: ../build/fuzz/init.tl
[`build.grammar_mode`]: ../build/grammar_mode.tl
[`build.harness_epoch_test`]: ../build/harness_epoch_test.tl
[`build.harness_epoch`]: ../build/harness_epoch.tl
[`build.host_names`]: ../build/host_names.tl
[`build.paths`]: ../build/paths.tl
[`build.pipeline`]: ../build/pipeline.tl
[`build.rebuild`]: ../build/rebuild.tl
[`build.sandboxed_verdicts_test`]: ../build/sandboxed_verdicts_test.tl
[`build.test_child`]: ../build/test_child.tl
[`build.test_sandbox_probe`]: ../build/test_sandbox_probe.tl
[`build.test_sandbox`]: ../build/test_sandbox.tl
[`build.test_worker`]: ../build/test_worker.tl
[`build.this_program`]: ../build/this_program.tl
[`build.tree_checks`]: ../build/tree_checks.tl
[`build/fact_hook_tool_test.tl`]: ../build/fact_hook_tool_test.tl
[`build/harness_epoch_test.tl`]: ../build/harness_epoch_test.tl
[`build/rebuild_lock_tool_test.tl`]: ../build/rebuild_lock_tool_test.tl
[`build/test.tl`]: ../build/test.tl
[`build/test_key.tl`]: ../build/test_key.tl
[`build/test_state.tl`]: ../build/test_state.tl
[`build/type_watch.tl`]: ../build/type_watch.tl
[`Check.Checked.narrowed`]: ../lang/check.tl
[`ci/cosmic_ci/capabilities.json`]: ../ci/cosmic_ci/capabilities.json
[`ci/README.md`]: ../ci/README.md
[`cosmic.layout`]: ../cosmic/layout.tl
[`cosmic.sandbox`]: ../cosmic/sandbox/init.tl
[`cosmic.template`]: ../cosmic/template/init.tl
[`cosmic/store_seal_test.tl`]: ../cosmic/store_seal_test.tl
[`declared_key.host_split`]: ../build/declared_key.tl
[`doc/performance.md`]: performance.md
[`Fuzz.label`]: ../build/fuzz/init.tl
[`Fuzz.more`]: ../build/fuzz/init.tl
[`importer.checked_tool`]: ../build/importer.tl
[`lang.boundary_checks`]: ../lang/boundary_checks.tl
[`lang.check_programs`]: ../lang/check_programs.tl
[`lang.codegen`]: ../lang/codegen.tl
[`lang.fact_wraps`]: ../lang/fact_wraps.tl
[`lang/check_assigned_fuzz_test.tl`]: ../lang/check_assigned_fuzz_test.tl
[`lang/check_flow_fuzz_test.tl`]: ../lang/check_flow_fuzz_test.tl
[`lang/check_total_fuzz_test.tl`]: ../lang/check_total_fuzz_test.tl
[`Test.passed_unchecked`]: ../cosmic/test.tl
[`Test.policy`]: ../cosmic/test.tl
[`Test.skip`]: ../cosmic/test.tl
