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

local function test_a_floor_is_a_percentage_from_0_to_100()
  for text, wanted in pairs({ ["76"] = 76.0, ["76.5"] = 76.5, ["0"] = 0.0, ["100"] = 100.0, ["0.25"] = 0.25 }) do
    local got, why = test_report.percent(text, "--min")
    assert(got == wanted and why == "", text .. ": " .. tostring(got) .. tostring(why))
  end
  for _, text in ipairs({ "", "x", "101", "100.1", "-1", "1e2", "0x10", "7 6", "nan", "inf", ".5", "5.", "%" }) do
    local got, why = test_report.percent(text, "--min-file")
    assert(got == nil and why == "--min-file must be a percentage from 0 to 100, not " .. text, text .. ": " .. why)
  end
end

local function test_a_floor_names_each_file_and_the_total_that_fall_short()
  local files: {test_report.FileLines} = {
    { path = "z.tl", hit = 1, lines = 8 }, { path = "a.tl", hit = 3, lines = 4 },
    { path = "core/a.c", hit = 1, lines = 8 }, { path = "empty.tl", hit = 0, lines = 0 },
  }
  local none = test_report.floor(13, 24, files, {})
  assert(#none.lines == 0 and none.clause == "")
  -- At the floor is not under it, for the total and for a file.
  local at = test_report.floor(3, 4, { { path = "a.tl", hit = 3, lines = 4 } }, { min = 75.0, min_file = 75.0 })
  assert(#at.lines == 0 and at.clause == "", table.concat(at.lines, "\n"))
  local total = test_report.floor(1, 4, files, { min = 76.0 })
  assert(table.concat(total.lines, "\n") == "test: FAIL  coverage: 25.0% (1/4 lines) is under --min 76%")
  assert(total.clause == "coverage floor not met: 25.0% under --min 76%", total.clause)
  local per_file = test_report.floor(13, 24, files, { min_file = 50.0 })
  assert(table.concat(per_file.lines, "\n") ==
      "test: FAIL  coverage: core/a.c 12.5% (1/8 lines) is under --min-file 50%\n" ..
      "test: FAIL  coverage: z.tl 12.5% (1/8 lines) is under --min-file 50%", table.concat(per_file.lines, "\n"))
  assert(per_file.clause == "coverage floor not met: 2 files under --min-file 50%", per_file.clause)
  local both = test_report.floor(1, 4, { { path = "z.tl", hit = 1, lines = 8 } }, { min = 76.5, min_file = 50.0 })
  assert(#both.lines == 2, table.concat(both.lines, "\n"))
  assert(both.lines[1]:find("is under --min 76.5%", 1, true) ~= nil, both.lines[1])
  assert(both.clause == "coverage floor not met: 25.0% under --min 76.5%, 1 file under --min-file 50%", both.clause)
  -- A run that measured no line is under any floor above 0.
  assert(#test_report.floor(0, 0, {}, { min = 1.0 }).lines == 1)
  assert(#test_report.floor(0, 0, {}, { min = 0.0 }).lines == 0)
  assert(test_report.coverage(1, 4, true) == "test: coverage 25.0% (1/4 lines)")
end
