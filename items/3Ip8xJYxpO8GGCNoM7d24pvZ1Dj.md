## Change

`_make/engine.tl` (34 lines) decides by position (`_make/**`, `_cli/**`) plus a hand-kept five-file `_tool/**` list which tests get `o/bin/cosmic` in `deps_<stem>`. 32 `cosmic/**` tests spawn the same binary through `TEST_BIN` and are left out, so an edit to `_cli/docs.tl` or `cmd/cosmic/embed_gen.tl` replays their cached PASS — the exact bug class the positional rule was added for.

1. `_make/engine.tl`: keep the positional rule; delete `TOOL_ENGINE_TESTS`; add a content rule — `exercises_the_engine(path)` also returns true when `fs.read(path)` succeeds and the text contains the literal token `TEST_BIN` (`text:find("TEST_BIN", 1, true)`). Read relative to the cwd: the graph is built after `open_project` chdirs to the root (`_make/init.tl:56-58`), and `refstamp.resolve` already relies on the same fact. A path that cannot be read falls back to position alone. `require("cosmic.fs")` is the one new import. Keep the signature `(path: string)` so `_make/graph.tl:194` is untouched — the prerequisite-guard item edits that line.
2. `_make/engine_test.tl` (65 lines): replace `test_confirmed_tool_spawners_match` and the `_tool/**` negative case with cases over files the test writes under `TEST_TMPDIR` (absolute paths read fine): a `cosmic/x_test.tl`-shaped file mentioning `TEST_BIN` matches; one without it does not; a `_make/**` path that does not exist still matches by position; and the five former list entries, checked against the real tree from the repo root (`os.getenv("TEST_TMPDIR")` is not the root, so `in_dir`-style chdir to `..` is NOT allowed — instead read them via `fs.read` of their repo-relative path only if `fs.is_file` says the cwd is the root, else skip that sub-assertion aloud). Delete the "cosmic/** is out of scope" comment and assertion at lines 52-60.
3. Coverage: hand-edit `.cosmic-coverage`'s `_make/engine.tl` row per AGENTS.md; never `--baseline`.

## Evidence

The wall (`git show origin/main:_make/engine_test.tl | sed -n 52,60p`):
```
-- Everywhere else -- cosmic/**, _perf/**, the repo root -- is out of
-- scope for this positional rule; a path there never matches, whatever
-- it happens to import.
local function test_other_paths_do_not_match()
  check.truthy(not engine.exercises_the_engine("cosmic/proc_test.tl"),
```
The files it walls off (`git grep -l 'TEST_BIN' origin/main -- 'cosmic/**_test.tl' | wc -l` → 32; `git grep -L` → 116 do not):
```
cosmic/binary_test.tl cosmic/check_test.tl cosmic/child/init_test.tl cosmic/child/io_test.tl
cosmic/child/stdio_test.tl cosmic/compile_test.tl cosmic/cosmic_debug_test.tl cosmic/cosmic_test.tl
cosmic/coverage/init_test.tl cosmic/doc/guide_test.tl cosmic/embed_advanced_test.tl
cosmic/embed_env_test.tl cosmic/embed_test.tl cosmic/env_test.tl cosmic/include_dir_test.tl
cosmic/proc_test.tl cosmic/quicksand/box/run_test.tl cosmic/quicksand/caps_test.tl
cosmic/quicksand/init_test.tl cosmic/quicksand/netns_test.tl cosmic/quicksand/proc_test.tl
cosmic/sandbox/init_test.tl cosmic/sandbox/landlock_net_test.tl cosmic/sandbox/landlock_scope_test.tl
cosmic/sandbox/landlock_test.tl cosmic/sandbox/pledge_test.tl cosmic/sandbox/unveil_test.tl
cosmic/script_test.tl cosmic/stream_test.tl cosmic/tl_loader_test.tl cosmic/tty_test.tl cosmic/version_test.tl
```
The content rule subsumes the hand list (`git grep -c 'TEST_BIN' origin/main -- _tool/benchmark_test.tl _tool/coverage/baseline_test.tl _tool/example_test.tl _tool/lint_test.tl _tool/testrun_test.tl` → 1, 3, 1, 1, 2) and no test outside `_cli`, `_make`, `_tool`, `cosmic` names it (`git grep -l TEST_BIN origin/main -- '*_test.tl' | grep -v -E '^origin/main:(_cli|_make|_tool|cosmic)/'` prints nothing). `TEST_BIN` is what the runner sets (`_make/stage.tl:242-250`), and the cost of the rule is one extra `fs.read` per test at graph build plus hashing `o/bin/cosmic` into 32 more content keys per run — measure a warm `--make test` before and after and quote both in the PR.

## Non-goals

A test that spawns `cosmic` by bare name through `PATH` without the token is not caught; `git grep -n '{"cosmic"' origin/main -- '*_test.tl'` finds no such argv today, which says only that this one spelling is absent.
