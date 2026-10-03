--- Output contracts shared with CI's suite parser and copyable rerun commands.

local test_report = require("build.test_report")

local function test_a_selector_is_printed_as_one_shell_word()
  local function shell_word(word: string): string
    local lines = test_report.failures({ { message = "failed", rerun = word } }, "")
    return assert(lines[2]:match("^  rerun: cosmic test (.*)$"))
  end
  assert(shell_word("build/test_test.tl:test_x") == "build/test_test.tl:test_x")
  assert(shell_word("a b/c_test.tl:t") == "'a b/c_test.tl:t'")
  assert(shell_word("it's_test.tl:t") == "'it'\\''s_test.tl:t'")
  assert(shell_word("-x_test.tl:t") == "./-x_test.tl:t")
  assert(shell_word("-a b_test.tl:t") == "'./-a b_test.tl:t'")
  assert(shell_word("$x_test.tl:t") == "'$x_test.tl:t'")
  assert(shell_word("") == "''")
end

local function test_failures_sort_and_keep_reruns_and_output_together()
  local lines = test_report.failures({
    { message = "z test_a: broken", rerun = "a b_test.tl:test_a", printed = "first\nsecond\n" },
    { message = "a test_b: broken" },
  }, "FUZZ_CASE='x:y' ")
  assert(table.concat(lines, "\n") == "test: FAIL  a test_b: broken\n" ..
      "test: FAIL  z test_a: broken\n" ..
      "  rerun: FUZZ_CASE='x:y' cosmic test 'a b_test.tl:test_a'\n" ..
      "  | first\n  | second")
  lines = test_report.failures({ { message = "a test_x: broken", printed =
      "prefix" .. string.rep("x", 4096) } }, "")
  assert(lines[2] == "  | ..." .. string.rep("x", 4096))
  assert(table.concat(test_report.skips({ "z: denied", "a: denied" }), "\n") ==
      "test: SKIP  a: denied\ntest: SKIP  z: denied")
end

local function test_summaries_keep_the_figures_ci_reads_in_order()
  assert(test_report.passed({ total = 9, modules = 3, ran = 4, cached = 5,
    skipped = 1, every = 2, shared = 3 }, "7 ms; sandboxed") ==
      "9 tests, 3 modules; 4 ran, 5 stood, 1 skipped (this host could not check it), " ..
      "2 run every time (no key holds them), 3 of them on another checkout's verdict, " ..
      "7 ms; sandboxed")
  assert(test_report.failed(2, 9, 1, "7 ms") ==
      "2 of 9 failed, 1 infrastructure error, 7 ms")
  assert(test_report.coverage(1, 4) ==
      "test: coverage 25.0% (1/4 lines; informational, never a failure)")
  assert(test_report.coverage(0, 0) ==
      "test: coverage 0.0% (0/0 lines; informational, never a failure)")
end

--- A test that called a method its value lacks -- a record's value made
--- as a table literal, never given the record as its metatable -- is
--- told how to make one that has it, straight under its failure line
--- and ahead of what the runner appended to the message.
local function test_a_missing_method_is_told_the_metatable()
  local lines = test_report.failures({ { message =
      "kv_example basic_usage: kv_example:9: attempt to call a nil value (method 'set')\n" ..
      "  its directory is kept: /tmp/x",
    rerun = "kv_example.tl:basic_usage" } }, "")
  local text = table.concat(lines, "\n")
  assert(text ==
      "test: FAIL  kv_example basic_usage: kv_example:9: attempt to call a nil value (method 'set')\n" ..
      "  hint: 'set' is nil on that value: either it was made as a table literal, " ..
      "which gets none of R's methods (make it with `setmetatable({ ... }, { __index = R })`), " ..
      "or R declares 'set' and nothing defines `function R:set`\n" ..
      "  its directory is kept: /tmp/x\n" ..
      "  rerun: cosmic test kv_example.tl:basic_usage", text)
  lines = test_report.failures({ { message = "a test_b: a:1: attempt to call a nil value (field 'x')" } }, "")
  assert(#lines == 1)
end
