local check = require("cosmic.check")
local fs = require("cosmic.fs")
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

-- Position matches even when the path does not exist: `_make/**` and
-- `_cli/**` never fall through to the content read.
local function test_nonexistent_positional_path_still_matches()
  check.truthy(engine.exercises_the_engine("_make/does_not_exist_test.tl"),
    "_make/** matches by position alone, no read needed")
end

-- Outside `_make/**` and `_cli/**`, content decides it: a file naming
-- the literal `TEST_BIN` token matches, whatever tree it lives in.
local function test_content_rule_matches_test_bin_token()
  local dir = check.must(os.getenv("TEST_TMPDIR"))
  local with = fs.join(dir, "x_test.tl")
  check.must(fs.write(with,
      "local bin = os.getenv(\"TEST_BIN\")\nprint(bin)\n"))
  check.truthy(engine.exercises_the_engine(with),
    "a cosmic/**-shaped file mentioning TEST_BIN matches")
end

local function test_content_rule_does_not_match_without_the_token()
  local dir = check.must(os.getenv("TEST_TMPDIR"))
  local without = fs.join(dir, "y_test.tl")
  check.must(fs.write(without, "local x = 1\nprint(x)\n"))
  check.truthy(not engine.exercises_the_engine(without),
    "a file that never mentions TEST_BIN does not match")
end

-- A path that cannot be read falls back to position alone: outside
-- `_make/**`/`_cli/**`, a missing or unreadable file does not match.
local function test_unreadable_path_falls_back_to_position()
  local dir = check.must(os.getenv("TEST_TMPDIR"))
  local missing = fs.join(dir, "does_not_exist_test.tl")
  check.truthy(not engine.exercises_the_engine(missing),
    "an unreadable path outside _make/_cli does not match")
end

-- The five former `_tool/**` list entries, re-checked against the real
-- tree: the content rule must subsume every one of them. TEST_TMPDIR is
-- not the root, so this reads them by repo-relative path only when the
-- cwd actually is the root; otherwise it skips the sub-assertion aloud
-- rather than chdir-ing out of TEST_TMPDIR.
local function test_content_rule_subsumes_former_tool_list()
  if not fs.is_file("_make/engine.tl") then
    print("skip: cwd is not the repo root, cannot read _tool/** by" ..
      " repo-relative path")
    return
  end
  local former_list = {
    "_tool/benchmark_test.tl",
    "_tool/coverage/baseline_test.tl",
    "_tool/example_test.tl",
    "_tool/lint_test.tl",
    "_tool/testrun_test.tl",
  }
  for _, path in ipairs(former_list) do
    check.truthy(engine.exercises_the_engine(path),
      path .. " still matches under the content rule")
  end
end

print("all engine tests passed")
