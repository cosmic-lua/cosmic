local check = require("cosmic.check")
local engine = require("_make.engine")

-- _make/** and _cli/** match by position: this project's own tooling
-- drives `--make` and its dispatcher directly, so any test file there
-- may spawn the binary the tree just built.
local function test_make_and_cli_paths_match()
  check.truthy(engine.exercises_the_engine("_make/fixtures_test.tl"),
    "_make/** matches")
  check.truthy(engine.exercises_the_engine("_make/build/nested_test.tl"),
    "a nested _make/** path still matches")
  check.truthy(engine.exercises_the_engine("_cli/args_test.tl"),
    "_cli/** matches")
  check.truthy(engine.exercises_the_engine("_cli/build/recipe_test.tl"),
    "a nested _cli/** path still matches")
end

-- The five `_tool/**` files confirmed (by reproducing the staleness bug
-- per-file) to spawn `TEST_BIN`'s built cosmic the same way
-- `_make/fixtures_test.tl` did.
local function test_confirmed_tool_spawners_match()
  check.truthy(engine.exercises_the_engine("_tool/benchmark_test.tl"),
    "benchmark_test.tl spawns cosmic --benchmark")
  check.truthy(engine.exercises_the_engine("_tool/coverage/baseline_test.tl"),
    "coverage/baseline_test.tl spawns cosmic for a real coverage run")
  check.truthy(engine.exercises_the_engine("_tool/example_test.tl"),
    "example_test.tl spawns cosmic --check example")
  check.truthy(engine.exercises_the_engine("_tool/lint_test.tl"),
    "lint_test.tl spawns cosmic --check lint")
  check.truthy(engine.exercises_the_engine("_tool/testrun_test.tl"),
    "testrun_test.tl spawns TEST_BIN/cosmic directly")
end

-- The rest of `_tool/**` is pure-unit tests over one module: they must
-- NOT match, or a `^_tool/` blanket would force them to re-run on every
-- engine edit for no reason -- the over-invalidation this item's audit
-- was written to avoid.
local function test_unconfirmed_tool_paths_do_not_match()
  check.truthy(not engine.exercises_the_engine("_tool/discover_test.tl"),
    "discover_test.tl never spawns TEST_BIN")
  check.truthy(not engine.exercises_the_engine("_tool/floor_test.tl"),
    "floor_test.tl never spawns TEST_BIN")
  check.truthy(not engine.exercises_the_engine("_tool/records_test.tl"),
    "records_test.tl never spawns TEST_BIN")
  check.truthy(not engine.exercises_the_engine("_tool/seam_test.tl"),
    "seam_test.tl spawns o/bootstrap/cosmic, declared via its own reads:")
  check.truthy(not engine.exercises_the_engine("_tool/coverage/lines_test.tl"),
    "coverage/lines_test.tl never spawns TEST_BIN")
  check.truthy(not engine.exercises_the_engine("_tool/doc/index_test.tl"),
    "doc/index_test.tl never spawns TEST_BIN")
end

-- Everywhere else -- cosmic/**, _perf/**, the repo root -- is out of
-- scope for this positional rule; a path there never matches, whatever
-- it happens to import.
local function test_other_paths_do_not_match()
  check.truthy(not engine.exercises_the_engine("cosmic/proc_test.tl"),
    "cosmic/** is not _make/_cli/_tool")
  check.truthy(not engine.exercises_the_engine("_perf/bench/binary.tl"),
    "_perf/** is not _make/_cli/_tool")
  check.truthy(not engine.exercises_the_engine("tool_test.tl"),
    "a bare prefix match ('tool' vs '_tool/') must not slip through")
end

print("all engine tests passed")
