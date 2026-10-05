# Iterating on cosmic

- Use [`bin/zig`], the repository's pinned compiler, rather than a system Zig.
- Use a separate worktree for each independent fix. Check `git status --short`
  before building or switching branches: untracked test files can enter a build.
- Keep `vendor/` unedited; express vendor changes as records under `patch/`.
  [`bin/vendor`] refetches a tree from its PIN, keeping only what the build reads.
  Generated output under `o/` must not be committed.
- Workflows, and the local actions under `.github/actions/`, are YAML's
  flow style, in the subset [`build/workflows_test.tl`] holds them to and
  the layout `o/bin/cosmic fix` writes ([`build/flow.tl`]): run `o/bin/cosmic
  fix` and `o/bin/cosmic test build/workflows_test.tl` on a change under
  `.github/`. A step's script longer than a line or two lives under
  `.github/scripts/`. A job gets the pinned CI
  driver on its PATH with `uses: ./.github/actions/cosmic-driver`.

## Build, format, test

1. Run `bin/zig build boot` in a fresh worktree. This builds the required cores
   and stages the tree into `o/build.db`, the working database every later
   build reads; copying an existing cosmic executable alone is insufficient to
   test a fresh checkout. zig's caches are shared by every checkout
   (`zig-project` and `zig-global` under `~/.cache/cosmic`, see
   [`build/zig.tl`]), and every C file compiles from a copy there, so a
   fresh worktree compiles none of it again; delete them to reclaim the
   space. The Teal compiles and parses are shared the same way, through
   `cache.db` in `$XDG_CACHE_HOME/cosmic/build` (`~/.cache/cosmic/build`,
   [`build/shared_compiles.tl`]):
   `COSMIC_BUILD_CACHE` names another file, `0` none, and a build line
   says how many modules and sources came from another checkout.
   `o/bin/cosmic db` says what the
   databases under `o/` hold -- `o/cosmic.db`, the tree's projection;
   `o/carried.db`, that projection less the tree's own tests and
   examples and every doc but the public standard library's, which
   the tool carries; `o/build.db`, the working
   database -- and how the last few builds went;
   `o/bin/cosmic sql [--build|--store|--db <path>] '<statement>'` runs one
   read-only query against one of them, with no script and no build;
   `o/bin/cosmic docs <symbol>`
   shows a symbol's signature, doc comment and use count, and
   `o/bin/cosmic uses <symbol>` lists every `file:line` that refers to it.
2. Edit source and tests, then run `o/bin/cosmic fix <changed-paths>`.
   `fix` checks syntax and tree equivalence, and builds the tree as
   `cosmic test` does: a type error or a break of
   [`build/contracts.tl`]'s rules fails it, saying why. A C
   path is written back in Lua's own layout ([`build/c/layout.tl`]) and
   checked against the rules in [`build/c/rules.tl`] (see C, below).
   The checks only the whole tree can answer ([`build/tree_checks.tl`]:
   every export earned, every doc anchor its own, and the like) run in
   `o/bin/cosmic fix --check .`, as CI runs it, and not in a `fix` of
   some paths: run it before pushing a change to what they read. Since
   they read the tree's projection, that run also refuses a tree that
   does not build.
3. A tool older than the tree rebuilds itself and re-enters the command the
   moment it notices, so `o/bin/cosmic test` after an edit is enough. An
   edit to Teal rebuilds its database; a change to the core's C under
   `core/`, to `build.zig`, [`build/launcher.tl`] or [`build/artifact.tl`], or
   to a vendored library's pin or patches runs `bin/zig build boot` first,
   its output on stderr.
   `COSMIC_AUTO_BOOT=0` makes the tool refuse instead, exiting 3 (CI's
   driver sets it). A boot that fails stops the command: check its exit
   status rather than piping it away. Only the tree's own tool (under
   `o/`) rebuilds or boots; another cosmic run in the tree when it is
   stale -- a release, the bootstrap cache's -- refuses, exiting 3.
   One `cosmic test` runs per checkout at a time: it holds
   `o/rebuild.lock` ([`build/rebuild_lock.tl`]) for its whole run, and so
   do a rebuild of the tool, a `bin/zig build boot` or `sanitized` (by
   hand or not) and a write of `o/cosmic.db`. A run that finds another
   holding it says which, what it is doing and the lock it waits for,
   waits for it, and says so again every few minutes; one that must
   rebuild re-enters on the tool that run wrote ([`build/reboot.tl`]). So
   `cosmic docs`, `cosmic uses` or `cosmic foo.tl` after an edit waits
   for a whole test run in the checkout, and a `timeout` around `cosmic
   test` counts the time it waits for another. A `cosmic test` a test
   starts must run in a tree of its own, whose lock it takes: one run in
   this checkout would wait on the run that started it until the test
   timed out.
