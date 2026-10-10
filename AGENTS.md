# Iterating on cosmic

The operating guide every agent session loads. Detail lives in
[`doc/testing.md`] (tests), [`doc/writing.md`] (prose and comments) and
[`doc/contributing.md`] (the pull request).

## ground rules

- Use [`bin/zig`], the repository's pinned compiler, never a system Zig.
- Use a separate worktree for each independent fix. Check
  `git status --short` before building or switching branches: untracked
  test files can enter a build.
- Keep `vendor/` unedited. Express a vendor change as a record under
  `patch/`. [`bin/vendor`] refetches a tree from its PIN and keeps only
  what the build reads.
- Workflows and the local actions under `.github/actions/` are YAML in
  flow style, in the subset [`build/workflows_test.tl`] holds them to,
  laid out as `bin/cosmic fix` writes them ([`build/flow.tl`]). After a
  change under `.github/`, run `bin/cosmic fix` and
  `bin/cosmic test build/workflows_test.tl`. A step's script longer than
  a line or two lives under `.github/scripts/`. A job gets the pinned CI
  driver on its PATH with `uses: ./.github/actions/cosmic-driver`.
- Run the tool only as [`bin/cosmic`], from any directory and with the
  checkout at any path. It asks [`build/paths.tl`] where the build
  directory is, passes its arguments and exit status through, and runs
  `bin/zig build boot` first where there is no tool yet (with
  `COSMIC_AUTO_BOOT=0` it refuses and exits 3). Never run the tool by its
  path in the build directory.

## the build directory

Every build of a project (databases, rebuild lock, cores, executables)
goes in its build directory, outside the checkout:
`$XDG_CACHE_HOME/cosmic/trees/<key>` (`~/.cache/cosmic/trees/<key>`),
`<key>` the SHA-256 of the project root's canonical path. Each worktree
has its own. `COSMIC_BUILD_HOME=/absolute/path` moves the `<key>`
directories; [`build/paths.tl`] holds the rules and what it refuses.
Nothing falls back to `o/`: a checkout's `o/` from an older tool is stale,
never read, and may be deleted. Delete a worktree's build directory when
you delete the worktree. zig's caches and the Teal compile cache
(`COSMIC_BUILD_CACHE` names another file, `0` none) are shared by every
checkout, so a fresh worktree compiles little.

## the loop

1. Run `bin/zig build boot` in a fresh worktree. It builds the required
   cores and stages the tree into the build directory's `build.db`, the
   working database every later build reads. Copying an existing cosmic
   executable is not a substitute.
2. Edit source and tests, then run `bin/cosmic fix <changed-paths>`.
   `fix` checks syntax and tree equivalence and builds the tree as
   `cosmic test` does, so a type error or a broken contract fails it,
   saying why. A C path is held to [`build/c/rules.tl`] (see C, below).
   The checks only the whole tree can answer ([`build/tree_checks.tl`])
   run in `bin/cosmic fix --check .`, as CI runs it, not in a `fix` of
   some paths: run it before pushing a change to what they read. It also
   refuses a tree that does not build.
3. A tool older than the tree rebuilds itself and re-enters the command
   the moment it notices, so `bin/cosmic test` after an edit is enough. An
   edit to Teal rebuilds the database. A change to the core's C under
   `core/`, to `build.zig`, the launcher or artifact format, or to a
   vendored library's pin or patches runs `bin/zig build boot` first. With
   `COSMIC_AUTO_BOOT=0` the tool refuses instead and exits 3 (CI sets it).
   A boot that fails stops the command: check its exit status, do not pipe
   it away. Only the tree's own tool rebuilds or boots; another cosmic
   (a release) run in a stale tree refuses and exits 3.
4. Run `timeout 30 bin/cosmic test`.

One `cosmic test` runs per checkout at a time: it holds the build
directory's `rebuild.lock` ([`build/rebuild_lock.tl`]) for its whole run,
as do a rebuild, a boot and a write of `cosmic.db`. A run that finds it
held says who holds it and waits. So `cosmic docs`, `uses` or `foo.tl`
after an edit waits for a whole test run, and a `timeout` around
`cosmic test` counts the wait. A `cosmic test` that a test starts must run
in a tree of its own, or it waits on its starter until the test times out.

