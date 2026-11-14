# testing

How to write a test for cosmic and how `cosmic test` decides to run it.
The authoritative detail lives in the modules this doc links. This doc
gives the rules an author acts on.

## exit status

`cosmic test` exits 0 when every test passed and 1 when a test failed. It
exits 4 when the tree, or a module a named run needs, did not compile: the
checker refused a module, a file does not parse, or the modules require each other in a cycle. That holds when tests
failed too, so a script that tries a changed tree (a mutation run) tells a
change the checker refused from one a test caught. A refusal in a module a
named run does not need leaves the run at 0 or 1, as does a failure to read, stage or write. `cosmic build`, a file run, `-e` and
`--standalone` exit 4 for the same reason; a program that returns 4 itself looks the same. `cosmic help exit` lists
every status.

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

To check one file in a project, run `cosmic fix <file>`: it builds the tree and reports that file's errors, with every
project `require` known. `cosmic --standalone --check <file>` checks a file alone, outside the project, so its project
requires are unknown by design and a file that needs them is refused there.

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

- `--all` (`COSMIC_TEST_ALL=1`) runs every test, whatever verdict stands for
  it, in this checkout or another. It is the way to run a test again that
  passed.
- `--no-shared` (`COSMIC_TEST_NO_SHARED=1`) stands on no shared verdict.
- `COSMIC_TEST_FOREIGN_KERNEL=1`, set only by CI's checked gathering run,
  also looks a test up under the key of another host in the shared cache
  that differs from this one in its kernel alone
  ([`declared_key.host_split`]), every other input as this host keys it:
  a share that ran on an image with another kernel. It never reaches a
  row of another processor's features (below). Unset, a run reuses only
  the rows of its own host's keys.
- The new checker is the tool's only one: [`build.pipeline`] reads the tree, checks it against its markers and writes
  the Lua. `COSMIC_GRAMMAR` takes `new` or nothing ([`build.grammar_mode`]); `teal`, the grammar of the fork that was
  deleted, is refused, pointing to the project guide, which says how to rewrite a project to the new one. A project outside cosmic's own
  holds no marker: every error refuses, its globals are the declarations of the standard library the tool carries
  ([`build.checker_declarations`]), and a form of the old grammar is refused with the new checker's words and fix. A
  lone file run (`cosmic --standalone`, `cosmic sandbox`) and a file run (`cosmic <file>`) are built by it too. `cosmic
  build` compiles the project with it. A module it refuses, a test file included, or one that breaks a position rule (a
  private module imported from outside its directory), does not stop the programs (`cmd/<name>/`) whose own requires
  compile: they are written, the refused files and the programs held out are named, and the exit status is 4. A module
  that requires a refused one is refused too, so a program resting on it is held out. A `global` in a module is refused
  as that module's own; one in a declaration file, an import cycle and a source that cannot be read stop the whole tree:
  no program is written, the executable of every program is removed, and the status is 4. The executable an earlier
  build left for a program that is not written (refused, or its own build failed) is removed from the build directory
  and, with `--out`, from that directory, and the output says so. `--out` removes only a copy a build of this tree wrote
  (a manifest beside `cosmic.db` names them) and that is unchanged since, never a file of the user's, and a build
  without `--out` leaves an earlier `dist/<name>` alone. A failure of the environment (no portable core, a build
  directory that cannot be made) removes no executable of its own, though a program refused in the same run has had its
  executable removed before the failure is found. A failure to read, stage or write is 1 and outranks the refusal, which
  is named all the same. The Teal a template compiles to is
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
  module that requires a refused one is refused itself. One run tells every finding it soundly can. A module that
  requires a refused one is checked all the same, and its own findings told, where the refused module parsed and its errors
  are in its bodies and in no `return`: its declarations are what the other reads. Such a finding holds of those declarations
  as they are written, and its refusal says so, since a fix of the refused module that changes one may settle it. A module the checker refuses is told its
  breaches of the error-slot rules too, those in the top-level statements the checker typed whole. A file refused only for a
  `global` is told what the checker says of it with `local` in its place. A pool is refused with `--check-types`, which checks the facts
  alone (below).
- `COSMIC_VERDICT_CACHE` names another cache file. `0` means none. It turns
  off the cache that checkouts share and nothing more: a verdict this
  checkout reached, kept in `build.db`, still stands, so the variable does
  not run a test again. `--all` does.

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

A sandboxed worker is not told where or how its run was started. It has
no PATH unless its module declares `env = { "PATH" }`, and then
/usr/local/sbin, /usr/local/bin, /usr/sbin, /usr/bin, /sbin and /bin,
which the profile `"system"` gives. COSMIC_AUTO_BOOT is `0` and
COSMIC_TEST_SANDBOX is unset. HOME is a directory in its scratch
directory and XDG_CACHE_HOME is unset, unless the module grants a host
cache (`/cache/...`), which it finds by the host's. So a verdict stands
for a run started from another home, with another PATH. A test that
needs another value of one sets it for the process it starts.

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
`loopback` and `requires`, and `cpu_features` and `store_text`, which only a
test declares (below, and "the pure store"). The harness takes only some of the rest.

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
  declares. A sandboxed worker has a PATH only where its module declares
  it, and then the system's directories on every host, whatever the
  runner's ("sandboxed and unsandboxed runs").
