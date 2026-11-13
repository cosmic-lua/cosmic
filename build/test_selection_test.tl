--- CLI coverage for test-module selection. The child project contains an
--- unrelated failing test, so a passing selected run proves it was not loaded.

local Child = require("cosmic.child")
local Fs = require("cosmic.fs")
local Sqlite = require("cosmic.sqlite")
local this_program = require("build.this_program")
local Test = require("cosmic.test")
local Clock = require("cosmic.clock")
local support = require("build.test_support_fixture")

--- The program itself, which its tests start.
Test.policy{ profiles = { "cosmic" }, grants = { { path = "o/bin", letters = "rx" } } }

local function invoke(root: string, output: string, selector: string): Child.Result
  local fd = assert(Fs.open_write(output))
  -- Unsandboxed, whatever this run's switch: what is chosen, and what
  -- a choice runs and reports, is the same either way, and a sandbox
  -- nested in this test's own is one a host may refuse (root nests one
  -- only two deep, where its runner cannot run its workers as a user of
  -- their own). The rerun line it prints repeats the switch.
  local env = this_program.environment()
  env["COSMIC_TEST_SANDBOX"] = "0"
  -- What its failing tests keep stays in this test's directory.
  env["TMPDIR"] = Fs.dirname(output)
  local started = this_program.program({ "test", selector }, {
    cwd = root, env = env, stdout = fd, stderr = fd,
    process_group = true, timeout_ns = Clock.seconds(30),
  })
  local result, trouble = Child.run(started.argv, started.options)
  assert(Fs.close(fd))
  return (assert(result, trouble))
end