Look things up with the tool, not grep: `bin/cosmic docs <symbol or
words>` (signature, doc comment, use count; or search by what a function
does), `bin/cosmic uses <symbol>` (every `file:line`), `bin/cosmic db`
(the databases by path, and how the last builds went), `bin/cosmic sql
[--build|--store|--db <path>] '<statement>'` (one read-only query, no
build), `bin/cosmic todos <paths>`.

## tests

[`doc/testing.md`] holds the rules. The ones an agent needs most:

- A test is a top-level `local function test_*` in a `*_test.tl` file,
  with no top-level `return`. Prefer small regression cases that fail for
  the reported bug over assertions that pin incidental implementation.
- A test whose declared inputs, closure, core, harness epoch, timeout and
  host are unchanged since it last passed is not run again, and checkouts
  share passing verdicts. `--all` runs everything.
- A test declares what it reads in a top-level `Test.policy { ... }`
  ([`Test.policy`]). Sandboxed (the Linux default), an undeclared read
  finds nothing and the test fails with its own error: declare it. A test
  must not depend on the tree's path, file times, inodes, owners or the
  network beyond declared loopback.
- A test that cannot check its subject on this host declares `requires`
  ([`build/host_names.tl`] holds the names) or calls `Test.skip(reason)`;
  it never returns early. A new `requires` name also goes in each leg that
  promises it in [`ci/cosmic_ci/capabilities.tl`]. A test must call
  `assert`, or its pass is listed as `NO ASSERT` and keeps no verdict.
- Treat a timeout as a failure to investigate; do not silently raise the
  limit. A parser of untrusted bytes gets a `*_fuzz_test.tl` driving
  [`build.fuzz`]'s `run`. A change to a harness module
  ([`build/harness_epoch.tl`] lists them) needs the epoch handling in the
  last section of [`doc/testing.md`].

## ci

`ci/` is a tree of its own with its own build directory. After editing
it, run `../bin/cosmic fix --check` from `ci/`. Its `fixtures/*_test.tl`
run only under the CI driver: before pushing a change to the launcher,
startup, the artifact format or a fixture, run [`ci/run-local`] (a few
minutes), then `ci/run-local fixtures` for edited fixtures. Invoked as
root, it runs the driver as an unprivileged user (`COSMIC_CI_LOCAL_USER`),
as CI's runners are. The launcher fixture's core is a stand-in that checks
nothing: a case about the real core belongs in `runtime_test.tl`.

## TODO comments

