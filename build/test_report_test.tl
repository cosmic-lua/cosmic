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
      "9 tests passed in 3 modules; 4 ran, 5 stood, 1 skipped (this host could not check it), " ..
      "2 run every time (no key holds them), 3 of them on another checkout's verdict, " ..
      "7 ms; sandboxed")
  assert(test_report.passed({ total = 9, modules = 3, ran = 4, cached = 3,
    skipped = 1, na = 2, every = 0, shared = 0 }, "7 ms") ==
      "9 tests passed in 3 modules; 4 ran, 3 stood, 1 skipped (this host could not check it), " ..
      "2 n/a (this platform has none of what they check), 7 ms")
  assert(table.concat(test_report.nas({ "z: requires proc: none", "a: requires proc: none" }), "\n") ==
      "test: N/A  a: requires proc: none\ntest: N/A  z: requires proc: none")
  assert(test_report.failed(2, 9, 1, "7 ms") ==
      "2 of 9 tests failed, 1 infrastructure error, 7 ms")
  assert(test_report.failed(1, 1, 0, "7 ms") == "1 of 1 test failed, 0 infrastructure errors, 7 ms")
  assert(test_report.failed(1, 3, 0, "7 ms", 2) ==
      "1 of 3 tests failed, 0 infrastructure errors, 7 ms; 2 not run after the first failure")
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

--- Properties that stopped drawing are one line, sorted, naming what each drew.
local function test_stopped_properties_are_one_sorted_line()
  assert(#test_report.stopped({}) == 0)
  local lines = test_report.stopped({ "b drew 64 of 10000 inputs in 130 s (FUZZ_SECONDS=120): each cost about 2.03 s",
    "a drew 70 of 10000 inputs in 121 s (FUZZ_SECONDS=120): each cost about 1.73 s" })
  assert(#lines == 1)
  assert(lines[1] == "test: fuzz: 2 properties stopped by FUZZ_SECONDS: a drew 70 of 10000 inputs, b drew 64 of 10000 inputs",
    tostring(lines[1]))
  assert(test_report.stopped({ "x drew 64 of 99 inputs in 5 s (FUZZ_SECONDS=1)" })[1] ==
      "test: fuzz: 1 property stopped by FUZZ_SECONDS: x drew 64 of 99 inputs")
end

local function test_a_shown_output_is_listed_beneath_its_test_in_the_form_a_failure_has()
  local lines = test_report.shown({
    { id = "z.m_test test_b", printed = "one\ntwo\n" },
    { id = "a.m_test test_a", printed = "x" },
  })
  assert(table.concat(lines, "\n") == "test: PASS  a.m_test test_a\n  | x\n" ..
      "test: PASS  z.m_test test_b\n  | one\n  | two")
  -- As long an output is cut as a failure's is, from the front.
  lines = test_report.shown({ { id = "a test_x", printed = "prefix" .. string.rep("x", 4096) } })
  assert(lines[2] == "  | ..." .. string.rep("x", 4096))
  assert(#test_report.shown({}) == 0)
  assert(test_report.shown_note(0) == nil)
  assert(test_report.shown_note(1) == "test: show-output: 1 test stood and so printed nothing; --all runs it")
  assert(test_report.shown_note(2) == "test: show-output: 2 tests stood and so printed nothing; --all runs them")
end

local function test_a_failure_names_the_relative_paths_it_did_not_find()
  local function found(message: string): string
    return table.concat(test_report.missing_relative_paths(message), " ")
  end
  assert(found("a test_x: fixture.txt: No such file or directory") == "fixture.txt")
  assert(found("a test_x: x.tl:3: suite/data/p.txt: No such file or directory") == "suite/data/p.txt")
  assert(found("a test_x: cannot open 'a/b.txt': No such file or directory") == "a/b.txt")
  assert(found("a test_x: (a.txt): No such file or directory\nb.txt: No such file or directory") == "a.txt b.txt")
  -- Once, though it is named twice; and an absolute path, a URL, a path out of the tree are no business of it.
  assert(found("x: a.txt: No such file or directory a.txt: No such file or directory") == "a.txt")
  assert(found("x: /etc/passwd: No such file or directory") == "")
  assert(found("x: http://example.com/a.txt: No such file or directory") == "")
  assert(found("x: ../a.txt: No such file or directory") == "")
  assert(found("x: a/../../b.txt: No such file or directory") == "")
  assert(found("x: other error: Permission denied") == "")
  assert(test_report.tree_hint("a/b.txt") == "a/b.txt is not in this test's sandbox, though it is in the " ..
      "tree: grant it in Test.policy { grants = { { path = \"a/b.txt\", letters = \"r\" } } } " ..
      "(see cosmic docs cosmic.test)")
end
