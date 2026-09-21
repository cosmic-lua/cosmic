# Iterating on cosmic

- Use `bin/zig`, the repository's pinned compiler, rather than a system Zig.
- Use a separate worktree for each independent fix. Check `git status --short`
  before building or switching branches: untracked test files can enter a build.
- Keep `vendor/` pristine; express vendor changes as records under `patch/`.
  Generated output under `o/` must not be committed.

## Build, format, test

1. Run `bin/zig build boot` in a fresh worktree. This builds the required cores
   and stages the tree into `o/build.db`, the working database every later
   build reads; copying an existing cosmic executable alone is insufficient to
   test a fresh checkout. `o/bin/cosmic db` says what both databases under
   `o/` hold and how the last few builds went; `o/bin/cosmic docs <symbol>`
   shows a symbol's signature, doc comment and use count, and
   `o/bin/cosmic uses <symbol>` lists every `file:line` that refers to it.
2. Edit source and tests, then run `o/bin/cosmic fix <changed-tl-paths>`.
   `fix` checks syntax and tree equivalence; compilation checks types.
3. A tool older than the tree rebuilds itself and re-enters the command the
   moment it notices, so an edit to Teal needs no boot: `o/bin/cosmic test`
   after the edit is enough. A change under `core/`, to `build.zig` or
   `build/launcher.tl`, or to a vendored library's pin or patches still needs
   `bin/zig build boot`, and the tool says so by name.
4. Run `timeout 30 o/bin/cosmic test`. A test whose verdict still stands -- same
   module key, same contents for every file opened, and same stat and directory
   read answers under the root -- is not run again, so a run after a small edit
   takes seconds; a run after a boot, or on a fresh `o/`, runs everything and
   still finishes in single-digit seconds under the native coverage collector.
   Treat an actual
   timeout as a failure to investigate, and report it separately from an
   assertion failure. Do not silently raise the limit; inspect elapsed time and
   the slow work first. To benchmark full test execution, delete only the rows
   from the `verdicts` table in `o/build.db`; preserve the staged database and
   report the `ran` and `stood` counts with the elapsed time.

Tests belong in `*_test.tl` files as top-level `local function test_*` functions.
Do not add a top-level `return` to test files. Prefer small regression cases that
fail for the reported bug over assertions that pin incidental implementation.
Documentation-only edits do not require rebuilding or running tests.

## Bootstrap troubleshooting

If the pinned Zig download fails to extract because tar cannot restore ownership
in a container, retry with `TAR_OPTIONS=--no-same-owner bin/zig version`, then
resume the normal build commands.