--- A run of `cosmic test` with `words` in `root`, as `invoke`'s.
local function invoke_words(root: string, output: string, words: {string}): Child.Result
  local fd = assert(Fs.open_write(output))
  local env = this_program.environment()
  env["COSMIC_TEST_SANDBOX"] = "0"
  env["TMPDIR"] = Fs.dirname(output)
  local argv: mut {string} = { "test" }
  for _, word in ipairs(words) do argv[#argv + 1] = word end
  local started = this_program.program(argv, {
    cwd = root, env = env, stdout = fd, stderr = fd,
    process_group = true, timeout_ns = Clock.seconds(30),
  })
  local result, trouble = Child.run(started.argv, started.options)
  assert(Fs.close(fd))
  return (assert(result, trouble))
end

local function project(tmp: string): string
  local root = tmp .. "/project"
  assert(Fs.mkdirs(root .. "/suite"))
  assert(Fs.write(root .. "/suite/helper.tl", [[
local record helper
  answer: integer
end
local h: helper = { answer = 42 }
return h
]]))
  assert(Fs.write(root .. "/suite/selected_test.tl", [[
local helper = require("suite.helper")
local function test_selected()
  assert(helper.answer == 42)
end
]]))
  assert(Fs.write(root .. "/suite/unrelated_test.tl", [[
local function test_unrelated()
  error("unrelated test executed")
end
]]))
  return root
end

local function test_cli_selects_one_path_and_runs_it_fresh(tmp: string)
  local root = project(tmp)
  local output = tmp .. "/selected.out"
  local result = invoke(root, output, "suite/selected_test.tl")
  assert(result.ok, assert(Fs.read(output)))
  local text = assert(Fs.read(output))
  assert(text:find("1 ran, 0 stood", 1, true), text)
  assert(not text:find("unrelated test executed", 1, true), text)
  local db = assert(Sqlite.open(support.build_dir(root) .. "/build.db"))
  local rows = assert(Sqlite.text_rows(db,
    "SELECT COUNT(*) FROM coverage WHERE path = 'suite.helper'"))
  assert(db:close())
  assert(support.nth(rows, 1):text(1) ~= "0", "selected run omitted dependency coverage")
end

local function test_a_standing_verdict_still_credits_its_coverage(tmp: string)
  local root = project(tmp)
  for run, expected in ipairs({ "1 ran, 0 stood", "0 ran, 1 stood" }) do
    local output = tmp .. "/run-" .. tostring(run) .. ".out"
    local result = invoke(root, output, "suite/selected_test.tl")
    local text = assert(Fs.read(output))
    assert(result.ok, text)
    assert(text:find(expected, 1, true), text)
  end
  local db = assert(Sqlite.open(support.build_dir(root) .. "/build.db"))
  local by_run = assert(Sqlite.text_rows(db,
    "SELECT SUM(hit) FROM coverage WHERE path = 'suite.helper' " ..
      "GROUP BY ran_at_ns ORDER BY ran_at_ns"))
  local credits = assert(Sqlite.text_rows(db,
    "SELECT test, hits FROM coverage_by_test"))
  assert(db:close())
  assert(#by_run == 2, "expected a coverage snapshot per run")
  assert(by_run[1]:text(1) ~= "0" and support.nth(by_run, 2):text(1) == support.nth(by_run, 1):text(1),
    "the standing run credited " .. support.nth(by_run, 2):text(1) .. " lines, not " .. support.nth(by_run, 1):text(1))
  assert(#credits == 1, "expected one coverage_by_test row for the one test")
  -- The helper's lines name the text they are numbered in, a prefix of its source hash.
  assert(credits[1]:text(2):find("suite%.helper %x+\t"), support.nth(credits, 1):text(2))
end

--- A standing row credits a module's lines only while the module's text is
--- the one the row names: a comment that moves a harness module's lines moves
--- no key, so the lines a row names can have moved. A row naming another text,
--- or none (written by an older tool), credits none of the module's lines,
--- and the coverage line says the figure is partial.
local function test_a_standing_row_numbered_in_another_text_credits_none_of_its_lines(tmp: string)
  local root = project(tmp)
  for case, named in ipairs({ "suite.helper 0000000000000000\t", "suite.helper\t" }) do
    local first = tmp .. "/first-" .. tostring(case) .. ".out"
    local ran = invoke_words(root, first, { "--all", "suite/selected_test.tl" })
    assert(ran.ok, assert(Fs.read(first)))
    local db = assert(Sqlite.open(support.build_dir(root) .. "/build.db", { writable = true }))
    local rows = assert(Sqlite.text_rows(db, "SELECT ran_at_ns, test, hits FROM coverage_by_test " ..
        "WHERE ran_at_ns = (SELECT max(ran_at_ns) FROM coverage_by_test)"))
    local row = support.nth(rows, 1)
    local moved, count = row:text(3):gsub("suite%.helper %x+\t", named)
    assert(count == 1, row:text(3))
    assert(Sqlite.run(db, "UPDATE coverage_by_test SET hits = ?1 WHERE ran_at_ns = ?2 AND test = ?3",
      { { text = moved }, { integer = math.tointeger(tonumber(row:text(1))) or 0 }, { text = row:text(2) } }))
    assert(db:close())
    local output = tmp .. "/stood-" .. tostring(case) .. ".out"
    local stood = invoke(root, output, "suite/selected_test.tl")
    local text = assert(Fs.read(output))
    assert(stood.ok, text)
    assert(text:find("0 ran, 1 stood", 1, true), text)
    assert(text:find("partial: hits of 1 module came from runs on other text; `--all` reruns them", 1, true), text)
    db = assert(Sqlite.open(support.build_dir(root) .. "/build.db"))
    local hit = assert(Sqlite.text_rows(db, "SELECT sum(hit) FROM coverage WHERE path = 'suite.helper' " ..
        "AND ran_at_ns = (SELECT max(ran_at_ns) FROM coverage)"))
    assert(db:close())
    assert(support.nth(hit, 1):text(1) == "0", "credited " .. support.nth(hit, 1):text(1) .. " lines of another text")
  end
end

--- A snapshot holds every executable line of a module, ascending, with
--- whether the run hit it: the lines of a function the test called are 1, those
--- of one it did not are 0, each an integer.
local function test_a_snapshot_holds_each_line_with_whether_it_was_hit(tmp: string)
  local root = project(tmp)
  assert(Fs.write(root .. "/suite/helper.tl", [[
local record helper
  mut answer: integer
end
function helper.used(): integer
  local a = 1
  return a
end
function helper.unused(): integer
  local b = 2
  return b
end
helper.answer = helper.used() + 41
return helper
]]))
  local output = tmp .. "/lines.out"
  local result = invoke(root, output, "suite/selected_test.tl")
  assert(result.ok, assert(Fs.read(output)))
  local db = assert(Sqlite.open(support.build_dir(root) .. "/build.db"))
  local rows = assert(Sqlite.text_rows(db,
    "SELECT group_concat(line || ':' || hit, ' ') FROM (SELECT line, hit FROM coverage " ..
      "WHERE path = 'suite.helper' ORDER BY line)"))
  local kinds = assert(Sqlite.text_rows(db,
    "SELECT DISTINCT typeof(line) || typeof(hit) FROM coverage WHERE path = 'suite.helper'"))
  local distinct = assert(Sqlite.text_rows(db,
    "SELECT count(*), count(DISTINCT line) FROM coverage WHERE path = 'suite.helper'"))
  assert(db:close())
  local lines = assert(rows[1]):text(1)
  assert(lines == "4:1 5:1 6:1 8:1 9:0 10:0 12:1 13:1", lines)
  assert(#kinds == 1 and assert(kinds[1]):text(1) == "integerinteger", "a cell was not an integer")
  local counted = assert(distinct[1])
  assert(counted:text(1) == counted:text(2), "a line was written twice")
end

local function test_cli_runs_only_the_one_test_a_selector_names(tmp: string)
  local root = project(tmp)
  assert(Fs.write(root .. "/suite/selected_test.tl", [[
local helper = require("suite.helper")
local function test_selected()
  assert(helper.answer == 42)
end
local function test_sibling()
  error("sibling test executed")
end
]]))
  for run, expected in ipairs({ "1 ran, 0 stood", "0 ran, 1 stood" }) do
    local output = tmp .. "/named-" .. tostring(run) .. ".out"
    local result = invoke(root, output, "./suite/selected_test.tl:test_selected")
    local text = assert(Fs.read(output))
    assert(result.ok, text)
    assert(text:find("1 test passed in 1 module; " .. expected, 1, true), text)
    assert(not text:find("executed", 1, true), text)
  end
  local output = tmp .. "/module.out"
  local result = invoke(root, output, "suite.selected_test:test_selected")
  local text = assert(Fs.read(output))
  assert(result.ok, text)
  assert(text:find("0 ran, 1 stood", 1, true), text)
  local db = assert(Sqlite.open(support.build_dir(root) .. "/build.db"))
  local credits = assert(Sqlite.text_rows(db, "SELECT test FROM coverage_by_test"))
  assert(db:close())
  assert(#credits == 1 and credits[1]:text(1) == "suite.selected_test test_selected",
    "expected only the named test credited")
end

--- Each test's row holds the lines its own module's load ran: the runner takes a load's hits once for every
--- test whose worker reports them alike, and a test given another module's would be credited what it never ran.
local function test_each_tests_row_holds_its_own_modules_load(tmp: string)
  local root = tmp .. "/project"
  assert(Fs.mkdirs(root .. "/suite"))
  for _, name in ipairs({ "one", "two" }) do
    assert(Fs.write(root .. "/suite/" .. name .. ".tl", [[
local record helper
  answer: integer
end
local h: helper = { answer = 42 }
return h
]]))
    assert(Fs.write(root .. "/suite/" .. name .. "_test.tl", (([[
local helper = require("suite.NAME")
local function test_first()
  assert(helper.answer == 42)
end
local function test_second()
  assert(helper.answer ~= 41)
end
local function test_third()
  assert(helper.answer ~= 43)
end
]]):gsub("NAME", name))))
  end
  local output = tmp .. "/both.out"
  local result = invoke_words(root, output, { "--all" })
  local text = assert(Fs.read(output))
  assert(result.ok, text)
  assert(text:find("6 ran, 0 stood", 1, true), text)
  local db = assert(Sqlite.open(support.build_dir(root) .. "/build.db"))
  local credits = assert(Sqlite.text_rows(db, "SELECT test, hits FROM coverage_by_test ORDER BY test"))
  assert(db:close())
  assert(#credits == 6, "expected a row for each of the six tests, not " .. tostring(#credits))
  for _, row in ipairs(credits) do
    local test, hits = row:text(1), row:text(2)
    local own, other = "one", "two"
    if test:find("suite.two_test", 1, true) then own, other = "two", "one" end
    assert(hits:find("suite%." .. own .. " %x+\t"), test .. " lacks its module's load: " .. hits)
    assert(not hits:find("suite." .. other .. " ", 1, true), test .. " holds another module's load: " .. hits)
  end
end

local function test_cli_fails_when_the_named_test_is_not_in_its_module(tmp: string)
  local root = project(tmp)
  local output = tmp .. "/missing.out"
  local result = invoke(root, output, "suite/selected_test.tl:test_missing")
  local text = assert(Fs.read(output))
  assert(not result.ok, text)
  assert(text:find("no test in suite.selected_test is named test_missing; " ..
      "it has test_selected\n", 1, true), text)
  assert(not text:find("no test module matches", 1, true), text)
end

local function test_cli_runs_one_example_by_its_name(tmp: string)
  local root = project(tmp)
  assert(Fs.write(root .. "/suite/answer_example.tl", [[
local record Example
end
function Example.answer()
  assert(require("suite.helper").answer == 42)
end
function Example.other()
  error("other example executed")
end
return Example
]]))
  local output = tmp .. "/example.out"
  local result = invoke(root, output, "suite/answer_example.tl:answer")
  local text = assert(Fs.read(output))
  assert(result.ok, text)
  assert(text:find("1 test passed in 1 module; 1 ran", 1, true), text)
  output = tmp .. "/prefixed.out"
  result = invoke(root, output, "suite/answer_example.tl:Example.answer")
  text = assert(Fs.read(output))
  assert(result.ok, text)
  assert(text:find("1 test passed in 1 module; 0 ran, 1 stood", 1, true), text)
end

--- A run says where its time went on a line before its summary: the tests' own time apart from what the runner
--- spent around them. A run that ran none says nothing of workers.
local function test_cli_says_where_the_time_went_before_the_summary(tmp: string)
  local root = project(tmp)
  local output = tmp .. "/ran.out"
  local result = invoke(root, output, "suite/selected_test.tl:test_selected")
  local text = assert(Fs.read(output))
  assert(result.ok, text)
  local line = "\ntest: time: building [%d.]+ s, keying [%d.]+ s, running [%d.]+ s %([%d.]+ s in 1 test, up to %d+ at a " ..
    "time; the runner [%d.]+ s starting their workers and [%d.]+ s recording them%), settling coverage and records " ..
    "[%d.]+ s\ntest: 1 test passed in 1 module; 1 ran"
  assert(text:find(line), text)
  output = tmp .. "/stood.out"
  result = invoke(root, output, "suite/selected_test.tl:test_selected")
  text = assert(Fs.read(output))
  assert(result.ok, text)
  assert(text:find("\ntest: time: building [%d.]+ s, keying [%d.]+ s, running [%d.]+ s, settling coverage and records " ..
      "[%d.]+ s\ntest: 1 test passed in 1 module; 0 ran, 1 stood"), text)
end

--- The tests the `time` line counts are those whose worker this run collected: one whose module's host lacks what it
--- requires starts none, and is in the summary's figures alone. A failing run says the line too, before its summary.
--- The module requires a path no host has, so that it starts no worker on any core: a requirement of the platform
--- (`checked`) is there on the core that has it.
local function test_cli_times_only_the_tests_whose_workers_it_collected_and_a_failing_run_too(tmp: string)
  local root = project(tmp)
  assert(Fs.write(root .. "/suite/needs_test.tl", [[
local Test = require("cosmic.test")
Test.policy {
  grants = { { path = "/cosmic-no-such-directory/absent", letters = "r" } },
  requires = { "path:/cosmic-no-such-directory/absent" },
}
local function test_needs_a_file_no_host_has()
  assert(true)
end
]]))
  local output = tmp .. "/unmet.out"
  local result = invoke_words(root, output, { "suite/selected_test.tl:test_selected", "suite/needs_test.tl" })
  local text = assert(Fs.read(output))
  assert(result.ok, text)
  assert(text:find("%([%d.]+ s in 1 test, up to %d+ at a time; [^\n]*\ntest: 2 tests passed in 2 modules; 2 ran, 0 stood, " ..
      "1 skipped"), text)
  assert(Fs.write(root .. "/suite/fails_test.tl", [[
local function test_fails()
  assert(1 + 1 == 3, "arithmetic held")
end
]]))
  output = tmp .. "/failing.out"
  result = invoke(root, output, "suite/fails_test.tl")
  text = assert(Fs.read(output))
  assert(not result.ok, text)
  assert(text:find("\ntest: time: building [%d.]+ s, keying [%d.]+ s, running [%d.]+ s %([%d.]+ s in 1 test, [^\n]*\n" ..
      "test: 1 of 1 test failed, "), text)
end

--- A failing test's report names the selector that reruns it, quoted
--- for a shell when its path needs it, on the line after its FAIL block;
--- that selector, given back to `cosmic test`, runs that one test and no
--- other.
local function test_a_failure_names_the_selector_that_reruns_it(tmp: string)
  local root = project(tmp)
  local failing = [[
local function test_unrelated()
  error("unrelated test executed")
end
local function test_sibling()
  error("sibling test executed")
end
]]
  assert(Fs.write(root .. "/suite/unrelated_test.tl", failing))
  assert(Fs.mkdirs(root .. "/suite/two words"))
  assert(Fs.write(root .. "/suite/two words/spaced_test.tl", failing))
  local output = tmp .. "/all.out"
  local result = invoke(root, output, ".")
  local text = assert(Fs.read(output))
  assert(not result.ok, text)
  local record Case
    module: string
    selector: string
    printed: string
  end
  local cases: {Case} = {
    { module = "suite.unrelated_test", selector = "suite/unrelated_test.tl:test_unrelated",
      printed = "suite/unrelated_test.tl:test_unrelated" },
    { module = "suite.two words.spaced_test",
      selector = "suite/two words/spaced_test.tl:test_unrelated",
      printed = "'suite/two words/spaced_test.tl:test_unrelated'" },
  }
  for _, case in ipairs(cases) do
    -- The FAIL line keeps its `<module> <name>: <message>` shape, and
    -- the rerun line follows its block: the message, then the kept
    -- directory.
    local block = "\ntest: FAIL  " .. case.module .. " test_unrelated: " ..
      case.module .. ":2: unrelated test executed\n  its directory is kept: "
    local at = text:find(block, 1, true)
    assert(at ~= nil, text)
    local line_end = assert(text:find("\n", at + #block, true))
    local rerun = "  rerun: COSMIC_TEST_SANDBOX=0 cosmic test " .. case.printed .. "\n"
    assert(text:sub(line_end + 1, line_end + #rerun) == rerun, text)
    output = tmp .. "/rerun.out"
    result = invoke(root, output, case.selector)
    local again = assert(Fs.read(output))
    assert(not result.ok, again)
    assert(again:find("unrelated test executed", 1, true), again)
    assert(not again:find("sibling test executed", 1, true), again)
    assert(again:find("1 of 1 test failed", 1, true), again)
  end
end

local function test_cli_fails_when_no_module_matches(tmp: string)
  for index, selector in ipairs({ "suite/missing_test.tl", "", "/" }) do
    local root = project(tmp .. "/case-" .. tostring(index))
    local output = tmp .. "/missing-" .. tostring(index) .. ".out"
    local result = invoke(root, output, selector)
    assert(not result.ok, assert(Fs.read(output)))
    local text = assert(Fs.read(output))
    assert(text:find("no test module matches:", 1, true), text)
  end
end

local function test_a_named_file_whose_module_was_refused_is_shown_the_refusal_not_a_missing_module(tmp: string)
  local root = tmp .. "/refused"
  assert(Fs.mkdirs(root))
  assert(Fs.write(root .. "/tally.tl", "local record tally\n  count: function(n: integer): integer\nend\n" ..
      "function tally.count(n: integer): integer\n  return \"x\"\nend\nreturn tally\n"))
  assert(Fs.write(root .. "/tally_test.tl",
    'local tally = require("tally")\nlocal function test_count()\n  assert(tally.count(1) == 1)\nend\n'))
  assert(Fs.write(root .. "/other.tl", 'local tally = require("tally")\nlocal record other end\nreturn other\n'))
  assert(Fs.write(root .. "/fine_test.tl", "local function test_fine()\n  assert(true)\nend\n"))
  local output = tmp .. "/refused.out"
  local result = invoke(root, output, "tally_test.tl")
  local text = assert(Fs.read(output))
  assert(not result.ok, text)
  assert(not text:find("no test module matches", 1, true), text)
  local root_at = text:find("tally.tl:5:10:", 1, true)
  local cascade_at = text:find("tally_test.tl: not compiled: it requires tally", 1, true)
  assert(root_at ~= nil and cascade_at ~= nil and root_at < cascade_at, text)
  assert(text:find("tally_test.tl did not compile", 1, true), text)
  -- Only the dependents the run named: the module nobody named is not told of.
  assert(not text:find("other.tl: not compiled", 1, true), text)
  -- A file that is no module of the tree is still missing.
  local missing = invoke(root, tmp .. "/missing.out", "nothing_test.tl")
  local missing_text = assert(Fs.read(tmp .. "/missing.out"))
  assert(not missing.ok, missing_text)
  assert(missing_text:find("no test module matches: nothing_test.tl", 1, true) ~= nil, missing_text)
end

--- What a refused module's file shows for a named run, however the module is named or reached.
local function test_a_named_run_shows_the_refusals_whichever_way_the_file_is_named_or_reached(tmp: string)
  local bad = 'local n: integer = "x"\nreturn n\n'
  local passing = "local function test_it()\n  assert(true)\nend\n"
  local record Case
    name: string
    files: {string:string}
    selector: string
    shown: {string}
    absent?: {string}
  end
  local cases: {Case} = {
    { name = "module", files = { ["pkg/x.tl"] = bad,
      ["pkg/x_test.tl"] = 'local x = require("pkg.x")\nlocal function test_it()\n  assert(x == 1)\nend\n' },
      selector = "pkg.x_test",
      shown = { "pkg/x.tl:1:", "pkg/x_test.tl: not compiled" } },
    { name = "chain", files = { ["c.tl"] = bad, ["b.tl"] = 'local c = require("c")\nreturn c\n',
      ["a_test.tl"] = 'local b = require("b")\n' .. passing }, selector = "a_test.tl",
      shown = { "c.tl:1:", "a_test.tl: not compiled" }, absent = { "b.tl: not compiled" } },
    { name = "itself", files = { ["a_test.tl"] = "local n: integer = \"x\"\n" .. passing }, selector = "a_test.tl",
      shown = { "a_test.tl:1:", "a_test.tl did not compile" } },
    { name = "parse", files = { ["a_test.tl"] = "local function test_it(\n" }, selector = "a_test.tl",
      shown = { "a_test.tl", "a_test.tl did not compile" } },
  }
  for _, case in ipairs(cases) do
    local root = tmp .. "/" .. case.name
    for file, source in pairs(case.files) do
      assert(Fs.mkdirs(Fs.dirname(root .. "/" .. file)))
      assert(Fs.write(root .. "/" .. file, source))
    end
    local output = tmp .. "/" .. case.name .. ".out"
    local result = invoke(root, output, case.selector)
    local text = assert(Fs.read(output))
    assert(not result.ok, text)
    assert(not text:find("no test module matches", 1, true), case.name .. ": " .. text)
    local at = 0
    for _, word in ipairs(case.shown) do
      local found = text:find(word, 1, true)
      assert(found ~= nil and found > at, case.name .. ": " .. word .. " in order in: " .. text)
      at = found
    end
    local absent = case.absent
    if absent == nil then absent = {} end
    for _, word in ipairs(absent) do
      assert(not text:find(word, 1, true), case.name .. ": " .. text)
    end
  end
end

--- `runs.elapsed_ns` is how long the test function took, not merely a
--- value: a test that sleeps 50 ms is recorded as taking at least that,
--- and well under 5 s.
local function test_records_the_tests_elapsed_duration(tmp: string)
  local root = tmp .. "/project"
  assert(Fs.mkdirs(root .. "/timing"))
  assert(Fs.write(root .. "/timing/sleep_test.tl", [[
local Clock = require("cosmic.clock")
local function test_sleeps_a_known_duration()
  assert(Clock.sleep_ns(50 * 1000 * 1000))
end
]]))
  local output = tmp .. "/sleep.out"
  local result = invoke(root, output, "timing/sleep_test.tl")
  assert(result.ok, assert(Fs.read(output)))
  local db = assert(Sqlite.open(support.build_dir(root) .. "/build.db"))
  local rows = assert(Sqlite.text_rows(db,
    "SELECT elapsed_ns FROM runs WHERE path = 'timing.sleep_test' " ..
      "AND test = 'test_sleeps_a_known_duration'"))
  assert(db:close())
  assert(#rows == 1, "expected exactly one recorded run")
  local elapsed = math.tointeger(tonumber(rows[1]:text(1)))
  assert(elapsed ~= nil)
  assert(elapsed >= Clock.ms(50),
    "elapsed_ns " .. tostring(elapsed) .. " is shorter than the sleep")
  assert(elapsed < Clock.seconds(5),
    "elapsed_ns " .. tostring(elapsed) .. " is implausibly large")
end

--- The project's root names every test, written relative or absolute: "." as [`test.matches`] reads it
--- (build/test_test.tl holds its other spellings), and the root's own path, with a slash after it, as the command line
--- resolves one.
local function test_cli_accepts_relative_and_absolute_project_root(tmp: string)
  for index, selector in ipairs({ ".", "absolute-slash" }) do
    local root = project(tmp .. "/case-" .. tostring(index))
    assert(Fs.write(root .. "/suite/unrelated_test.tl", [[
local function test_unrelated()
  assert(true)
end
]]))
    local argument = if selector == "." then "." else root .. "/" end
    local output = tmp .. "/" .. selector .. ".out"
    local result = invoke(root, output, argument)
    assert(result.ok, assert(Fs.read(output)))
    local text = assert(Fs.read(output))
    assert(text:find("2 ran, 0 stood", 1, true), text)
  end
end

local function test_another_project_counts_none_of_the_cores_c(tmp: string)
  local root = project(tmp)
  local output = tmp .. "/project.out"
  local result = invoke(root, output, "suite/selected_test.tl")
  assert(result.ok, assert(Fs.read(output)))
  local db = assert(Sqlite.open(support.build_dir(root) .. "/build.db"))
  local lines = assert(Sqlite.text_rows(db,
    "SELECT COUNT(*) FROM coverage WHERE path LIKE 'core/%'"))
  local credits = assert(Sqlite.text_rows(db,
    "SELECT COUNT(*) FROM coverage_by_test WHERE hits LIKE '%core/%'"))
  assert(db:close())
  assert(support.nth(lines, 1):text(1) == "0", support.nth(lines, 1):text(1) .. " coverage rows name the core's C")
  assert(support.nth(credits, 1):text(1) == "0", support.nth(credits, 1):text(1) .. " tests are credited the core's C")
end

--- A test whose directory cannot be made fails as that test's own
--- failure, and the run reports it rather than ending on it.
local function test_a_test_without_a_directory_fails_alone(tmp: string)
  local root = project(tmp)
  local output = tmp .. "/nowhere.out"
  local environment = this_program.environment()
  environment["TMPDIR"] = tmp .. "/missing"
  -- Unsandboxed, as `invoke` runs one: the directory is made before a
  -- worker starts, sandboxed or not.
  environment["COSMIC_TEST_SANDBOX"] = "0"
  local fd = assert(Fs.open_write(output))
  local started = this_program.program({ "test", "suite/selected_test.tl" }, {
    cwd = root, env = environment, stdout = fd, stderr = fd, timeout_ns = Clock.seconds(30),
  })
  local result = assert(Child.run(started.argv, started.options))
  assert(Fs.close(fd))
  local text = assert(Fs.read(output))
  assert(not result.ok, text)
  assert(text:find("could not make a temporary directory", 1, true), text)
  assert(not text:find("attempt to perform arithmetic", 1, true), text)
end

--- The shares of `--shard I/N`, each run in a checkout of its own as
--- CI's runners do, run every chosen test once between them, and the
--- one that holds a failing test fails as a whole run would; a share
--- that names no share is refused.
local function test_the_shares_of_a_run_run_each_test_once(tmp: string)
  local function shard_project(at: string): string
    local root = at .. "/project"
    assert(Fs.mkdirs(root .. "/suite"))
    assert(Fs.write(root .. "/suite/a_test.tl", [[
local function test_one() end
local function test_two() end
local function test_three() end
]]))
    assert(Fs.write(root .. "/suite/b_test.tl", [[
local function test_four() end
local function test_five()
  error("the failing test ran")
end
]]))
    return root
  end
  local seen: mut {string:integer} = {}
  local failed = 0
  for index = 1, 2 do
    local at = tmp .. "/share-" .. tostring(index)
    local root = shard_project(at)
    local output = at .. "/run.out"
    local result = invoke_words(root, output, { "--shard", tostring(index) .. "/2" })
    local text = assert(Fs.read(output))
    assert(text:find("; shard " .. tostring(index) .. " of 2\n", 1, true), text)
    if text:find("the failing test ran", 1, true) then
      failed = failed + 1
      assert(not result.ok and text:find("test: 1 of ", 1, true) ~= nil, text)
    else
      assert(result.ok, text)
    end
    local db = assert(Sqlite.open(support.build_dir(root) .. "/build.db"))
    local rows = assert(Sqlite.text_rows(db, "SELECT path, test FROM runs"))
    assert(db:close())
    for _, row in ipairs(rows) do
      local id = row:text(1) .. " " .. row:text(2)
      seen[id] = (seen[id] or 0) + 1
    end
  end
  assert(failed == 1, "the failing test failed " .. tostring(failed) .. " shares")
  local ids: mut {string} = {}
  for id, count in pairs(seen) do
    assert(count == 1, id .. " ran in " .. tostring(count) .. " shares")
    ids[#ids + 1] = id
  end
  table.sort(ids)
  assert(table.concat(ids, ",") == table.concat({
    "suite.a_test test_one", "suite.a_test test_three", "suite.a_test test_two",
    "suite.b_test test_five", "suite.b_test test_four" }, ","), table.concat(ids, ","))
  for _, refused in ipairs({ "3/2", "0/2", "1", "1/0", "a/b" }) do
    local root = shard_project(tmp .. "/refused-" .. refused:gsub("/", "-"))
    local output = tmp .. "/refused-" .. refused:gsub("/", "-") .. ".out"
    local result = invoke_words(root, output, { "--shard", refused })
    local text = assert(Fs.read(output))
    assert(not result.ok and result.code == 2, text)
    assert(text:find("--shard must be I/N", 1, true), text)
  end
end

--- A project of a module `tally.tl` the checker refuses (`bad`) or accepts, its test `tally_test.tl`, a test `fine_test.tl`
--- that passes or fails (`failing`) and a module `lone.tl` nothing requires that the checker refuses (`lone_bad`).
local function status_project(root: string, bad: boolean, failing: boolean, lone_bad: boolean)
  assert(Fs.mkdirs(root))
  assert(Fs.write(root .. "/tally.tl", "local record tally\n  count: function(n: integer): integer\nend\n" ..
      "function tally.count(n: integer): integer\n  return " .. (if bad then '"x"' else "n" end) .. "\nend\nreturn tally\n"))
  assert(Fs.write(root .. "/tally_test.tl",
    'local tally = require("tally")\nlocal function test_count()\n  assert(tally.count(1) == 1)\nend\n'))
  assert(Fs.write(root .. "/fine_test.tl",
    "local function test_fine()\n  assert(" .. (if failing then "false" else "true" end) .. ")\nend\n"))
  assert(Fs.write(root .. "/lone.tl", "local n: integer = " .. (if lone_bad then '"x"' else "1" end) .. "\nreturn n\n"))
end

--- A mutation-testing script tells a mutant the checker refused from one a test killed by the exit status: 4 when the tree, or
--- a module a named run needs, did not compile, whatever else failed with it, and 1 for a test that fails. One case for each
--- place the status is decided: the summary of a whole run, with every test passing and with one failing, and of a named
--- one; a named run a refusal elsewhere leaves alone; a tree that stops at its compile; and a name that matches nothing.
--- Which refusals a named run fails for is build/test_test.tl's ([`test.refusals_of`]).
local function test_a_tree_that_does_not_compile_exits_4_and_a_failing_test_exits_1(tmp: string)
  local record Case
    name: string
    words: {string}
    code: integer
    bad?: boolean
    failing?: boolean
    lone?: boolean
    cycle?: boolean
  end
  local cases: {Case} = {
    { name = "refused", words = {}, code = 4, bad = true },
    { name = "refused-and-failing", words = {}, code = 4, bad = true, failing = true },
    { name = "named-cascade-and-failing", words = { "tally_test.tl", "fine_test.tl" }, code = 4, bad = true, failing = true },
    { name = "named-unaffected-by-a-refusal-elsewhere", words = { "fine_test.tl" }, code = 1, lone = true, failing = true },
    { name = "cycle", words = {}, code = 4, cycle = true },
    { name = "named-absent", words = { "nothing_test.tl" }, code = 1 },
  }
  for _, case in ipairs(cases) do
    local root = tmp .. "/" .. case.name
    status_project(root, case.bad == true, case.failing == true, case.lone == true)
    if case.cycle == true then
      assert(Fs.write(root .. "/ping.tl", 'local pong = require("pong")\nreturn pong\n'))
      assert(Fs.write(root .. "/pong.tl", 'local ping = require("ping")\nreturn ping\n'))
    end
    local output = tmp .. "/" .. case.name .. ".out"
    local result = invoke_words(root, output, case.words)
    assert(result.code == case.code, case.name .. ": exit " .. tostring(result.code) .. ": " .. assert(Fs.read(output)))
  end
end
