--- Output contracts shared with CI's suite parser and copyable rerun commands.

local test_report = require("build.test_report")
local Array = require("cosmic.array")

local function test_a_selector_is_printed_as_one_shell_word()
  local function shell_word(word: string): string
    local lines = test_report.failures({ { message = "failed", rerun = word } }, "")
    return assert(Array.at(lines, 2):match("^  rerun: cosmic test (.*)$"))
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

--- A run where none ran and some stood says why and how to run them, after
--- the figures CI's reader finds by their places.
local function test_a_run_where_every_test_stood_says_why_none_ran()
  local line = test_report.passed({ total = 5, modules = 2, ran = 0, cached = 5,
    skipped = 0, every = 0, shared = 0 }, "7 ms")
  assert(line == "5 tests passed in 2 modules; 0 ran, 5 stood, none ran, as nothing the tests that stood " ..
      "are keyed on changed since their verdicts (--all runs them), 7 ms", line)
  assert(line:match("; (%d+) ran, ") == "0" and line:match(" (%d+) stood, ") == "5" and
      line:match(", (%d+) ms") == "7", line)
  assert(test_report.passed({ total = 1, modules = 1, ran = 0, cached = 1, skipped = 0, every = 0, shared = 0 }, "7 ms") ==
      "1 test passed in 1 module; 0 ran, 1 stood, none ran, as nothing the test that stood is keyed on " ..
      "changed since its verdict (--all runs it), 7 ms")
  assert(test_report.passed({ total = 5, modules = 1, ran = 0, cached = 4, skipped = 1, every = 0, shared = 4 }, "7 ms") ==
      "5 tests passed in 1 module; 0 ran, 4 stood, 1 skipped (this host could not check it), 4 of them on " ..
      "another checkout's verdict, none ran, as nothing the tests that stood are keyed on changed since their " ..
      "verdicts (--all runs them), 7 ms")
  -- A run where some ran, or none stood, says nothing of it.
  assert(not test_report.passed({ total = 5, modules = 2, ran = 1, cached = 4, skipped = 0, every = 0, shared = 0 },
    "7 ms"):find("keyed on", 1, true))
  assert(not test_report.passed({ total = 0, modules = 0, ran = 0, cached = 0, skipped = 0, every = 0, shared = 0 },
    "7 ms"):find("keyed on", 1, true))
end

