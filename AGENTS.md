# Iterating on cosmic

The operating guide every agent session loads, cosmic agent's too, on every
request: keep it short. Detail lives in [`doc/contributing.md`] (the pull
request, the checks a change needs, the pin), [`doc/testing.md`] (tests),
[`doc/writing.md`] (prose, comments, TODOs), [`doc/c.md`] (the core's C),
[`doc/design.md`] (the build) and [`doc/decisions/`] (decisions, including
[`doc/decisions/0001-friction-triage.md`]).

## ground rules

- Use [`bin/zig`], the pinned compiler, never a system Zig.
- Use a worktree for each independent fix. Check `git status --short`
  before building or switching branches: untracked test files can enter a
  build.
- Keep `vendor/` unedited: a vendor change is a record under `patch/`.
  [`bin/vendor`] refetches a tree from its PIN.
- Workflows and `.github/actions/` are flow-style YAML ([`build/flow.tl`]).
  After a change under `.github/`, run `bin/cosmic fix` and
  `bin/cosmic test build/workflows_test.tl`. A script longer than a line or
  two lives under `.github/scripts/`; a job gets the pinned CI driver with
  `uses: ./.github/actions/cosmic-driver`.
- `ci/` is a tree of its own: after editing it, run `../bin/cosmic fix
  --check` and `../bin/cosmic-bootstrap fix --check .` (the pinned
  release's older checker, COSMIC_BOOTSTRAP unset) from `ci/`.
- Run the tool only as [`bin/cosmic`], from any directory; never by its
  path in the build directory. Where there is no tool, it boots first
  (`COSMIC_AUTO_BOOT=0`, which CI sets, refuses, exit 3). A moved or copied checkout is
  booted again.

## the build directory

Each worktree builds into its own directory outside the checkout
([`build/paths.tl`]; `COSMIC_BUILD_HOME=/absolute/path` moves it). A
checkout's `o/` is stale and never read. Delete a worktree's build
directory with the worktree.

## the loop

1. `bin/zig build boot` in a fresh worktree (2 to 6 minutes cold). Before a
   change to the artifact format, the launcher or `cosmic build`, boot
   with `-Dboot-cores=all` ([`doc/contributing.md`]).
2. Edit, then `bin/cosmic fix <changed-paths>`: it checks and builds as
   `cosmic test` does and rewrites the layout of the files it is given, so
   commit what it wrote. Before pushing a change to what the tree checks
   read, run `bin/cosmic fix --check .`, as CI does: only the whole tree
   runs [`build/tree_checks/`].
3. A tool older than the tree rebuilds itself when a verb runs (`fix`,
   `test`, `docs` and the rest; not `--version`, `-e` or `-`, which note
   on stderr that the tool is older than its checkout). A change to the core's C, `build.zig`, the launcher, the
   artifact format or a vendored pin or patch boots first. A failed boot
   stops the command: check its exit status, do not pipe it away.
4. Test what you changed: `bin/cosmic test <their *_test.tl files>`.
   Before pushing, the full suite: `timeout 2700 bin/cosmic test` (about 8
   minutes fresh; [`doc/testing.md`] has timings).
5. Commit, push and open the pull request as [`doc/contributing.md`] says.

One `cosmic test`, rebuild or boot runs per checkout at a time; another
waits, and a `timeout` counts the wait. Read-only verbs (`docs`, `uses`,
`db`, `sql`, `todos`, `bom`, `help`, `lsp`) never wait: where the lock is
held, they read the last build.

Look things up with the tool, not grep: `bin/cosmic docs <symbol or
words>`, `uses <symbol>`, `db`, `sql '<statement>'`, `todos <paths>`.

## held findings

Each checker finding not yet removed is held where it occurs by a trailing
marker such as `-- checked: map_field` ([`doc/contributing.md`], "markers
only fall"). A finding with no marker fails, and a new marker is refused.
`bin/cosmic fix .` removes a stale marker: commit what it wrote. A guide's
code block and `ci/testdata` hold no markers, so a finding there fails.

## tests

[`doc/testing.md`] holds the rules. The ones an agent needs most:

- A test is a top-level `local function test_*` in a `*_test.tl` file.
  Prefer a small case that fails for the bug over pinning incidental
  behavior.
- A test declares what it reads in `Test.policy { ... }` ([`Test.policy`]).
- A test that cannot check its subject here declares `requires` or calls
  `Test.skip(reason)`; it never returns early.
- A test asserts, or is listed as `NO ASSERT`.
- A timeout is a failure to investigate, not a limit to raise.

## comments and TODOs

Write a `TODO:` the moment one is due (a lesser fix, or a gap left alone),
naming what it waits on. One that waits on the pin says "once
ci/cosmic-driver.pin names ...", word for word. List the TODOs the work
adds in the summary and the PR description from `bin/cosmic todos <changed-paths>`. A
comment says what the code cannot: a reason, an invariant, a hazard
([`doc/writing.md`]).

## C

The core's C builds with warnings as errors, held to the (checked) items
of [`doc/c.md`]. Read it before writing C.

## bootstrap

[`bin/zig`], [`bin/vendor`] and [`bin/verify-codesign`] run on the release
[`ci/cosmic-driver.pin`] names, not on the tree, so a change reaches them
only once the pin moves (`COSMIC_BOOTSTRAP=<path>` runs another cosmic). A
change that moves the pin takes up the TODOs it unblocks: `bin/cosmic todos
'"cosmic-driver.pin"'` ([`doc/contributing.md`]).

[`bin/cosmic`]: bin/cosmic
[`bin/vendor`]: bin/vendor
[`bin/verify-codesign`]: bin/verify-codesign
[`bin/zig`]: bin/zig
[`build/flow.tl`]: build/flow.tl
[`build/paths.tl`]: build/paths.tl
[`build/tree_checks/`]: build/tree_checks/init.tl
[`ci/cosmic-driver.pin`]: ci/cosmic-driver.pin
[`doc/c.md`]: doc/c.md
[`doc/contributing.md`]: doc/contributing.md
[`doc/decisions/0001-friction-triage.md`]: doc/decisions/0001-friction-triage.md
[`doc/decisions/`]: doc/decisions/README.md
[`doc/design.md`]: doc/design.md
[`doc/testing.md`]: doc/testing.md
[`doc/writing.md`]: doc/writing.md
[`Test.policy`]: cosmic/test.tl
