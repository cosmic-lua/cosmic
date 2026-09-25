# Iterating on cosmic

- Use `bin/zig`, the repository's pinned compiler, rather than a system Zig.
- Use a separate worktree for each independent fix. Check `git status --short`
  before building or switching branches: untracked test files can enter a build.
- Keep `vendor/` unedited; express vendor changes as records under `patch/`.
  `bin/vendor` refetches a tree from its PIN, keeping only what the build reads.
  Generated output under `o/` must not be committed.
- Run `bin/actionlint` (the pinned actionlint, over `.github/workflows/`)
  before pushing a change under `.github/`.

## Build, format, test

1. Run `bin/zig build boot` in a fresh worktree. This builds the required cores
   and stages the tree into `o/build.db`, the working database every later
   build reads; copying an existing cosmic executable alone is insufficient to
   test a fresh checkout. zig's caches are shared by every checkout
   (`zig-project` and `zig-global` under `~/.cache/cosmic`, see
   `build/zig.tl`), so a fresh worktree compiles only the core's own C;
   delete them to reclaim the space. `o/bin/cosmic db` says what both
   databases under `o/` hold and how the last few builds went;
   `o/bin/cosmic sql [--build|--store|--db <path>] '<statement>'` runs one
   read-only query against one of them, with no script and no build;
   `o/bin/cosmic docs <symbol>`
   shows a symbol's signature, doc comment and use count, and
   `o/bin/cosmic uses <symbol>` lists every `file:line` that refers to it.
2. Edit source and tests, then run `o/bin/cosmic fix <changed-paths>`.
   `fix` checks syntax and tree equivalence; compilation (`cosmic test`, a
   boot) checks types and `build/contracts.tl`'s rules, which `fix` does
   not report. A C
   path is written back in Lua's own layout (`build/c/layout.tl`) and
   checked against the rules in `build/c/rules.tl` (see C, below).
3. A tool older than the tree rebuilds itself and re-enters the command the
   moment it notices, so `o/bin/cosmic test` after an edit is enough. An
   edit to Teal rebuilds its database; a change to the core's C under
   `core/`, to `build.zig` or `build/launcher.tl`, or to a vendored library's
   pin or patches runs `bin/zig build boot` first, its output on stderr.
   `COSMIC_AUTO_BOOT=0` makes the tool refuse instead, exiting 3 (CI's
   driver sets it). A boot that fails stops the command: check its exit
   status rather than piping it away. Only the tree's own tool (under
   `o/`) rebuilds or boots; another cosmic run in the tree when it is
   stale -- a release, the bootstrap cache's -- refuses, exiting 3.
4. Run `timeout 30 o/bin/cosmic test`. A test whose verdict still stands -- same
   module key, same contents for every file opened, and same stat and directory
   read answers under the root -- is not run again, so a run after a small edit
   takes seconds. A run after a boot, or on a fresh `o/`, runs everything.
   Environment variables a test reads are part of its key; a test that spawns
   a process or reads outside the tree beyond its own temporary directories
   is never answered from a verdict.
   Treat an actual
   timeout as a failure to investigate, and report it separately from an
   assertion failure. Do not silently raise the limit; inspect elapsed time and
   the slow work first. To benchmark full test execution, delete only the rows
   from the `verdicts` table in `o/build.db`; preserve the staged database and
   report the `ran` and `stood` counts with the elapsed time.

`ci/` is a tree of its own, with its own `o/`. After editing it, run
`../o/bin/cosmic fix --check` from `ci/`; that also builds and type-checks it.
Its `fixtures/*_test.tl` run only under the CI driver, which builds every
target: run `ci/run-local` (a few minutes) before pushing a change that
touches the launcher, startup, the artifact format, or a fixture, and
`ci/run-local fixtures` to re-run edited fixtures after that. CI's runners are
unprivileged; invoked as root, run-local runs the driver as an unprivileged
user (`COSMIC_CI_LOCAL_USER`, default `nobody`). The launcher fixture's core
is a stand-in payload that checks nothing; a case about what the real core
does (its digest, its startup errors) belongs in `runtime_test.tl`.

A parser that reads untrusted bytes gets a `*_fuzz_test.tl` beside it,
driving `build.fuzz`'s `run`: a generator draws each input from a seeded
source and a check must hold for all of them. `FUZZ_SEED` and `FUZZ_ITERS`
(64 by default) choose the inputs, a failure is shrunk and kept in the test's
directory, and `FUZZ_SEED=<seed> FUZZ_ITERS=<iteration>` reproduces it. CI's
runs, which gate a merge, set `FUZZ_ITERS=0` and draw nothing; `fuzz.yml`
fuzzes every property each night on the checked core with a seed of its own,
and opens an issue (or comments on the open one) when it fails. Once a failure is fixed, keep its input in
`testdata/fuzz/<property>/` as the report says: `run` checks that corpus
before drawing anything. A check calls `Fuzz.label` for what an input reached
(opened, read a body); a property `requires` the labels it exists to exercise,
so a generator whose inputs all stop at the first refusal fails rather than
passing while it checks nothing (not held when `FUZZ_ITERS` is below 64).

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
comment back until it lands. A gap named anywhere else -- a reply, a
summary, a "known limits" line in a PR description -- is a `TODO:` not yet
written: write it in the code before naming it there.

When the work is done, list every `TODO:` it added, with its `file:line` and
what it waits on, in the summary and the PR description. Take the list from
`o/bin/cosmic todos <changed-paths>`, which lists every `TODO:` under them
with the date and commit `git blame` gives its first line: the work's own are
the ones with no commit yet or with a commit on this branch. Rather than
writing "none" from memory, run it.

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
`build/c/rules.tl` with its reason. When reviewing C, check for:

- A value pushed above an open `luaL_Buffer`: only `luaL_addvalue` may find
  one there. Every other buffer call needs the buffer's own slot on top.
  (checked)
- A pointer into a Lua string kept after the value leaves the stack. Copy it
  first. (checked, for a string counted from the top)
- A resource held in a C local across a Lua call that can allocate: any call
  can raise on memory. Hold it in a guard (`core/guard.h`), or, for one the
  caller is to own, acquire it after everything that allocates. (checked)
- An integer argument cast to `int`. Use `cosmic_checkint` or
  `cosmic_optint` (`core/check.h`), which refuse a value that does not fit.
  (checked)
- A binding's failure in another shape than its contract's: a degenerate
  argument raises, and a runtime failure returns `nil` or `false`, a message,
  and an errno (`core/fail.h`): `false` through `cosmic_fail_effect` for one
  declared `boolean`, `nil` through `cosmic_fail` for one declared a value,
  never `boolean|nil`. (checked: what a binding returns, against its
  declaration in `core/syscalls.h`)
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
  unless `build/c_functions.tl` exempts it with the reason no test can.
  Allocation-failure paths are walked on the checked core in
  `core/allocation_test.tl`.

## Bootstrap

`bin/zig` and `bin/vendor` run Teal (`build/zig.tl`, `build/vendor.tl`) on
the cosmic release `ci/cosmic-driver.pin` names, which `bin/cosmic-bootstrap`
fetches once and caches by digest. `COSMIC_BOOTSTRAP=<path>` runs another
cosmic instead, such as a tree-built `o/bin/cosmic`.