--- The coverage line and a floor's failure print one figure the same way:
--- rounded down, to as many decimals as the floor has and one at least.
--- 14610/15002 is 97.387%: rounding put 97.4% on the line and the failure
--- said 97.3% under --min 97.4%.
local function test_the_coverage_line_and_a_floor_print_one_figure()
  local floors: test_report.Floors = { min = 97.4 }
  assert(test_report.coverage(14610, 15002, floors) == "test: coverage 97.3% (14610/15002 lines)",
    test_report.coverage(14610, 15002, floors))
  local short = test_report.floor(14610, 15002, {}, floors)
  assert(short.lines[1] == "test: FAIL  coverage: 97.3% (14610/15002 lines) is under --min 97.4%", short.lines[1])
  assert(test_report.coverage(14610, 15002) ==
      "test: coverage 97.3% (14610/15002 lines; informational, never a failure)")
  -- A floor with two decimals shows the figure to two, so one under it never reads as at it.
  local fine: test_report.Floors = { min = 97.39, min_file = 97.39 }
  assert(test_report.coverage(14610, 15002, fine) == "test: coverage 97.38% (14610/15002 lines)",
    test_report.coverage(14610, 15002, fine))
  local finer = test_report.floor(14610, 15002, { { path = "a.tl", hit = 14610, lines = 15002 } }, fine)
  assert(finer.lines[1] == "test: FAIL  coverage: 97.38% (14610/15002 lines) is under --min 97.39%", finer.lines[1])
  assert(finer.lines[2] == "test: FAIL  coverage: a.tl 97.38% (14610/15002 lines) is under --min-file 97.39%",
    finer.lines[2])
  assert(finer.clause == "coverage floor not met: 97.38% under --min 97.39%, 1 file under --min-file 97.39%",
    finer.clause)
  -- A whole floor still shows one decimal; a figure of 100 and of 0 print whole.
  assert(test_report.coverage(4, 4, { min = 90.0 }) == "test: coverage 100.0% (4/4 lines)")
  assert(test_report.coverage(0, 4, { min = 90.0 }) == "test: coverage 0.0% (0/4 lines)")
  assert(test_report.coverage(1, 3, { min = 0.25 }) == "test: coverage 33.33% (1/3 lines)")
  -- As many decimals as the floor has, up to the four a floor may have; and --min-file's set each file's.
  assert(test_report.coverage(14610, 15002, { min = 97.3874 }) == "test: coverage 97.3870% (14610/15002 lines)")
  assert(test_report.coverage(14610, 15002, { min = 0.0001 }) == "test: coverage 97.3870% (14610/15002 lines)")
  assert(test_report.coverage(14610, 15002, { min_file = 97.39 }) == "test: coverage 97.3% (14610/15002 lines)")
  local files = test_report.floor(14610, 15002, { { path = "a.tl", hit = 14610, lines = 15002 } },
    { min = 50.0, min_file = 97.3871 })
  assert(files.lines[1] == "test: FAIL  coverage: a.tl 97.3870% (14610/15002 lines) is under --min-file 97.3871%",
    files.lines[1])
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
  end -- More decimals than a figure prints to, or the check compares exactly, are refused.
  assert(test_report.percent("97.1234", "--min") == 97.1234)
  for _, text in ipairs({ "97.12344", "99.99999", "0.00001" }) do
    local got, why = test_report.percent(text, "--min")
    assert(got == nil and why == "--min takes at most 4 decimals, which a figure prints to and the check " ..
        "compares exactly, not " .. text, text .. ": " .. why)
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
  -- Nothing to cover is under no floor.
  assert(#test_report.floor(0, 0, {}, { min = 1.0, min_file = 1.0 }).lines == 0)
  assert(test_report.coverage(1, 4, {}) == "test: coverage 25.0% (1/4 lines)")
  assert(test_report.coverage(0, 0, {}) ==
      "test: coverage 0.0% (0/0 lines; no lines to cover, so a floor holds vacuously)")
  -- Exactly under the floor never prints as reaching it.
  local near = test_report.floor(1599, 2000, { { path = "a.tl", hit = 1599, lines = 2000 } },
    { min = 80.0, min_file = 80.0 })
  assert(near.lines[1] == "test: FAIL  coverage: 79.9% (1599/2000 lines) is under --min 80%", near.lines[1])
  assert(assert(near.lines[2]):find("a.tl 79.9% (1599/2000", 1, true) ~= nil)
  assert(near.clause:find("79.9% under --min 80%", 1, true) ~= nil, near.clause)
  assert(#test_report.floor(1600, 2000, {}, { min = 80.0 }).lines == 0)
end

--- A figure that left out the standing hits of modules whose text moved
--- says it is partial. It is at most the true one, so a floor it meets is
--- met; one under a floor fails, saying the figure is partial and naming the
--- files it holds whose hits were dropped.
local function test_a_partial_figure_says_so_and_fails_a_floor_it_is_under()
  local note = "partial: hits of 2 modules came from runs on other text; `--all` reruns them"
  local other = test_report.other_text
  local two = { a = other, b = other }
  assert(test_report.coverage(1, 4, nil, two) ==
      "test: coverage 25.0% (1/4 lines; informational, never a failure; " .. note .. ")")
  assert(test_report.coverage(1, 4, {}, two) == "test: coverage 25.0% (1/4 lines; " .. note .. ")")
  assert(test_report.coverage(1, 4, {}, {}) == "test: coverage 25.0% (1/4 lines)")
  local stale = { ["b.m"] = other, ["c.m"] = other }
  local met = test_report.floor(3, 4, { { path = "b.m", hit = 3, lines = 4 } }, { min = 75.0, min_file = 75.0 }, stale)
  assert(#met.lines == 0 and met.clause == "", "a partial figure at the floor meets it")
  local files: {test_report.FileLines} = { { path = "a.m", hit = 1, lines = 4 }, { path = "b.m", hit = 1, lines = 4 } }
  local short = test_report.floor(2, 8, files, { min = 50.0, min_file = 50.0 }, stale)
  assert(table.concat(short.lines, "\n") ==
      "test: FAIL  coverage: 25.0% (2/8 lines; " .. note .. ") is under --min 50%\n" ..
      "test: FAIL  coverage: a.m 25.0% (1/4 lines) is under --min-file 50%\n" ..
      "test: FAIL  coverage: b.m 25.0% (1/4 lines; partial: its hits came from runs on other text; " ..
      "`--all` reruns them) is under --min-file 50%", table.concat(short.lines, "\n"))
  assert(short.clause == "coverage floor not met: 25.0% under --min 50% on a partial figure, " ..
      "2 files under --min-file 50% (1 on a partial figure)", short.clause)
end

--- A module whose standing hits were dropped for another reason than another text (an instruction its row numbers
--- that the run cannot place) is named with why, and not said to have come from other text.
local function test_a_partial_figure_names_a_module_dropped_for_another_reason()
  local why = "were not placed at its lines: instruction 4 is past the module's 3"
  local stale = { ["a.m"] = test_report.other_text, ["b.m"] = why }
  local line = test_report.coverage(1, 4, {}, stale)
  assert(line == "test: coverage 25.0% (1/4 lines; partial: hits of 2 modules are left out (1 came from runs on " ..
      "other text; the hits of b.m " .. why .. "); `--all` reruns them)", line)
  local short = test_report.floor(1, 4, { { path = "b.m", hit = 1, lines = 4 } }, { min_file = 50.0 }, stale)
  assert(table.concat(short.lines, "\n") == "test: FAIL  coverage: b.m 25.0% (1/4 lines; partial: its hits " .. why ..
      "; `--all` reruns them) is under --min-file 50%", table.concat(short.lines, "\n"))
  -- A mass of them names the first few, by path, and counts the rest.
  local many: mut {string:string} = {}
  for _, path in ipairs({ "e.m", "d.m", "c.m", "b.m", "f.m" }) do many[path] = why end
  local capped = test_report.coverage(1, 4, {}, many)
  assert(capped == "test: coverage 25.0% (1/4 lines; partial: hits of 5 modules are left out (the hits of b.m " ..
      why .. "; the hits of c.m " .. why .. "; the hits of d.m " .. why .. "; and 2 more); `--all` reruns them)", capped)
end

--- A decimal floor a file meets exactly holds, though `64.4 * 250` rounds above 16100 in floating point.
local function test_a_decimal_floor_met_exactly_holds()
  local at = test_report.floor(161, 250, { { path = "f.tl", hit = 161, lines = 250 } }, { min = 64.4, min_file = 64.4 })
  assert(#at.lines == 0, at.lines[1])
  assert(#test_report.floor(33, 375, { { path = "g.tl", hit = 33, lines = 375 } }, { min_file = 8.8 }).lines == 0)
  local short = test_report.floor(160, 250, { { path = "f.tl", hit = 160, lines = 250 } }, { min_file = 64.4 })
  assert(#short.lines == 1, "one line short of 64.4% is under it")
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
  assert(test_report.tree_hint("b.txt") == "b.txt is not in this test's sandbox, though it is in the " ..
      "tree: grant it in Test.policy { grants = { { path = \"b.txt\", letters = \"r\" } } } " ..
      "(see cosmic docs cosmic.test)")
end

--- A file in a directory is told the directory's grant too, for a test that reads more of it.
local function test_a_file_in_a_directory_is_told_the_directory_grant()
  assert(test_report.tree_hint("a/b/c.txt") == "a/b/c.txt is not in this test's sandbox, though it is in the " ..
      "tree: grant it in Test.policy { grants = { { path = \"a/b/c.txt\", letters = \"r\" } } }, or, " ..
      "for a test that reads more of a/b/, grant the directory: { path = \"a/b/\", letters = \"r\" } " ..
      "(see cosmic docs cosmic.test)", test_report.tree_hint("a/b/c.txt"))
end

--- A module that failed to load fails each of its tests for one cause, which ran outside every test: it is said once,
--- naming the tests and where the cause ran, and rerun by the module's file, though its text differs from test to test
--- (a path under each worker's own directory). A module of one test is said so too, and a test of another module as
--- before.
local function test_a_module_that_failed_to_load_is_one_failure()
  local function cause(dir: string): string
    return "the module failed to load: run_test:2: /tmp/" .. dir .. "/missing: no such file\n  its directory was a tmpfs"
  end
  local lines = test_report.failures({
    { message = "run_test test_b: " .. cause("b"), rerun = "run_test.tl:test_b" },
    { message = "run_test test_a: " .. cause("a"), rerun = "run_test.tl:test_a" },
    { message = "one_test test_c: " .. cause("c"), rerun = "one_test.tl:test_c" },
    { message = "other_test test_d: broken", rerun = "other_test.tl:test_d" },
  }, "")
  local text = table.concat(lines, "\n")
  local tail = "): what failed ran as the module loaded, at its top level and outside every test; move it into a test " ..
    "or a function the tests call\n  its directory was a tmpfs\n"
  assert(text == "test: FAIL  one_test: the module failed to load: run_test:2: /tmp/c/missing: no such file\n" ..
      "  its test did not run (test_c" .. tail ..
      "  rerun: cosmic test one_test.tl\n" ..
      "test: FAIL  other_test test_d: broken\n" ..
      "  rerun: cosmic test other_test.tl:test_d\n" ..
      "test: FAIL  run_test: the module failed to load: run_test:2: /tmp/a/missing: no such file\n" ..
      "  none of its 2 tests ran (test_a, test_b" .. tail ..
      "  rerun: cosmic test run_test.tl", text)
end
