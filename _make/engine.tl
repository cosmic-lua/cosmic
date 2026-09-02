--- Whether a test file spawns the tree's own built `cosmic` -- behavior
--- no import edge can name, so `_make/graph.tl`'s `project_mk` uses this
--- to add `o/bin/cosmic` to a test's `deps_<stem>` BY POSITION.

--- `_tool/**` tests confirmed to spawn `TEST_BIN`'s built `cosmic`, named
--- individually rather than swept in by a `^_tool/` prefix: most of
--- `_tool/**` is pure-unit tests that never touch the binary.
local TOOL_ENGINE_TESTS: {string: boolean} = {
  ["_tool/benchmark_test.tl"] = true,
  ["_tool/coverage/baseline_test.tl"] = true,
  ["_tool/example_test.tl"] = true,
  ["_tool/lint_test.tl"] = true,
  ["_tool/testrun_test.tl"] = true,
}

--- Whether a test drives `--make` itself, or a binary it produces, by
--- spawning cosmic. Position decides it: `_make/**` and `_cli/**` are
--- this project's own tooling, plus the explicit `_tool/**` set above.
--- @param path string Source file path, relative to the root
--- @return boolean
local function exercises_the_engine(path: string): boolean
  return path:match("^_make/") ~= nil or path:match("^_cli/") ~= nil
  or TOOL_ENGINE_TESTS[path] == true
end

local record EngineModule
  exercises_the_engine: function(path: string): boolean
end

local M: EngineModule = {
  exercises_the_engine = exercises_the_engine,
}

return M
