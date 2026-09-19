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
   `o/` hold and how the last few builds went.
2. Edit source and tests, then run `o/bin/cosmic fix <changed-tl-paths>`.
   `fix` checks syntax and tree equivalence; compilation checks types.
3. Run `bin/zig build boot` after the final source edit, including any changes
   made by `fix`. Code and tests are embedded in the executable, so testing an
   older executable can exercise older implementations and tests.
4. Run `timeout 90 o/bin/cosmic test`. A test whose verdict still stands -- same
   module key, same hashes for every file under the root it read -- is not run
   again, so a run after a small edit takes seconds; a run after a boot, or on a
   fresh `o/`, runs everything and takes 30-40 seconds under the native coverage
   collector. A shorter timeout reports false failures on a tree with nothing
   wrong. Treat an actual timeout as a failure to investigate, and report it
   separately from an assertion failure. Do not silently raise it without checking
   real elapsed time first. Deleting `o/build.db` forgets every verdict.

Tests belong in `*_test.tl` files as top-level `local function test_*` functions.
Do not add a top-level `return` to test files. Prefer small regression cases that
fail for the reported bug over assertions that pin incidental implementation.
Documentation-only edits do not require rebuilding or running tests.

## Bootstrap troubleshooting

If the pinned Zig download fails to extract because tar cannot restore ownership
in a container, retry with `TAR_OPTIONS=--no-same-owner bin/zig version`, then
resume the normal build commands.