- A test that starts a host program grants it by its absolute path
  (`{ path = "/bin/sh", letters = "r" }`). The program comes with what it
  needs to start: its loader and shared libraries, and a script's
  interpreter. The key holds each of those files by its contents and
  nothing else of the host's. A program it starts in turn, or a file it
  opens by name, is granted the same way. A grant of a path a host lacks
  gives nothing there, so a program hosts keep in different places is
  granted at each (`/bin/sed` and `/usr/bin/sed`).
- The profile `"system"` gives /usr, /bin, /lib, /etc and the like, and
  its key holds every package the host has installed, so its verdict
  stands only on a host with the same packages. A test needs it only
  where it cannot say which programs it starts, as one that runs
  `cosmic sandbox --system` cannot; one that runs the `#!/bin/sh`
  launcher or [`bin/cosmic`] grants the programs those call. A test that
  only reads a file or two of the system names them as absolute grants.
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

### processor features

A verdict stands across hosts of other processors. A key holds the
host's kernel (its release and version) and not the processor's
features, so CI's runners of one image, which land on processors that
differ, share their verdicts and their cache. (Measured on them: the
kernel is the same, and only the VNNI features differ, which only
[`cosmic.vector`]'s kernel reads.)

A module whose tests can turn on the processor says so with
`cpu_features = true` in its [`Test.policy`]
(`Test.policy { cpu_features = true }`, [`Test.policy`]). Its tests' keys
then hold the features a core chooses code by
([`declared_key.host_cpu`], listed in [`declared_key.dispatched`]), and a
verdict of a host that lacks one does not stand for a host that has it,
nor the other way. Policy is static, so the key is worked out before the
test runs.

The harness holds a module to declaring it where the core itself selects
the code by a feature. A run of cosmic's own tree reads which lines of the
core's C each test ran (its worker, from the module's load through the
test, and the processes it started, [`Coverage.native_functions`]), and a
test that passes having run a line of code that core/vector.c selects by a
feature (the kernel compiled for VNNI, the lines that call the one chosen,
and `vector_kernel`, which names it), in a module that does not
declare `cpu_features`, fails, naming the function and the fix
([`build/dispatch_sites.tl`], derived from the audit of
[`build/dispatched_features_test.tl`]). A pass that stands without
running is not checked again, since its key held the module's declaration
when it was earned. A core that observes no C of its own, a core that
compiles no such code (aarch64), and a project outside cosmic's tree,
whose C is not there to read, are not checked.

Entering a vendored library's dispatched code (mbedtls's AES-NI, SHA-NI
and Arm instructions, xz's carry-less CRCs) is not checked: those paths
compute the same output as the portable ones, so a test that hashes or
compresses incidentally does not depend on the processor, and holding
them to it put half the suite under a processor key. A module whose
subject is such a routine (the hash, compress and zip tests) declares the
field anyway, so that a bug in one processor's path is caught on that
processor.

A test that asserts on what [`sys.cpu_features`] answers has an outcome that
depends on the processor, and the harness does not catch it: every
`cosmic test` a test starts asks for the features to make its key, so the
function's lines are hit by modules that do not depend on the answer. Such a
test goes in a module of its own that declares `cpu_features`
(core/cpu_features_test.tl), not in a module that happens to call it.

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
- `Store.source(name)` ([`cosmic.store`]) serves only the running binary's own database. Under `cosmic test` that is the
  test's sealed database: the source of a module the test requires is there, and a module it does not require answers
  `nil` and `no module '<name>' in the binary`.
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

### the pure store

A test's key holds the store of its closure, and a comment, a blank line or
a moved line of an imported module changes that store's rows (the source,
the docs, the uses with their lines, the debug information of the bytecode)
without changing what the module does. So a sandboxed test is given a pure
store by default ([`build.closure_store`]'s `write` with `own`), unless it
declares `store`, `store_text`, `lua` or `tool`, or a module of its closure
declares that it reads text (below):

- no module's source or source hash, and no row of `docs`, `uses`, `links`,
  `examples`, `catalog`, `stubs` or `places`, but for the exception below: a test that reads one finds none
  and fails, rather than standing on text that changed;
- the exception to the first item, the stubs of the standard-library modules
  (`cosmic.*`) the test module names with a top-level `local type _ =
  require("cosmic.x")` (a `<const>` after the name is allowed), and of those
  the stubs require, among the modules of its closure. The checker types a
  snippet from a module's stub and follows only the stub's requires
  ([`build.standard_text`]), so these are all it reads, and the source of no
  module is kept. A stub is the module's declared types, with no comment or body, each token at its source line and column;
- the exception to the first item, the sources of what a module in the closure
  declares it reads: a module that hashes other modules' sources into an
  identity (the checker's readers, the analyzer, the readers of the record-field
  uses, the links finder) requires one of [`build.reads.pipeline`],
  [`build.reads.analyzer`], [`build.reads.receivers`] or [`build.reads.links`]
  ([`build.code_walk`] holds the walks), and a test importing it is given the
  source of the modules that walk reaches, which its key holds. A module that
  reads any other text ([`build.reads.all`]: docs, uses, places, the language
  server) demotes every test importing it: the test is given the store of its
  closure with its text, keyed by its bytes, as `store_text` does for a test
  that declares it;
- the tables of text-derived rows (`docs`, `uses`, `links`, `examples`,
  `places`, `catalog` and their full-text tables) are left out, not left empty:
  a query of one fails with "no such table", and so does a hint
  ([`build.symbols`]) asked of a store that has none. The catalog is withheld
  because most of it, the rows of the error sites each module documents, moves
  with the lines of the module; the checker's own codes (`kind = 'code'`) do not,
  but no test that reads module text wants them alone;
- the bytecode of each module it imports stripped of its debug
  information and numbered by instruction ([`build.lua_tail`]'s
  `numbered`): each function names its module as its source, and each but
  the chunk's own is defined on line 16777216 + `k`, `k` the number of the
  chunk's instructions before its first, whatever line of the text it came
  from. Its own module's bytecode is as the build made it;
- the source file of its own module and of the declarations it requires, and
  not of the modules it imports.

Its key holds the digest of exactly that, the stubs kept included, so an edit to an imported module
that changes no bytecode (a comment, a blank line, a renamed local, a function
that moved down the file) runs no test of its importers again, and one that
changes what the module does runs them. In a module the test names, a comment
at the end of a line it already has runs nothing, but one on a line of its own, a
blank line, or a body that gains or loses lines moves every token below it, and with it the stub and the key;
so does a change to its declared types, or to those of a module its stub requires. Name only
the modules a snippet needs. A `require` by value names none, so [`cosmic.test`] and the modules a test
runs keep stable keys.

A snippet that requires a standard-library module the test does not name finds
its stub withheld (the message says so, and says to name the module), and the test fails: name the module in the test, as
`local type _ = require("cosmic.x")` beside any `require` by value. A statement in a comment
or a long string (a snippet the test checks) names nothing. The docs, places and uses of a module are
never kept: a test whose subject is the language server, `cosmic docs` or a
module's declared places declares `store_text`. A test that starts the program (`lua`,
`tool`) is given the store of its closure, text included, as a `store_text` test is; only
`store` is given the whole projection.

