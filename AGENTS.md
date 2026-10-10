# Iterating on cosmic

The operating guide every agent session loads. Detail lives in
[`doc/testing.md`] (tests), [`doc/writing.md`] (prose, comments, TODOs),
[`doc/c.md`] (the core's C) and [`doc/contributing.md`] (the pull request).

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
- `ci/` is a tree of its own: after editing it, run `../bin/cosmic fix
  --check` from `ci/`. [`doc/contributing.md`] says when to run
  [`ci/run-local`].
- Run the tool only as [`bin/cosmic`], from any directory and with the
  checkout at any path; never by its path in the build directory. It
  passes its arguments and exit status through, and runs
  `bin/zig build boot` first where there is no tool yet (with
  `COSMIC_AUTO_BOOT=0` it refuses and exits 3).

## the build directory

Every build of a project (databases, rebuild lock, cores, executables)
goes in its build directory, outside the checkout, one per worktree.
[`build/paths.tl`] names it and holds the rules and what it refuses;
`COSMIC_BUILD_HOME=/absolute/path` moves it. Nothing falls back to `o/`: a
checkout's `o/` is stale, never read, and may be deleted. Delete a
worktree's build directory when you delete the worktree.

## the loop

1. Run `bin/zig build boot` in a fresh worktree. It builds the cores and
   stages the tree into the build directory's `build.db`, the working
   database every later build reads. Copying an existing cosmic
   executable is not a substitute.
2. Edit source and tests, then run `bin/cosmic fix <changed-paths>`. It
   checks syntax and builds the tree as `cosmic test` does, so a type
   error or a broken contract fails it, saying why. It writes a C file
   back in Lua's own layout ([`doc/c.md`]). The checks only the whole tree
   can answer ([`build/tree_checks.tl`]) run in `bin/cosmic fix --check .`,
   as CI runs it, which also refuses a tree that does not build: run it
   before pushing a change to what they read.
3. A tool older than the tree rebuilds itself and re-enters the command
   the moment it notices, so `bin/cosmic test` after an edit is enough. A
   change to the core's C, `build.zig`, the launcher or artifact format,
   or a vendored library's pin or patches runs `bin/zig build boot` first.
   With `COSMIC_AUTO_BOOT=0` the tool refuses instead and exits 3 (CI sets
   it). A boot that fails stops the command: check its exit status, do
   not pipe it away.
4. Run `timeout 30 bin/cosmic test`.
5. Commit, push and open the pull request as [`doc/contributing.md`]
   says.

One `cosmic test` runs per checkout at a time, holding the build
directory's `rebuild.lock` ([`build/rebuild_lock.tl`]), as do a rebuild
and a boot. A run that finds it held says who holds it and waits, so
`cosmic docs` or `uses` after an edit waits for a whole test run, and a
`timeout` counts the wait.

Look things up with the tool, not grep: `bin/cosmic docs <symbol or
words>`, `uses <symbol>`, `db`, `sql '<statement>'`, `todos <paths>`.

## tests

[`doc/testing.md`] holds the rules. The ones an agent needs most:

- A test is a top-level `local function test_*` in a `*_test.tl` file,
  with no top-level `return`. Prefer small regression cases that fail for
  the reported bug over assertions that pin incidental implementation.
- A test declares what it reads in a top-level `Test.policy { ... }`
  ([`Test.policy`]); an undeclared read fails sandboxed.
- A test that cannot check its subject on this host declares `requires`
  or calls `Test.skip(reason)`, never returns early.
- A test calls `assert`, or its pass is listed as `NO ASSERT`.
- A timeout is a failure to investigate; do not silently raise the limit.
- A change to a harness module ([`build/harness_epoch.tl`] lists them)
  needs the epoch handling in [`doc/testing.md`].

## comments and TODOs

Leave a `TODO:` the moment one is due, not at the end of the work: when a
change settles for less than the right fix, or a gap is met and left
alone. Name what it waits on. One that waits on the bootstrap pin says
"once ci/cosmic-driver.pin names ...", word for word. List every `TODO:`
the work adds in the summary and the PR description, from `bin/cosmic
todos <changed-paths>`, never from memory. A comment says what the code
cannot (a reason, an invariant, a contract, a hazard). [`doc/writing.md`]
holds the standard for both, the TODO rules in
[its own section](doc/writing.md#todo-comments).

## C

The core's own C builds with warnings as errors, and `cosmic fix` holds it
to the items marked (checked) in [`doc/c.md`]. Read that before writing C.

## bootstrap

[`bin/zig`], [`bin/vendor`] and [`bin/verify-codesign`] run through
[`bin/cosmic-bootstrap`] on the cosmic release [`ci/cosmic-driver.pin`]
names, not on the tree, so what a change adds reaches them only once the
pin moves. `COSMIC_BOOTSTRAP=<path>` makes them run another cosmic
instead, such as the tree's own tool by its path in the build directory
([`bin/cosmic`] itself is refused). A change that moves the pin also takes
up every `TODO:` the new release unblocks: `bin/cosmic todos
'"cosmic-driver.pin"'` lists them, and [`doc/contributing.md`] has the
procedure.

[`bin/cosmic-bootstrap`]: bin/cosmic-bootstrap
[`bin/cosmic`]: bin/cosmic
[`bin/vendor`]: bin/vendor
[`bin/verify-codesign`]: bin/verify-codesign
[`bin/zig`]: bin/zig
[`build/flow.tl`]: build/flow.tl
[`build/harness_epoch.tl`]: build/harness_epoch.tl
[`build/paths.tl`]: build/paths.tl
[`build/rebuild_lock.tl`]: build/rebuild_lock.tl
[`build/tree_checks.tl`]: build/tree_checks.tl
[`build/workflows_test.tl`]: build/workflows_test.tl
[`ci/cosmic-driver.pin`]: ci/cosmic-driver.pin
[`ci/run-local`]: ci/run-local
[`doc/c.md`]: doc/c.md
[`doc/contributing.md`]: doc/contributing.md
[`doc/testing.md`]: doc/testing.md
[`doc/writing.md`]: doc/writing.md
[`Test.policy`]: cosmic/test.tl