Leave a `TODO:` the moment one is due, not at the end of the work. One is
due when a change settles for less than the right fix because something
is missing (an API, a binding, a module, a patch the bootstrap pin lacks):
put it where the better fix would go and name what it waits on ("once
cosmic.sys carries ftruncate"), so the workaround can be found and undone.
One is also due for a gap met along the way and left alone: say what is
wrong and what the fix would be.

A `TODO:` whose fix cannot be made yet still goes in now, naming the unmet
dependency ("once #2011 merges"). One that waits on the bootstrap pin
says "once ci/cosmic-driver.pin names ...", word for word, so the change
that moves the pin finds it. In a doc comment, a `TODO:` is a separate
`--` comment set off from the doc by a blank line.

A feature no caller needs yet is no `TODO:`: it goes in
[`doc/roadmap.md`]. A limit decided for good is a plain comment with the
reason it stays. A gap named anywhere else (a reply, a summary, a "known
limits" line in a PR description) is a `TODO:` not yet written: write it
in the code first.

When the work is done, list every `TODO:` it added, with `file:line` and
what it waits on, in the summary and the PR description. Take the list
from `bin/cosmic todos <changed-paths>`: the work's own are those with no
commit yet or a commit on this branch. Do not write "none" from memory.

## comments

A comment says what the code cannot: a reason, an invariant, a contract, a
hazard. [`doc/writing.md`] holds the standard, with examples and how to
audit a part of the tree against it. Where a comment only makes up for
unclear code, prefer clearer code.

## C

The core's own C builds under `own_warnings` in `build.zig`, as errors.
Fix a warning rather than silencing it; `-Wcast-qual` is left out only
because the core's calls take const-dropping casts by design. `bin/zig
build analyze` runs the static analyzer over the same files, and `bin/zig
build sanitized` runs it too, so CI fails on a finding. `cosmic fix` holds
each C file to the items marked (checked) below; a case a rule cannot see
past goes in `exempt` in [`build/c/rules.tl`] with its reason. When
reviewing C, check for:

- A value pushed above an open `luaL_Buffer`: only `luaL_addvalue` may
  find one there. Every other buffer call needs the buffer's own slot on
  top. (checked)
- A pointer into a Lua string kept after the value leaves the stack. Copy
  it first. (checked, for a string counted from the top)
- A resource held in a C local across a Lua call that can allocate: any
  call can raise on memory. Hold it in a guard ([`core/guard.h`]), or, for
  one the caller is to own, acquire it after everything that allocates.
  (checked)
- An integer argument cast to `int`. Use `cosmic_checkint` or
  `cosmic_optint` ([`core/check.h`]), which refuse a value that does not
  fit. (checked)
- A binding's failure in another shape than its contract's: a degenerate
  argument raises, and a runtime failure returns `nil` or `false`, a
  message, and an errno ([`core/fail.h`]): `false` through
  `cosmic_fail_effect` for one declared `boolean`, `nil` through
  `cosmic_fail` for one declared a value, never `boolean|nil`. (checked:
  what a binding returns, against its declaration in
  [`core/syscalls.h`])
- A header's function returning `int` that only ever answers 0, 1 or a
  truth: it is a pass or a fail, so it returns `bool`, true for success.
  One forwarding a library's status stays `int`, its contract said where
  it is declared. (checked)
- A function of external linkage returning the same constant on every
  path: it returns `void`. (checked)
- A binding that answers `true` and nothing else on every path: it answers
  nothing. (checked)
- A function a header declares that only its own file refers to: it is
  `static` there and out of the header. (checked, only when every C file
  is checked at once, as CI's `fix --check .` does)
- A function that never returns without `_Noreturn`.
- A new C function without a test that enters it: a whole run fails for
  one unless [`build/c_functions.tl`] exempts it with the reason no test
  can. Allocation-failure paths are walked on the checked core in
  [`core/allocation_test.tl`].

## Bootstrap

[`bin/zig`], [`bin/vendor`] and [`bin/verify-codesign`] each run their
Teal ([`build/zig.tl`], ...) through [`bin/cosmic-bootstrap`], on the
cosmic release [`ci/cosmic-driver.pin`] names, fetched once and cached by
digest. [`bin/cosmic`] asks [`build/paths.tl`] for the build directory the
same way. So what those files run is held to what that release has.
`COSMIC_BOOTSTRAP=<path>` makes [`bin/cosmic-bootstrap`] answer another
cosmic instead, such as the tree's own tool (by its path in the build
directory; [`bin/cosmic`] itself is refused), for all of them and for CI's
driver step alike.

A change that moves [`ci/cosmic-driver.pin`] also takes up every `TODO:` the
new release unblocks: `bin/cosmic todos '"cosmic-driver.pin"'` lists them
([`doc/contributing.md`] has the procedure).

[`bin/cosmic-bootstrap`]: bin/cosmic-bootstrap
[`bin/cosmic`]: bin/cosmic
[`bin/vendor`]: bin/vendor
[`bin/verify-codesign`]: bin/verify-codesign
[`bin/zig`]: bin/zig
[`build.fuzz`]: build/fuzz/init.tl
[`build/c/rules.tl`]: build/c/rules.tl
[`build/c_functions.tl`]: build/c_functions.tl
[`build/flow.tl`]: build/flow.tl
[`build/harness_epoch.tl`]: build/harness_epoch.tl
[`build/host_names.tl`]: build/host_names.tl
[`build/paths.tl`]: build/paths.tl
[`build/rebuild_lock.tl`]: build/rebuild_lock.tl
[`build/tree_checks.tl`]: build/tree_checks.tl
[`build/workflows_test.tl`]: build/workflows_test.tl
[`build/zig.tl`]: build/zig.tl
[`ci/cosmic-driver.pin`]: ci/cosmic-driver.pin
[`ci/cosmic_ci/capabilities.tl`]: ci/cosmic_ci/capabilities.tl
[`ci/run-local`]: ci/run-local
[`core/allocation_test.tl`]: core/allocation_test.tl
[`core/check.h`]: core/check.h
[`core/fail.h`]: core/fail.h
[`core/guard.h`]: core/guard.h
[`core/syscalls.h`]: core/syscalls.h
[`doc/contributing.md`]: doc/contributing.md
[`doc/roadmap.md`]: doc/roadmap.md
[`doc/testing.md`]: doc/testing.md
[`doc/writing.md`]: doc/writing.md
[`Test.policy`]: cosmic/test.tl
