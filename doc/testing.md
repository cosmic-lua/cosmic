# testing

How to write a test for cosmic and how `cosmic test` decides to run it.
The authoritative detail lives in the modules this doc links. This doc
gives the rules an author acts on.

## where tests live

A test is a top-level `local function test_*` in a `*_test.tl` file
([`cosmic.layout`]). Do not add a top-level `return` to a test file.

Write small regression cases that fail for the reported bug. Do not
pin incidental implementation.

Run the suite with `timeout 30 bin/cosmic test`. A run after a small
edit takes seconds, because most tests stand (below).

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
- `COSMIC_VERDICT_CACHE` names another cache file. `0` means none.

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

- A test requires a module of the tree it reads at its top level, with
  a literal name. A computed name, `pcall(require, ...)` or a type-only
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
- To run Lua in the program only (`-e`), the profile `"cosmic"` alone
  is enough (`lua`). Its key holds the closure, not the whole program.
  It is refused beside the profile `"system"`, the `o/cosmic.db` store
  grant or a `/cache/` grant, since a host program or a cosmic a cache
  holds could start the program with no hold on what it loads. Declare
  the `o/bin` grant beside the profile instead, to run the program
  itself.
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
found. A `path:` needs a `host` grant of the same path. A `program:`
needs the profile `"system"` and `env = { "PATH" }`.

A test of what only the checked (sanitized) core reaches, such as a
refused allocation or a fault point, declares `requires = { "checked" }`.
Every other core finds it not applicable. The checked leg promises it.

### CI legs

Each CI leg promises a list of requirements in
[`ci.cosmic_ci.capabilities`]. Add a name to a leg's list in the same
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
[`build.confine`]: ../build/confine.tl
[`build.fuzz`]: ../build/fuzz/init.tl
[`build.harness_epoch_test`]: ../build/harness_epoch_test.tl
[`build.harness_epoch`]: ../build/harness_epoch.tl
[`build.host_names`]: ../build/host_names.tl
[`build.paths`]: ../build/paths.tl
[`build.sandboxed_verdicts_test`]: ../build/sandboxed_verdicts_test.tl
[`build.test_sandbox_probe`]: ../build/test_sandbox_probe.tl
[`build.test_sandbox`]: ../build/test_sandbox.tl
[`build.this_program`]: ../build/this_program.tl
[`build.tree_checks`]: ../build/tree_checks.tl
[`ci.cosmic_ci.capabilities`]: ../ci/cosmic_ci/capabilities.tl
[`cosmic.layout`]: ../cosmic/layout.tl
[`cosmic.sandbox`]: ../cosmic/sandbox/init.tl
[`doc/performance.md`]: performance.md
[`Fuzz.label`]: ../build/fuzz/init.tl
[`Fuzz.more`]: ../build/fuzz/init.tl
[`Test.passed_unchecked`]: ../cosmic/test.tl
[`Test.policy`]: ../cosmic/test.tl
[`Test.skip`]: ../cosmic/test.tl