4. Run `timeout 30 o/bin/cosmic test`. Its workers run sandboxed to each
   test's declared inputs where the kernel can -- the default on Linux --
   and a test whose declared inputs, closure, core, harness epoch, timeout
   and host are what they were when it last passed is not run again
   (below), so a run
   after a small edit takes seconds. Every sandboxed checkout also shares
   its passing verdicts through `~/.cache/cosmic/verdicts/verdicts.db`,
   keyed without the tree's location: a fresh
   worktree runs only what no checkout has run on the same content and core,
   and a test that failed in this checkout never stands on another's pass.
   So a test must not depend on where the tree is (its absolute path); CI
   moves the checkout to a path chosen by the commit and the leg to catch
   one that does: a re-run meets the same path, a new commit a new one.
   A sandboxed worker sees the tree at /tree wherever it is, so only an
   unsandboxed leg (macOS) meets the moved path. There, as in every
   unsandboxed run, a key holds the tree's path, so no verdict
   stands at a path it was not reached at: a gating run (a push, the
   merge queue) places the tree by the leg alone, at one path from commit
   to commit, and stands on what it ran before; the scheduled run places
   it by the commit, and every test runs to meet the new path
   ([`.github/scripts/place-tree.sh`]).
   `COSMIC_VERDICT_CACHE` names another file, `0` none; `--no-shared`
   (`COSMIC_TEST_NO_SHARED=1`) stands on none but still shares; a test's own
   `cosmic test` has none unless it names one.
   Run sandboxed (the default where the kernel can), a test is keyed by
   what it declares -- its closure, its [`Test.needs`], their contents and
   values, the core -- and by the host (its kernel, processor, user and
   capabilities; its packages and system only for a module that declares
   `system`), before it runs
   ([`build/declared_key.tl`]): it stands while none of that changes, and
   nothing is assumed. The test harness -- what every worker loads, the
   sandbox's plan, the code that computes a key -- is keyed by
   `epoch` in [`build/harness_epoch.tl`], not by its source, so an edit
   to it reruns only the tests that import it; but
   [`build/harness_epoch_test.tl`] fails until `acknowledged` there
   holds each harness module's digest (its source and bytecode, so a
   compiler change that compiles the harness otherwise moves it too),
   one module to a line between blank ones, sorted, so changes to
   different modules merge cleanly: it names each module that moved or
   has no entry, printing the line to set or add, and each stale entry,
   whose line to delete. Bump
   `epoch` in the
   same edit where the change can alter a pass or a fail: what a worker
   is given, how it is judged, how a key is computed, and a sandbox's
   hold or bind tightened (a soundness fix that moves no other part of a
   key, so a pass earned through the hole does not stand). `epoch` is
   a count and a random token (`"N-xxxxxxxx"`), the count one past the
   tokens `retired` holds, so two branches' bumps conflict in git
   rather than merge as one edit that stands on verdicts either branch
   earned alone: a bump appends the old token to `retired` and draws a
   new one, pasting the two lines the guard prints when the harness
   moves. Resolve a conflict on `epoch` by keeping neither side: set
   the bare count, and the guard fails, printing a fresh value. A
   merge-queue run whose change moves that file runs every test
   (`--all`). `COSMIC_TEST_HARNESS_EPOCH` stands in for a bump in the
   tests of the runner alone ([`build/sandboxed_verdicts_test.tl`]);
   never set it to run a suite. The harness is what every worker
   loads, the sandbox's maker, build.test and cosmic.child (which
   applies the sandbox) each alone, and the closure of the key's code
   over value requires (a `local type` one is not followed: its effect
   is in the importer's bytecode). Its modules reach the host
   through raw bindings and the standard-library modules
   [`harness_epoch.library`] names, each with its reason, and no other
   `cosmic.*` module ([`build/harness_epoch_test.tl`] holds them to it);
   what else of the tree the runner calls -- the sandbox probe
   ([`build/test_sandbox_probe.tl`]) -- must fail
   loudly, never pass; and what a harness module calls through a
   library table a test can replace, it takes as a local at load. A test reaches no network but loopback,
   and loopback is 127/8: [`Test.needs`] takes `network` as a list of
   addresses `127.a.b.c`, whose worker runs offline on a loopback of
   its own and is keyed. A sandboxed worker whose module declares no
   `network` has no network at all: its filter refuses it an inet
   socket (under the older sandbox, `COSMIC_TEST_POLICY=0`, it too runs
   on a loopback of its own). `network = true`, any
   other host, `::1` and `localhost` are refused, for this tree and
   every project, naming the rule. A test that needs a service starts
   its own on 127.0.0.1. A
   worker, and every process it starts, is given at o/cosmic.db the
   store of its module's import closure alone, keyed by its bytes.
   Sandboxed or not, a worker whose module does not declare `store`
   (`tool` does not lift it) holds every other lookup in the store to
   that closure too
   ([`build/test_worker.tl`]'s `hold_store`): [`Store.bytecode`] or
   [`Store.source`] of a module of the tree outside it, or a searcher
   called by hand, answers none, [`Store.meta`] of a row its key does not
   hold (the compiler's identity outside `compiler_readers`'s closures,
   `projected`, `written_by`) raises unless a database the test attached
   itself answers it, and [`Store.databases()`], whose handles read every
   module's rows, raises, each naming the fix. So require a
   module the test reads at its top level (`local type _ = require(...)`
   for a declaration a type-checked snippet needs), or declare
   `store = true` where a test reads rows of modules outside its closure
   (their docs, catalog or bytecode, that way, through a verb run
   in-process, or by opening o/cosmic.db itself), and only there -- in a
   module of its own, if the rest of its tests need not -- since that
   test runs again on every edit to the tree. A module left declaring
   `store` says why above its declaration. Only a test of one module
   may read the store so: a check over the whole tree is no test, and
   goes in [`build/tree_checks.tl`].
   Each sandboxed worker starts under a [`cosmic.sandbox`] policy
   ([`build/test_policy.tl`]), held by a Landlock ruleset and a seccomp filter
   of the promises it declares, as step (c) and (d) of #2621's
   doc/plans/sandbox.md have it. `COSMIC_TEST_POLICY=0` starts them by the
   sandbox [`build/test_sandbox.tl`] plans instead, until step (e) deletes
   that path; `--policy` (`COSMIC_TEST_POLICY=1`) fails a run whose workers
   cannot be sandboxed rather than run them without a policy. The two paths'
   verdicts stand apart. A root that lacks CAP_SETUID, CAP_SETGID or
   CAP_SETFCAP cannot map the user a policy runs as (a program of a policy
   never runs as root), so its run starts workers by the older sandbox
   instead, and the summary says `older sandbox (<why>)` beside `sandboxed`,
   as it says `under a policy` for the default. A module whose workers the policy path cannot yet
   hold -- one that nests and declares neither `store` nor `tool`, which
   waits for a per-closure artifact -- has its tests skipped with that
   reason; a module declaring what no policy says (`env = { "*" }`) fails.
   `--all` (`COSMIC_TEST_ALL=1`) runs everything. The worker still reads
   /proc, /dev/null, /dev/zero, /dev/full and /dev/urandom, keyed only
   through the host's identity, and the program, its core and its
   database, keyed through the runtime's identity but for the database's
   modules, which the hold above keeps a test from reading through the
   store unless it declares `store`, nor through the descriptor a portable
   start keeps on the program, which every binding refuses
   (core/check.h's `cosmic_checkfd`), nor, sandboxed, by the program's
   own name, which only a `tool`'s worker is given. A test that starts this
   program declares `tool = true`: sandboxed, one that does not is
   refused it. `tool` gives the program and
   nothing else. A test that confines a process in a root of its own --
   a sandbox that unveils, build.confine's `confine`, or a `cosmic test`
   it starts whose workers are sandboxed -- declares `nests = true`:
   sandboxed, every other worker is held by a Landlock ruleset, under
   which the kernel refuses the mounts a root is made of, so such a
   start is refused outright, naming `nests`, and fails the test rather
   than falling back to running unconfined; a `cosmic test` started
   there refuses to sandbox its workers.
   Unsandboxed (`COSMIC_TEST_SANDBOX=0`, or where the kernel cannot, as
   on macOS), a test is keyed as a sandboxed one is, by what it
   declares, and by where the tree is, which its worker sees; nothing is
   assumed, and one that starts a process or reads outside the tree
   stands on its declaration like any other. Its worker gets only the
   environment it declares and the store of its closure, but nothing
   else holds it to its declaration, which a sandboxed run (a Linux leg
   of CI) must enforce: a read it does not declare moves no key there.
   Its verdicts are kept apart from sandboxed ones, and shared only
   through a file `COSMIC_VERDICT_CACHE` names (as CI's macOS leg
   does), and so only with a checkout at the same path; without one it
   shares none, and the summary says so.
   Only the sandbox's own tests nest one sandbox in another with
   build.confine's `confine`: where the kernel cannot confine a process,
   `confine` starts it unconfined; `must_confine` fails
   the spawn, and the test, instead, naming the part of the sandbox
   refused and its errno. `COSMIC_SANDBOX=must` (off by default) makes
   every `confine` one. Likewise a test nests the workers of a
   `cosmic test` it starts in its own sandbox only where its assertion
   is about their sandbox; every other run of `cosmic test` a test
   starts sets `COSMIC_TEST_SANDBOX=0`, so it means the same on every
   host. Root confines only two deep (core/syscalls.c's `map_ids`), so
   a runner that is root runs each sandboxed worker as a user of its
   own, uid and gid 65532, mapped from outside (build/test_sandbox.tl's
   `runs_as`, spawn's `user`), whose sandbox nests at any depth as on
   CI's unprivileged runners, with no setup; its key holds that user.
   A worker whose module declares a host cache, which it writes as
   root, runs as root still, as every worker does where the host
   refuses the drop. Where the kernel refuses a sandbox that deep,
   those tests call [`Test.skip`] and
   return before asserting: the summary counts them skipped, beside ran
   and stood, and lists each with its reason (`test: SKIP`); no verdict
   is kept of one, so it runs again every run, in a held run too
   (`COSMIC_TEST_SANDBOX=1`, `COSMIC_SANDBOX=must` or
   `COSMIC_CI_REQUIRE_SANDBOX=1`), which counts a skip as any run does.
   A test that returns early because this host cannot be given the
   sandbox it is about calls [`Test.skip`] too, never passing as though
   it had checked -- but only where the platform could give it
   ([`build.confine`]'s `sandbox_platform`): off Linux (no user
   namespaces, Landlock or subreaper) it returns silently, a pass the
   key's kernel part pins to that platform. So does a test for what the
   policy path cannot yet give it (a unix socket by path, a mode with a
   setuid bit): it skips naming the reason, beside a `TODO:` that says
   what it waits on. A test that returns early for a host tool or
   artifact it lacks (jq, a portable artifact) does not skip.
   A test module declares what it reads beyond its import closure, its
   fuzz corpora and a pinned environment with a top-level
   `Test.needs { ... }` (`local Test = require("cosmic.test")`; see
   `o/bin/cosmic docs cosmic.test`). [`Test.policy`] is [`Test.needs`]'
   successor, being phased in: a module declares one or the other, in
   the fields of cosmic.sandbox's `Policy`, which the harness translates
   into the `needs` it stands for, so the key is the same (a grant "r" of
   a path is a read, the profile "system" is `system`, "cosmic" is `tool`,
   the promise "nest" is `nests`, `loopback` is `network`); what has no
   `needs` yet (a grant to write, `isolate`, `limits`, `set_env`) is
   refused. Nothing lists what a test reads
   undeclared: sandboxed, such a read finds nothing, and the test fails
   with its own error (a file not found, a program that could not
   start), which is the signal to declare it. Narrow a test before
   declaring a large set. No key holds a file's times, inode, device, link count or
   owner, which differ in every checkout: a test must not depend on them
   for a file it did not make; one that needs them makes its own files in
   its temporary directory and sets them (`utimensat`, a fresh file for a
   new inode). What it declares, it declares for the processes it
   starts too, which inherit its worker's sandbox and environment; build
   a process's environment from build.this_program's `environment()` only where
   the test means to choose it. The closure is what the build
   finds `require`d by a literal name. The `local type` requires of a
   non-test module are not followed (Teal erases them, so they load
   nothing, and an edit to what they name that the importer's bytecode
   does not answer runs no test again); every require of a test module
   itself is followed, `local type` ones too. A test's `require` of any
   other module of the tree (a computed name, `pcall(require, ...)`, a
   type-only one) fails, naming it: require it statically, at the top
   level. A test that type-checks a snippet reading
   a module's types brings the sources it needs in with `local type _ =
   require(...)` of its own.
   Each worker runs sandboxed to those inputs ([`build/test_sandbox.tl`]),
   wherever the kernel can sandbox one: the tree at /tree, its directory
   beneath /tmp, and nothing else of either, with every process it starts, so
   a test that reads what it does not declare fails. Nor has it the
   system's own paths (/usr, /bin, /lib, /etc and the like) unless its
   module declares `system = true`, as one that starts a host program --
   a shell, `sleep`, a compiler, o/bin/cosmic's `#!/bin/sh` launcher --
   must; a test that starts cosmic's core past the launcher
   (build.this_program's `program`) needs none, and one that reads a file or two
   of the system names them in `host`. A `host` path names a file, or
   /proc: a directory is refused -- by the build where it is written as
   one (a "/" after it, a variable's whole path), and at the test's
   start where the host has one there -- so declare the files a test
   reads, which its key holds by their contents. Where none can be (macOS, a host refusing user
   namespaces), or with `COSMIC_TEST_SANDBOX=0`, workers run unsandboxed
   and the run shares no verdict unless `COSMIC_VERDICT_CACHE` names a
   file; `COSMIC_TEST_SANDBOX=1` makes that a failure, as CI's Linux legs set it.
   Every test's directory, sandboxed or not, is at a path padded to
   macOS's length (`scratch_length` in [`build/test_sandbox.tl`]), so a
   bound on a path's length (a socket file's, a tar name's) is met on
   every leg, and a directory's name holds a "-": escape a path before
   putting it in a Lua pattern (`(path:gsub("%p", "%%%0"))`). A worker
   that writes to /tmp itself, past its TMPDIR, writes to a /tmp of the
   sandbox's own, which is gone with it. Treat an actual
   timeout as a failure to investigate, and report it separately from an
   assertion failure. Do not silently raise the limit; inspect elapsed time and
   the slow work first. To benchmark full test execution, delete only the rows
   from the `verdicts` table in `o/build.db` and run with
   `COSMIC_VERDICT_CACHE=0`; preserve the staged database and report the `ran`
   and `stood` counts with the elapsed time.

`ci/` is a tree of its own, with its own `o/`. After editing it, run
`../o/bin/cosmic fix --check` from `ci/`; that also builds and type-checks it.
Its `fixtures/*_test.tl` run only under the CI driver, which builds every
target: run [`ci/run-local`] (a few minutes) before pushing a change that
touches the launcher, startup, the artifact format, or a fixture, and
`ci/run-local fixtures` to re-run edited fixtures after that. CI's runners are
unprivileged; invoked as root, run-local runs the driver as an unprivileged
user (`COSMIC_CI_LOCAL_USER`, default `$SUDO_USER` under sudo, else
`nobody`): its test workers would drop root without it, but the driver
itself -- its builds, its unsandboxed legs, the fixtures, the caches it
writes -- would not, and would meet none of the permissions CI's does.
The launcher fixture's core
is a stand-in payload that checks nothing; a case about what the real core
does (its digest, its startup errors) belongs in `runtime_test.tl`.

A parser that reads untrusted bytes gets a `*_fuzz_test.tl` beside it,
driving [`build.fuzz`]'s `run`: a generator draws each input from a seeded
source and a check must hold for all of them. `FUZZ_SEED` and `FUZZ_ITERS`
(64 by default) choose the inputs, a failure is shrunk and kept in the test's
directory, and the `FUZZ_CASE=<property>:<case>` its report names checks that
one input again, run on that test's file (`FUZZ_SEED=<seed>
FUZZ_ITERS=<iteration>` reruns the way to it). A new generator draws a
collection's elements with [`Fuzz.more`] rather than a count drawn first, so
shrinking can cut any one of them. CI's
runs, which gate a merge, set `FUZZ_ITERS=0` and draw nothing; `fuzz.yml`
fuzzes every property each night on the checked core with a seed of its own;
a failure is a red run whose summary lists what failed. Once a failure is fixed, keep its input in
`testdata/fuzz/<property>/` as the report says: `run` checks that corpus
before drawing anything. A check calls [`Fuzz.label`] for what an input reached
(opened, read a body); a property `requires` the labels it exists to exercise,
so a generator whose inputs all stop at the first refusal fails rather than
passing while it checks nothing, and `shares` the least share of drawn
inputs that must reach one, set well under what a run reaches, for a
generator most of whose inputs would otherwise stop there (neither held
when `FUZZ_ITERS` is below 64).

Leave `TODO:` comments as the work goes, the moment one is due, rather than
recalling them at the end. One is due when a change settles for less than
the right fix because something is missing (an API, a binding, a module, a
patch the bootstrap pin lacks): put it where the better fix would go, naming
what it waits on ("once cosmic.sys carries ftruncate"), so the workaround
can be found and undone when that lands. One is also due for a gap met along
the way and left alone: say what is wrong and what the fix would be. A
`TODO:` whose fix cannot be made yet still goes in now: when it depends on
something unmet (an open PR, a release the pin does not name yet), name that
dependency in the comment ("once #2011 merges") rather than holding the
comment back until it lands. One that waits on the bootstrap pin says so as
"once ci/cosmic-driver.pin names ...", word for word, so the change that
moves the pin finds it. A feature no caller needs yet is no `TODO:`: it
goes in [`doc/roadmap.md`]. Nor is a limit decided for good not worth
closing: say it in a plain comment with the reason it stays. A gap left
only for now is still a `TODO:`. A gap named anywhere else -- a reply, a
summary, a "known limits" line in a PR description -- is a `TODO:` not yet
written: write it in the code before naming it there.

When the work is done, list every `TODO:` it added, with its `file:line` and
what it waits on, in the summary and the PR description. Take the list from
`o/bin/cosmic todos <changed-paths>`, which lists every `TODO:` under them
with the date and commit `git blame` gives its first line: the work's own are
the ones with no commit yet or with a commit on this branch. Rather than
writing "none" from memory, run it.

A comment says what the code cannot: a reason, an invariant, a contract,
a hazard. It is correct, necessary, clear and concise, describes the code
as it is rather than its history, and gives way to clearer code where it
only makes up for unclear code. [`.claude/skills/comments/SKILL.md`] holds
the standard, with examples, and how to audit a part of the tree against it.

Tests belong in `*_test.tl` files as top-level `local function test_*` functions.
Do not add a top-level `return` to test files. Prefer small regression cases that
fail for the reported bug over assertions that pin incidental implementation.
Documentation-only edits do not require rebuilding or running tests.

## C

The core's own C builds under `own_warnings` in `build.zig`, as errors. Fix a
warning rather than silencing it; `-Wcast-qual` is left out only because the
calls the core makes take const-dropping casts by design. `bin/zig build
analyze` runs the static analyzer `bin/zig cc` carries over the same files, and
`bin/zig build sanitized` runs it too, so CI fails on a finding. `cosmic fix`
compiles each C file to clang's syntax tree and holds it to the items marked
(checked) below; a case a rule cannot see past goes in `exempt` in
[`build/c/rules.tl`] with its reason. When reviewing C, check for:

- A value pushed above an open `luaL_Buffer`: only `luaL_addvalue` may find
  one there. Every other buffer call needs the buffer's own slot on top.
  (checked)
- A pointer into a Lua string kept after the value leaves the stack. Copy it
  first. (checked, for a string counted from the top)
- A resource held in a C local across a Lua call that can allocate: any call
  can raise on memory. Hold it in a guard ([`core/guard.h`]), or, for one the
  caller is to own, acquire it after everything that allocates. (checked)
- An integer argument cast to `int`. Use `cosmic_checkint` or
  `cosmic_optint` ([`core/check.h`]), which refuse a value that does not fit.
  (checked)
- A binding's failure in another shape than its contract's: a degenerate
  argument raises, and a runtime failure returns `nil` or `false`, a message,
  and an errno ([`core/fail.h`]): `false` through `cosmic_fail_effect` for one
  declared `boolean`, `nil` through `cosmic_fail` for one declared a value,
  never `boolean|nil`. (checked: what a binding returns, against its
  declaration in [`core/syscalls.h`])
- A header's function returning `int` that only ever answers 0, 1 or a
  truth: it is a pass or a fail, so it returns `bool`, true for success. One
  forwarding a library's status stays `int`, its contract said where it is
  declared. (checked)
- A function of external linkage returning the same constant on every path:
  it returns `void`. (checked)
- A binding that answers `true` and nothing else on every path: it answers
  nothing. (checked)
- A function a header declares that only its own file refers to: it is
  `static` there and out of the header. (checked, only when every C file is
  checked at once, as CI's `fix --check .` does)
- A function that never returns without `_Noreturn`.
- A new C function without a test that enters it: a whole run fails for one
  unless [`build/c_functions.tl`] exempts it with the reason no test can.
  Allocation-failure paths are walked on the checked core in
  [`core/allocation_test.tl`].

## Bootstrap

[`bin/zig`], [`bin/vendor`] and [`bin/verify-codesign`] each run
their Teal ([`build/zig.tl`], ...) through [`bin/cosmic-bootstrap`], on the cosmic
release [`ci/cosmic-driver.pin`] names, which it fetches once and caches by
digest. `COSMIC_BOOTSTRAP=<path>` makes [`bin/cosmic-bootstrap`] answer another
cosmic instead, such as a tree-built `o/bin/cosmic`, for all of them and for
CI's driver step alike.

A change that moves ci/cosmic-driver.pin also takes up every `TODO:` the new release
unblocks: `o/bin/cosmic todos '"cosmic-driver.pin"'` lists them.

[`.claude/skills/comments/SKILL.md`]: .claude/skills/comments/SKILL.md
[`.github/scripts/place-tree.sh`]: .github/scripts/place-tree.sh
[`bin/cosmic-bootstrap`]: bin/cosmic-bootstrap
[`bin/vendor`]: bin/vendor
[`bin/verify-codesign`]: bin/verify-codesign
[`bin/zig`]: bin/zig
[`build.confine`]: build/confine.tl
[`build.fuzz`]: build/fuzz/init.tl
[`build/artifact.tl`]: build/artifact.tl
[`build/c/layout.tl`]: build/c/layout.tl
[`build/c/rules.tl`]: build/c/rules.tl
[`build/c_functions.tl`]: build/c_functions.tl
[`build/contracts.tl`]: build/contracts.tl
[`build/declared_key.tl`]: build/declared_key.tl
[`build/flow.tl`]: build/flow.tl
[`build/harness_epoch.tl`]: build/harness_epoch.tl
[`build/harness_epoch_test.tl`]: build/harness_epoch_test.tl
[`build/launcher.tl`]: build/launcher.tl
[`build/reboot.tl`]: build/reboot.tl
[`build/rebuild_lock.tl`]: build/rebuild_lock.tl
[`build/sandboxed_verdicts_test.tl`]: build/sandboxed_verdicts_test.tl
[`build/shared_compiles.tl`]: build/shared_compiles.tl
[`build/test_policy.tl`]: build/test_policy.tl
[`build/test_sandbox.tl`]: build/test_sandbox.tl
[`build/test_sandbox_probe.tl`]: build/test_sandbox_probe.tl
[`build/test_worker.tl`]: build/test_worker.tl
[`build/tree_checks.tl`]: build/tree_checks.tl
[`build/workflows_test.tl`]: build/workflows_test.tl
[`build/zig.tl`]: build/zig.tl
[`ci/cosmic-driver.pin`]: ci/cosmic-driver.pin
[`ci/run-local`]: ci/run-local
[`core/allocation_test.tl`]: core/allocation_test.tl
[`core/check.h`]: core/check.h
[`core/fail.h`]: core/fail.h
[`core/guard.h`]: core/guard.h
[`core/syscalls.h`]: core/syscalls.h
[`cosmic.sandbox`]: cosmic/sandbox.tl
[`doc/roadmap.md`]: doc/roadmap.md
[`Fuzz.label`]: build/fuzz/init.tl
[`Fuzz.more`]: build/fuzz/init.tl
[`harness_epoch.library`]: build/harness_epoch.tl
[`Store.bytecode`]: cosmic/store.tl
[`Store.databases()`]: cosmic/store.tl
[`Store.meta`]: cosmic/store.tl
[`Store.source`]: cosmic/store.tl
[`Test.needs`]: cosmic/test.tl
[`Test.policy`]: cosmic/test.tl
[`Test.skip`]: cosmic/test.tl