What makes the store sound is that a read of text it withholds fails: a source
is withheld ([`Store.withheld`]) and a table is absent. `cosmic fix --check .`
also runs a lint, `text_readers` ([`build.tree_checks`]), that finds most
modules that read text and asks them to declare it, so the failure is met
early; a reader it misses (a table named at run time) is met by the first test
that reaches it, which declares `store_text` or whose module declares the
read. The lint is a heuristic and no part of the guarantee.

The pure store is held for a sandboxed worker alone: unsandboxed, a worker
reads the real tree, which a key without the imports' sources would not follow.

What a test declares to be given more than the pure store:

- `Test.policy { store_text = true }`: the store of its closure with its text
  (docs, uses, places, catalog, sources), keyed by its bytes. For a test whose
  subject is the text of the store: the checker typing a snippet of the tree's
  sources, `cosmic docs`, the language server, the uses and catalog. A comment
  in any module of its closure runs it again.
- a top-level `local type _ = require("cosmic.x")`: the stub of that
  standard-library module, for a test that type-checks a snippet requiring it.
- `lua` or `tool`: the program starts, and its checker types against the
  closure's text, so the test is given the store of its closure with its text.
- `store`: the whole projection, for a test of one module that reads the rest
  of the tree.
- a read grant (`grants = { { path = "build/zig.tl", letters = "r" } }`) for a
  file of the tree that a process it starts reads, such as [`build/zig.tl`],
  which [`bin/zig`] hands to `cosmic-bootstrap --standalone`. A sandboxed
  worker is given the files of the tree its test declares and its closure
  supplies, and a pure store's rows supply no module's source file, so an
  undeclared read of one fails ("No such file").

What a module that reads other modules' text declares: it requires the marker
of what it reads, and every test importing it is given that, keyed by it.
[`build.reads.pipeline`], [`build.reads.analyzer`], [`build.reads.receivers`] and
[`build.reads.links`] ([`build.code_walk`]) name a walk of sources, and a test
importing the module is given the sources that walk reaches. [`build.reads.all`]
(docs, uses, places, the language server) gives every test importing it the
store of its closure with its text, as `store_text` does.

A test does not assert a position inside code it imports: a line number of
the module's own code in a message or a traceback, `debug.getinfo`'s
`currentline` or `linedefined`. In a pure store an imported module's code
has no line: an error it raises reads `module:-1: ...` (`error` with a
level adds no position), a traceback's frame in it names no line, and a
function's `linedefined` is the number of an instruction, not a line of
the text, which moves with each instruction added above it. The runner shows a traceback's
`function <module:line>` at the module's file and the line that function
is defined on in this run's text, in the message of a test it shows and
records in `runs` and in the output it shows (`--show-output`, a
failure's). Match the message without its position,
or write the source the test asserts about in the test itself (a fixture
string compiled by the test), whose lines it chooses.

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

Only what the module writes is required, with one exception. A module
that declares `loopback` addresses also requires `loopback` (this host
permits a TCP listener and a UDP socket bound to 127.0.0.1), which the
runner derives from the declared addresses; it need not be written.
Nothing else is inferred from its promises or grants.

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
tool that carries the host's core alone, which makes none without booting every
core first, and a test boots nothing, so the
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

`bin/cosmic fix --check .` fails a test that returns early from its own
body: an `if <condition> then return end` or a bare `return` standing
directly in a top-level `local function test_*`, unless the `return`
follows a `Test.skip(...)` call ([`build.test_returns`]). A `return` in
a branch of its own, a loop, a callback or a helper is not read, so it is
no licence: a branch that returns having checked nothing is a skip too.
A helper that skips for several tests ends the test itself and returns
nothing for the test to guard (`unix_socket.skip_if_refused(dir)`, a
local `<thing>_or_skip()`), because after [`Test.skip`] nothing runs.

## assertions

A test that passes without calling `assert` shows only that it did not
raise. The worker counts calls to `assert`, through any helper or
fixture. `cosmic test` lists each such pass as `test: NO ASSERT <id>`
and keeps no verdict of it. A held run fails it. A test that returns
early where it cannot check is such a pass: it calls [`Test.skip`]
with the reason instead, and is listed as skipped.

To compare JSON-shaped values, use [`Json.diff`]`(want, got)` and assert that the list it answers is empty, or put the paths
it names in the message. Compare a typed record field by field.

    local Json = require("cosmic.json")
    local want: Json.Value = { name = "cosmic", tags = Json.array({ "lua" }) }
    local got: Json.Value = { name = "cosmic", tags = Json.array({ "lua", "teal" }) }
    local differences = Json.diff(want, got)
    assert(#differences == 1 and differences[1].path == "/tags/1")

- A test that checks through `error` or `pcall` still calls `assert`
  for what it checks.
- A test that shows something does not raise asserts on a result.
- A test that cannot check on this host declares `requires` or calls
  [`Test.skip`].
- A doc test's output is compared with `assert`.
- `assert` of an optional that may hold a boolean is refused (`condition_type`): `assert(seen[key] == true)` says a
  flag is set, and `assert(decoded ~= nil)` that a value which may be false is there.

[`Test.passed_unchecked`] is for the fuzz runner alone. `bin/cosmic fix
--check .` fails any other use.

## coverage floor

Every run reports the share of executable lines the tests reached,
`test: coverage 90.8% (184277/202824 lines; informational, never a failure)`:
the Teal of the tree and, in cosmic's own tree, the core's C. By itself it
never fails a run. Two flags make it a gate:

- `--min PCT` fails the run when the whole tree's coverage is under `PCT`.
- `--min-file PCT` fails it when any one file's coverage is under `PCT`.
  Each file under it is named with its percentage.

`PCT` is a number from 0 to 100, with an optional decimal part of at most
four digits (`76`, `76.5`), given as `--min 76` or `--min=76`. A coverage at
the floor is not under it. A figure prints rounded down, so 1599 of 2000
lines is 79.9%, never 80.0%, to as many decimals as its floor has and one at
least: the coverage line and the failure under `--min` to `--min`'s, each
file's failure to `--min-file`'s, so under `--min 97.35` a coverage of
97.349% prints as 97.34% on both. A tree or file with no line to cover is
under no floor. A floor not met fails the run as a failing test does, with
status 1 (not the 4 of a tree that does not compile). It lists each shortfall as a `test: FAIL  coverage: ...` line
and names them in the summary line:

```text
test: coverage 77.7% (7/9 lines)
test: FAIL  coverage: 77.7% (7/9 lines) is under --min 100%
test: FAIL  coverage: lib 66.6% (4/6 lines) is under --min-file 80%
test: 1 test passed in 1 module; ...; coverage floor not met: 77.7% under --min 100%, 1 file under --min-file 80%
```

A floor is over every line of the tree, so a run that names tests or a
`--shard` is refused with status 2: it reaches only some of the lines. A run that stops early (`--bail`) judges no floor and says so: it reached only
part of the lines. A floor on a failing run is judged and named beside the failures.

A test whose verdict stands brings the lines it hit when it ran (the
`coverage_by_test` rows of that run, or the ones another checkout shared,
which are kept as the shared verdicts hold them: under a first line
`lines as distances`, each module's lines after its first as the distance
from the one before).
A row names, beside each module's lines, the text they are numbered in (a
prefix of the module's source hash). A comment, a blank line or a moved
line of a harness module moves no key ([changing the
harness](#changing-the-harness)), so the text a standing row's lines were
numbered in can be gone: a row's lines of a module are credited only while
its text is the one the row names, and a row that names none, written by an
older tool, credits no module. The lines of a module a pure store numbered
by instruction are kept as those numbers, which no comment moves, beside the
bytecode they number, and placed at the lines of the text of the run that
stands on them ([coverage](#coverage)). A run that dropped some says so:

```text
test: coverage 61.2% (127363/208103 lines; partial: hits of 3 modules came from runs on other text; `--all` reruns them)
```

Without them the figure is at most what the tests reach, so a floor it
meets is met, and one it is under fails as any floor does, its lines and
the summary saying the figure is partial: `--all` has the figure to judge
it on. A run that stands on verdicts earned on the text it runs has the
coverage of the runs that earned them, and a floor holds for it as for a
run that ran every test. A test that is skipped or not applicable on the
host reaches nothing of the lines it covers elsewhere, so the same floor
can differ between hosts: state a floor from the measurements of the host
that gates the merge.

## run-time type checks

`cosmic test --check-types` (`COSMIC_TEST_CHECK_TYPES=1`) shows where the checker's conclusion from a test is false at
run time. It compiles the tree with a check at each read of a place a test narrowed (below). Its verdicts are its
own: a checked run stands on the pass an earlier checked run earned under the same key, which holds the mode by name
(a `checks` part, with the harness digest of [`build.test_worker`], where the hooks live), and never on an unchecked
run's. The key holds the checked bytecode of the closure, so an edit that changes what the checks do moves the keys of
the tests that load it and no others. A checked run keeps its verdicts in `verdicts/verdicts-checked.db` beside
`verdicts.db` (or the file `COSMIC_VERDICT_CACHE` names), which keeps twice as many rows.
A test keeps no verdict in a checked run unless its worker reported the harness's own hooks and it met no violation
of any kind, so a test that meets one runs in every checked run and reports it again. `--all` runs every test. The
new checker keeps nil out of every declared type itself. It
writes a check at the entry of a function for each typed parameter ([`lang.boundary_checks`]): a statement on the line of
the `)` that ends the parameters, so no line moves and a tail call stays one, which hands the hook the values and the
kinds the declared types admit. A value of another kind is a row of kind `parameter` at the line of the caller. A
parameter declared under `cosmic/` raises there, "parameter violated at <caller>: ...", so the first violation fails the
test that met it: the caller or the declaration is wrong, and the fix is the declaration (`T?` where nil really flows)
or the caller, so a test cannot pass a wrong kind to a typed `cosmic/` parameter on purpose. The run fails too, in its summary, for a violation a `pcall` swallowed, naming the first. A parameter declared
elsewhere is reported, and the function runs on. A variadic parameter, `self` and a parameter typed `any` are not
checked. It writes no check of a returned value or a field write yet, so the run reports rows of kind `fact` and
`parameter`. The compile is keyed apart from an unchecked one ([`importer.checked_tool`]).
cosmic's callers are typed Teal, so a module need not re-check a declared type at run time; it checks the values a
type cannot express and data from outside the program.
The tests of declared boundaries (`*_declared_types_test.tl`, through [`build/type_watch.tl`]) skip in every run until a
compile writes the checks of returns and fields as well: a pass would check only the parameters.

Three tests compare the bytecode of a module with the binary's
([`build/harness_epoch_test.tl`], [`cosmic/store_seal_test.tl`],
[`build/rebuild_lock_tool_test.tl`]) and skip in a checked run, whose
modules carry checks.

The run ends with the count, the distinct violations and the commonest
ten, each with the line that sent the value: the caller for a parameter,
the `return` or the write for the others. `cosmic sql --build 'SELECT *
FROM type_violations'` lists all of them, from the latest checked run, and
`type_violation_tests` the tests that met each, which are the tests that
never stand. A line beneath says how many fact wraps and parameter checks the
compile wrote, which is 0 for an unchecked compile whatever the tests did, and
how many tests stood.

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
- A place that is not a local (a field, a global, `a.b.c`) is not checked, as
  the narrowing does not hold one. An index `t[k]` is not either, but for an
  element a length test proved (above).
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

CI runs the whole suite so in the `checked-narrowing` jobs of a full run,
two shares of it (`cosmic-driver cosmic_ci/driver.tl platform
checked-narrowing`, `--check-types --shard I/2`), standing on the checked
verdicts of earlier runs as the legs' suites stand on theirs (ci/README.md's
`checked-narrowing`), and `bin/cosmic test --check-types` runs it anywhere.

## fuzz tests

A parser that reads untrusted bytes gets a `*_fuzz_test.tl` beside it,
driving [`build.fuzz`]'s `run`. A generator draws each input from a
seeded source. A check must hold for all of them. The module doc of
[`build.fuzz`] has the full contract.

- `FUZZ_SEED` and `FUZZ_ITERS` (64 by default) choose the inputs.
- `FUZZ_SECONDS` bounds the seconds a property spends drawing (none by
  default): past them, with 64 inputs drawn, it stops, says how many it
  drew and is held to those. The weekly `fuzz.yml` sets 120, for the
  properties whose every input costs a tenth of a second or more.
  Prefer it to a `max_iters` guessed from a measurement.
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
  weekly `fuzz.yml` fuzzes every property on the checked core with a
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
reading the tree's markers.

## a test's files, output and time

### temporary files

Each test has a scratch directory, `<scratch>`. The test function
receives `<scratch>/tmp`, a link to the fresh, empty, writable directory
`<scratch>/real`. The worker's `TMPDIR` is `<scratch>` itself, so
[`Fs.mkdtemp`] and every process the test starts make their temporary files
there, as siblings of `tmp` (`<scratch>/xXXXX`), not inside it. After a
pass the runner removes the whole scratch directory, `tmp` and those
siblings with it. Sandboxed, `<scratch>` is a tmpfs of the worker's own and
is gone after a failure too, unless the module declares what gives its
worker a directory of the host instead (`system`, `tool`, `noexec`, a host
cache, a directory to read). There, and unsandboxed
(`COSMIC_TEST_SANDBOX=0`), a failing test's scratch directory is kept, and
its failure says where. A sandboxed
test has no write grant anywhere else.

### a cache of the code under test

A sandboxed test reads only its grants and writes only its scratch. A cache
that the code under test keeps outside them, such as a directory under
`out/` of the project, is not there in the worker: each test finds it
missing, cannot keep what it would write there, and never hits it. This is
by design. A cache
that could change a result would make a verdict turn on what its key does
not name. `caches` in [`Test.policy`] admits only `"zig"` and `"bootstrap"`,
whose contents are addressed by what they hold and never change a result.

Give the code a seam instead: take the cache's path as a parameter or an
option, and have the test pass a directory under its `tmp`, so the test can
fill the cache and read it back within itself. Or have the test run the code
with no cache.

```text
-- the module: where it keeps its cache is the caller's choice, nil for none
function Lookup.answer(key: string, cache_dir?: string): string

-- the test: a cache of its own, in its scratch
local function test_a_lookup_keeps_its_answer_in_the_cache(tmp: string)
  assert(Lookup.answer("a", tmp) == "A")
  assert(Fs.read(tmp .. "/a") == "A")
end
```

### one worker for a module's tests

Sandboxed, a module's tests share a worker where they can: the worker loads
the module once and runs each test in a copy of itself (a fork), one after
another. A module's tests are dealt to as many workers as may run at once
(`--jobs`), so they still run beside each other; a module of no more tests
than that has a worker for each. A run of more modules than that has other
modules' tests to run beside them, so there a worker is given at least
eight tests, where its module has them. The run says how many tests ran
so:

```text
test: forks: 5557 tests ran in copies of 1123 workers, 0 of which retired early
```

Each test keeps what a worker of its own gave it:

- a process of its own. A test that exits, crashes or hangs fails by itself;
  its worker's sandbox ends with it, and the module's other tests run in
  another worker.
- the module as it loaded, and nothing an earlier test did to it: a copy is
  made from the worker, which runs no test itself.
- its directory empty, and `TMPDIR` holding nothing an earlier test made.
  A worker goes on to the next test only after one that passed and left no
  process running. It then removes all the test made where it can write
  (the sandbox's `/tmp`, or its scratch directory where that is the
  host's), in its directory and beside it, and gives each directory that
  was there the mode and the times it had. The time a file of the host's
  that no test can write was last read is not put back: every worker's
  reading moves it. Where the worker cannot put a thing back, or where a
  file that was there before the test has changed, and after any test that
  did not pass, the worker retires, and its sandbox ends as a worker's
  does.
- its own output: what the load printed, then what the test printed, as it
  printed it, so a test that hangs is shown with what it had said.
- its own deadline, from when its copy was made.
- the descriptors a worker of its own has, by the same numbers.
- where its worker's scratch directory is the host's (a module that declares
  `system`, `tool`, a host cache or a directory to read), a failing test's
  directory kept, as a worker of its own leaves it: it is the last test that
  worker runs. Such a worker empties no directory before the runner has
  passed its test, which may fail one the worker saw pass (a test that
  made no call to `assert`, in a held run).
- no way to its worker: a copy is held to signalling itself and what it
  starts, so `kill(-1)` reaches what it reached in a worker of its own.

A worker forks only where every test can be given that:

- a sandbox holds the worker, so all it can write is the sandbox's `/tmp`,
  or its scratch directory alone where that is the host's, which the worker
  puts back between tests. A host cache a module declares is every worker's
  as it is, and is left so.
- the module declares no `loopback`, whose sockets one test would leave the
  next, no `nests`, whose worker no Landlock ruleset holds, and no `noexec`,
  whose private directory the worker does not put back.
- the kernel's Landlock scopes signals (ABI 6, Linux 6.12).
- the load left the worker as it was but for its memory: it started no
  process and left no descriptor open, no file written, no filter added and
  no signal's handling changed. A module whose load does one of these runs a
  worker for each test, and the run says so, naming the first and what its
  load left. So does one whose worker cannot tell: its `/proc` cannot be
  read, what its load printed could not be kept, or it is not alone in its
  pid namespace.

An unsandboxed run (macOS, `COSMIC_TEST_SANDBOX=0`) runs a worker for each
test.

What a test in a copy sees that one in a worker of its own does not:

- its process id is not 2, and its parent is its worker, not the namespace's
  init. A test does not assert a process id it did not ask for.
- what the module computed as it loaded (a clock reading, a random draw, its
  own process id) is the same for every test of the module that shares the
  worker. A test that needs a value of its own computes it in the test.
- the time the status of its directory, of `TMPDIR` and of `/tmp` last
  changed (`ctime`) is when the test before it was cleared away, not when
  its worker started.

No key says whether a test ran in a copy, so a verdict earned in one stands
where a worker of the test's own would run it, and the other way.

### output

What a test prints is shown only when it fails, beneath its failure as
`  | ` lines: its last 4096 bytes, under a line that says so when there
were more. A run in which a passing test printed says how many of those
that ran did, and names the flag: `cosmic test --show-output` also lists it, whole, for a
test that passed:

```text
test: PASS  suite.chatty_test test_prints_values
  | value=42
  | second line
```

Only a test that ran prints. A test whose verdict stands is not run, so the
flag says how many stood and prints nothing for them: add `--all` to run
them. The flag changes nothing a verdict is keyed or kept by. A run with it
stands on the verdicts of a run without it.

### time

Each test has 30 seconds. `--timeout <seconds>` or `COSMIC_TEST_TIMEOUT`
sets another for the run. The limit a test ran under is part of its key.

A module whose tests legitimately run long, such as one that starts
`cosmic test` or builds a program, declares a longer limit for itself:

```text
Test.policy {
  profiles = { "cosmic" },
  grants = { { path = "o/bin", letters = "rx" } },
  timeout = 120,
}
```

`timeout` is whole seconds, 1 to 3600. It lengthens the run's limit and
never shortens it. A module that names fewer seconds than the run gives
runs under the run's. Its key holds the limit it ran under, so a verdict
that stood under one limit does not stand under a longer one. A module's
`timeout` is not a way out of a slow test: a timeout is a failure to
investigate (below), and a test that is slow by accident is made fast,
not given more time.

A run says where its time went on the line before its summary:

```text
test: time: building 1.2 s, keying 3.4 s, running 15.9 s (10.0 s in 562 tests, up to 4 at a time; the runner 4.1 s starting their workers and 1.3 s recording them), settling coverage and records 0.4 s
```

`building` is from the checkout's lock taken to the tree compiled: the
stage, the probe of whether workers can be sandboxed, and the compile.
`keying` is from there to the last test looked up: the tests chosen, each
one's key made and looked up, and the closure stores written for the keys.
`running` is from there to the last worker collected. Of that, the tests'
own time is what their workers reported, summed over the tests whose
worker this run collected, so it can exceed the stretch where several run
at once; a test that started no worker (its host lacks what it requires,
or its start was refused) is in the summary's `ran` and not here. While
the runner starts one worker, which includes writing a sealed database it
has not written yet, or records one, it starts and collects no other.
`up to 4 at a time` is the limit (`--jobs`, by default one more than the
processors), not how many ran at once.
`settling` is the coverage and the records kept. The `runs` table holds
each test's own time ([measuring](guides/measuring.md)).

### coverage

Every run records the lines the tests reached in the `coverage` table of
the build directory's `build.db`: a row of `ran_at_ns` (when the run
started), `path` (the module's name), `line` and `hit` for each line. Query
the latest run with `cosmic sql --build`:

```text
cosmic sql --build "SELECT path, count(*) AS lines, sum(hit > 0) AS hit
  FROM coverage WHERE ran_at_ns = (SELECT max(ran_at_ns) FROM coverage)
  GROUP BY path ORDER BY hit * 1.0 / lines LIMIT 10"
```

`coverage_by_test` holds the lines each test reached, each module's beside
the text they are numbered in, but for a module a pure store imported: its
are the numbers of the instructions it ran, each past 2^24
([`build.lua_tail`]'s `ordinal_base`), beside a prefix of the digest of its
bytecode stripped. A row taken from another checkout's verdict begins with
the line `lines as distances`, and each of its numbers after a module's
first is the distance from the one before. The run's own `test: coverage`
line is informational and never a failure.

A sandboxed test given the pure store ([the pure store](#the-pure-store))
reaches the lines of the modules it imports as an unsandboxed one does. Their
bytecode carries no line, so a comment moves no key. The core counts each
instruction of such a function as it is about to run, by its number in the
chunk (core/coverage.c, told by Lua through `patch/lua/`'s instruction
coverage, after an instruction budget has had its turn, so an instruction
a budget stops before is not counted), and the runner places each at the
line this run's text has it on ([`build.lua_tail`]'s `instruction_lines`).
Its row keeps the instructions' numbers, not those lines, named by the
module's bytecode stripped and not by its text: a comment above them later
lets the verdict stand, since the key holds that bytecode, and a run that
stands on the row places each number at the line its own text has that
instruction on, which is exact while the verdict stands. The numbers it cannot
place are dropped, and the figure says it is partial and why. A tool
that reads a row's numbers as lines alone, older than these rows, finds the
row names another text than the module's and drops it the same way, so it
never credits an instruction's number as a line.
An instruction the runner cannot place is an error of the run, never a
line of another text, and no verdict of a test that reached it is kept, so
no later run stands on a row that lacks its lines.

## other hazards

- Every test's directory is at a path padded to macOS's length
  (`scratch_length` in [`build.test_sandbox`]). A bound on a path's
  length is met on every leg.
- The directory's name holds a `-`. Escape a path before putting it in
  a Lua pattern: `(path:gsub("%p", "%%%0"))`.
- A worker that writes to `/tmp` itself, past its `TMPDIR`, writes to a
  `/tmp` of the sandbox's own. It is gone with the worker, and no later
  test meets it ([one worker for a module's tests](#one-worker-for-a-modules-tests)).
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
runs, sandboxes or keys tests, and it asks nothing of them.

Every verdict key holds a digest of the harness's code, beside `epoch`
in [`build.harness_epoch`]. The digest (`harness` in [`build/test_key.tl`])
is taken over each harness module's bytecode with its debug information
stripped, computed once per run. An edit to the harness that changes
what it does (a constant, an instruction, a function's shape) therefore
runs every test again with nothing recorded by hand. A comment, a blank
line, a moved line or a renamed local changes none of it and runs
nothing again. A compiler change that emits other bytecode for the
harness moves it as an edit does.

The harness is what every worker loads, the sandbox's maker, and the
code that makes a key, looks a verdict up or keeps one:
[`build/test_key.tl`] and [`build/stamp.tl`], each of which it holds
alone, and the closure of [`build/declared_key.tl`] and the shared verdicts.
[`build.harness_epoch_test`] holds that set to everything a worker runs
and to the standard-library modules `library` in
[`build.harness_epoch`] names. The runner around it,
[`build/test.tl`], and the types they share, [`build/test_state.tl`], are
not held: an edit to either (a progress line, the coverage, the summary)
moves no digest. Where a part of the runner could be either, it is in
[`build/test_key.tl`].

The hooks of a checked run (`install_checks`, the hooks it defines, what
they record) are the code of [`build.test_worker`], a harness module, so
an edit to them moves every key, the ordinary suites' too.

`epoch` stays as a lever for a change the modules' code does not show:
the host or the toolchain a verdict stands on, or verdicts cached wrongly
under the keys as they were. Bump it in that edit. A bump appends the old
token to `retired` and draws a new one;
[`build.harness_epoch_test`] prints both lines. On a merge conflict in
`epoch`, keep neither side. Set the bare count, and the test prints a
fresh value. Two bumps conflict on that line by design.

A merge-queue run that finds the change's keys moved runs those tests,
and the shared verdict cache has no entry under them.

Other rules:

- A held run fails instead of falling back. Hold a run with
  `COSMIC_TEST_SANDBOX=1`, `COSMIC_SANDBOX=must` or
  `COSMIC_CI_REQUIRE_SANDBOX=1`. CI's Linux legs hold theirs.
- Never set `COSMIC_TEST_HARNESS_EPOCH`, `COSMIC_TEST_HARNESS_SALT` or
  `COSMIC_TEST_PLATFORM=other` to run a suite. They are for the runner's own tests
  ([`build.sandboxed_verdicts_test`]).
- A tool's database carries, as stamps, the identities a run keys by that
  are functions of the tool's own rows ([`build.stamps`]).
  `COSMIC_STAMPS=0` has a run work them out instead, and reach the same
  keys ([`build.sandboxed_verdicts_test`] holds it to that). It is never
  needed to run a suite.
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
[`bin/zig`]: ../bin/zig
[`build.checker_declarations`]: ../build/checker_declarations.tl
[`build.closure_store`]: ../build/closure_store.tl
[`build.code_walk`]: ../build/code_walk.tl
[`build.compile_grammar`]: ../build/compile_grammar.tl
[`build.confine`]: ../build/confine.tl
[`build.example_checks`]: ../build/example_checks.tl
[`build.fuzz`]: ../build/fuzz/init.tl
[`build.grammar_mode`]: ../build/grammar_mode.tl
[`build.harness_epoch_test`]: ../build/harness_epoch_test.tl
[`build.harness_epoch`]: ../build/harness_epoch.tl
[`build.host_names`]: ../build/host_names.tl
[`build.lua_tail`]: ../build/lua_tail.tl
[`build.paths`]: ../build/paths.tl
[`build.pipeline`]: ../build/pipeline.tl
[`build.reads.all`]: ../build/reads/all.tl
[`build.reads.analyzer`]: ../build/reads/analyzer.tl
[`build.reads.links`]: ../build/reads/links.tl
[`build.reads.pipeline`]: ../build/reads/pipeline.tl
[`build.reads.receivers`]: ../build/reads/receivers.tl
[`build.rebuild`]: ../build/rebuild.tl
[`build.sandboxed_verdicts_test`]: ../build/sandboxed_verdicts_test.tl
[`build.stamps`]: ../build/stamps.tl
[`build.standard_text`]: ../build/standard_text.tl
[`build.symbols`]: ../build/symbols.tl
[`build.test_child`]: ../build/test_child.tl
[`build.test_returns`]: ../build/test_returns.tl
[`build.test_sandbox_probe`]: ../build/test_sandbox_probe.tl
[`build.test_sandbox`]: ../build/test_sandbox.tl
[`build.test_worker`]: ../build/test_worker.tl
[`build.this_program`]: ../build/this_program.tl
[`build.tree_checks`]: ../build/tree_checks.tl
[`build/declared_key.tl`]: ../build/declared_key.tl
[`build/dispatch_sites.tl`]: ../build/dispatch_sites.tl
[`build/dispatched_features_test.tl`]: ../build/dispatched_features_test.tl
[`build/fact_hook_tool_test.tl`]: ../build/fact_hook_tool_test.tl
[`build/harness_epoch_test.tl`]: ../build/harness_epoch_test.tl
[`build/rebuild_lock_tool_test.tl`]: ../build/rebuild_lock_tool_test.tl
[`build/stamp.tl`]: ../build/stamp.tl
[`build/test.tl`]: ../build/test.tl
[`build/test_key.tl`]: ../build/test_key.tl
[`build/test_state.tl`]: ../build/test_state.tl
[`build/type_watch.tl`]: ../build/type_watch.tl
[`build/zig.tl`]: ../build/zig.tl
[`Check.Checked.narrowed`]: ../lang/check.tl
[`ci/cosmic_ci/capabilities.json`]: ../ci/cosmic_ci/capabilities.json
[`ci/README.md`]: ../ci/README.md
[`cosmic.layout`]: ../cosmic/layout.tl
[`cosmic.sandbox`]: ../cosmic/sandbox/init.tl
[`cosmic.store`]: ../cosmic/store.tl
[`cosmic.template`]: ../cosmic/template/init.tl
[`cosmic.test`]: ../cosmic/test.tl
[`cosmic.vector`]: ../cosmic/vector.tl
[`cosmic/store_seal_test.tl`]: ../cosmic/store_seal_test.tl
[`Coverage.native_functions`]: ../cosmic/coverage.tl
[`declared_key.dispatched`]: ../build/declared_key.tl
[`declared_key.host_cpu`]: ../build/declared_key.tl
[`declared_key.host_split`]: ../build/declared_key.tl
[`doc/performance.md`]: performance.md
[`Fs.mkdtemp`]: ../cosmic/fs.tl
[`Fuzz.label`]: ../build/fuzz/init.tl
[`Fuzz.more`]: ../build/fuzz/init.tl
[`importer.checked_tool`]: ../build/importer.tl
[`Json.diff`]: ../cosmic/json.tl
[`lang.boundary_checks`]: ../lang/boundary_checks.tl
[`lang.check_programs`]: ../lang/check_programs.tl
[`lang.codegen`]: ../lang/codegen.tl
[`lang.fact_wraps`]: ../lang/fact_wraps.tl
[`lang/check_assigned_fuzz_test.tl`]: ../lang/check_assigned_fuzz_test.tl
[`lang/check_flow_fuzz_test.tl`]: ../lang/check_flow_fuzz_test.tl
[`lang/check_total_fuzz_test.tl`]: ../lang/check_total_fuzz_test.tl
[`Store.withheld`]: ../cosmic/store.tl
[`sys.cpu_features`]: ../core/syscalls.h
[`Test.passed_unchecked`]: ../cosmic/test.tl
[`Test.policy`]: ../cosmic/test.tl
[`Test.skip`]: ../cosmic/test.tl
