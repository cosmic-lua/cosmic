--- CLI coverage for test-module selection. The child project contains an
--- unrelated failing test, so a passing selected run proves it was not loaded.

local Child = require("cosmic.child")
local Fs = require("cosmic.fs")
local Proc = require("cosmic.proc")
local Sqlite = require("cosmic.sqlite")
local observations = require("build.filesystem_observations")

-- What these tests start is this very program.
observations.confine({ reads = observations.itself() })

local function invoke(program: string, root: string, output: string,
    selector: string): Child.Result
  local fd = assert(Fs.open_write(output))
  local result, trouble = Child.run({ program, "test", selector }, {
    cwd = root, env = observations.environment(), stdout = fd, stderr = fd,
    process_group = true, timeout_ms = 30000,
  })
  assert(Fs.close(fd))
  return (assert(result, trouble))
end

local function project(tmp: string): string
  local root = tmp .. "/project"
  assert(Fs.mkdirs(root .. "/suite"))
  assert(Fs.write(root .. "/suite/helper.tl", [[
return { answer = 42 }
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
  local program = assert(Proc.executable())
  local root = project(tmp)
  local output = tmp .. "/selected.out"
  local result = invoke(program, root, output, "suite/selected_test.tl")
  assert(result.ok, assert(Fs.read(output)))
  local text = assert(Fs.read(output))
  assert(text:find("1 ran, 0 stood", 1, true), text)
  assert(not text:find("unrelated test executed", 1, true), text)
  local db = assert(Sqlite.open(root .. "/o/build.db", false))
  local rows = assert(Sqlite.text_rows(db,
    "SELECT COUNT(*) FROM coverage WHERE path = 'suite.helper'"))
  assert(db:close())
  assert(rows[1][1] ~= "0", "selected run omitted dependency coverage")
end

local function test_a_standing_verdict_still_credits_its_coverage(tmp: string)
  local program = assert(Proc.executable())
  local root = project(tmp)
  for run, expected in ipairs({ "1 ran, 0 stood", "0 ran, 1 stood" }) do
    local output = tmp .. "/run-" .. tostring(run) .. ".out"
    local result = invoke(program, root, output, "suite/selected_test.tl")
    local text = assert(Fs.read(output))
    assert(result.ok, text)
    assert(text:find(expected, 1, true), text)
  end
  local db = assert(Sqlite.open(root .. "/o/build.db", false))
  local by_run = assert(Sqlite.text_rows(db,
    "SELECT SUM(hit) FROM coverage WHERE path = 'suite.helper' " ..
    "GROUP BY ran_at_ns ORDER BY ran_at_ns"))
  local credits = assert(Sqlite.text_rows(db,
    "SELECT test, hits FROM coverage_by_test"))
  assert(db:close())
  assert(#by_run == 2, "expected a coverage snapshot per run")
  assert(by_run[1][1] ~= "0" and by_run[2][1] == by_run[1][1],
    "the standing run credited " .. by_run[2][1] .. " lines, not " .. by_run[1][1])
  assert(#credits == 1, "expected one coverage_by_test row for the one test")
  assert(credits[1][2]:find("suite.helper\t", 1, true), credits[1][2])
end

local function test_cli_runs_only_the_one_test_a_selector_names(tmp: string)
  local program = assert(Proc.executable())
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
    local result = invoke(program, root, output, "./suite/selected_test.tl:test_selected")
    local text = assert(Fs.read(output))
    assert(result.ok, text)
    assert(text:find("1 tests, 1 modules; " .. expected, 1, true), text)
    assert(not text:find("executed", 1, true), text)
  end
  local output = tmp .. "/module.out"
  local result = invoke(program, root, output, "suite.selected_test:test_selected")
  local text = assert(Fs.read(output))
  assert(result.ok, text)
  assert(text:find("0 ran, 1 stood", 1, true), text)
  local db = assert(Sqlite.open(root .. "/o/build.db", false))
  local credits = assert(Sqlite.text_rows(db, "SELECT test FROM coverage_by_test"))
  assert(db:close())
  assert(#credits == 1 and credits[1][1] == "suite.selected_test test_selected",
    "expected only the named test credited")
end

local function test_cli_fails_when_the_named_test_is_not_in_its_module(tmp: string)
  local program = assert(Proc.executable())
  local root = project(tmp)
  local output = tmp .. "/missing.out"
  local result = invoke(program, root, output, "suite/selected_test.tl:test_missing")
  local text = assert(Fs.read(output))
  assert(not result.ok, text)
  assert(text:find("no test in suite.selected_test is named test_missing; " ..
    "it has test_selected\n", 1, true), text)
  assert(not text:find("no test module matches", 1, true), text)
end

local function test_cli_runs_one_example_by_its_name(tmp: string)
  local program = assert(Proc.executable())
  local root = project(tmp)
  assert(Fs.write(root .. "/suite/answer_example.tl", [[
local Example = {}
function Example.answer()
  assert(require("suite.helper").answer == 42)
end
function Example.other()
  error("other example executed")
end
return Example
]]))
  local output = tmp .. "/example.out"
  local result = invoke(program, root, output, "suite/answer_example.tl:answer")
  local text = assert(Fs.read(output))
  assert(result.ok, text)
  assert(text:find("1 tests, 1 modules; 1 ran", 1, true), text)
  output = tmp .. "/prefixed.out"
  result = invoke(program, root, output, "suite/answer_example.tl:Example.answer")
  text = assert(Fs.read(output))
  assert(result.ok, text)
  assert(text:find("1 tests, 1 modules; 0 ran, 1 stood", 1, true), text)
end

--- A failing test's report names the selector that reruns it, quoted
--- for a shell when its path needs it, on the line after its FAIL block;
--- that selector, given back to `cosmic test`, runs that one test and no
--- other.
local function test_a_failure_names_the_selector_that_reruns_it(tmp: string)
  local program = assert(Proc.executable())
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
  local result = invoke(program, root, output, ".")
  local text = assert(Fs.read(output))
  assert(not result.ok, text)
  for _, case in ipairs({
    { module = "suite.unrelated_test", selector = "suite/unrelated_test.tl:test_unrelated",
      printed = "suite/unrelated_test.tl:test_unrelated" },
    { module = "suite.two words.spaced_test",
      selector = "suite/two words/spaced_test.tl:test_unrelated",
      printed = "'suite/two words/spaced_test.tl:test_unrelated'" },
  }) do
    -- The FAIL line keeps its `<module> <name>: <message>` shape, and
    -- the rerun line follows its block: the message, then the kept
    -- directory.
    local block = "\ntest: FAIL  " .. case.module .. " test_unrelated: " ..
      case.module .. ":2: unrelated test executed\n  its directory is kept: "
    local at = text:find(block, 1, true)
    assert(at ~= nil, text)
    local line_end = assert(text:find("\n", at + #block, true))
    local rerun = "  rerun: cosmic test " .. case.printed .. "\n"
    assert(text:sub(line_end + 1, line_end + #rerun) == rerun, text)
    output = tmp .. "/rerun.out"
    result = invoke(program, root, output, case.selector)
    local again = assert(Fs.read(output))
    assert(not result.ok, again)
    assert(again:find("unrelated test executed", 1, true), again)
    assert(not again:find("sibling test executed", 1, true), again)
    assert(again:find("1 of 1 failed", 1, true), again)
  end
end

local function test_cli_fails_when_no_module_matches(tmp: string)
  local program = assert(Proc.executable())
  for index, selector in ipairs({ "suite/missing_test.tl", "", "/" }) do
    local root = project(tmp .. "/case-" .. tostring(index))
    local output = tmp .. "/missing-" .. tostring(index) .. ".out"
    local result = invoke(program, root, output, selector)
    assert(not result.ok, assert(Fs.read(output)))
    local text = assert(Fs.read(output))
    assert(text:find("no test module matches:", 1, true), text)
  end
end

--- Regression: `runs.elapsed_ns` must reflect how long the test function
--- itself actually took, not merely be present. A test that sleeps a known
--- short duration must be recorded as having taken at least that long, and
--- comfortably less than a generous upper bound.
local function test_records_the_tests_elapsed_duration(tmp: string)
  local program = assert(Proc.executable())
  local root = tmp .. "/project"
  assert(Fs.mkdirs(root .. "/timing"))
  assert(Fs.write(root .. "/timing/sleep_test.tl", [[
local Time = require("cosmic.time")
local function test_sleeps_a_known_duration()
  assert(Time.sleep_ns(50 * 1000 * 1000))
end
]]))
  local output = tmp .. "/sleep.out"
  local result = invoke(program, root, output, "timing/sleep_test.tl")
  assert(result.ok, assert(Fs.read(output)))
  local db = assert(Sqlite.open(root .. "/o/build.db", false))
  local rows = assert(Sqlite.text_rows(db,
    "SELECT elapsed_ns FROM runs WHERE path = 'timing.sleep_test' " ..
    "AND test = 'test_sleeps_a_known_duration'"))
  assert(db:close())
  assert(#rows == 1, "expected exactly one recorded run")
  local elapsed = math.tointeger(tonumber(rows[1][1]))
  assert(elapsed ~= nil)
  assert(elapsed >= 50 * 1000 * 1000,
    "elapsed_ns " .. tostring(elapsed) .. " is shorter than the sleep")
  assert(elapsed < 5 * 1000 * 1000 * 1000,
    "elapsed_ns " .. tostring(elapsed) .. " is implausibly large")
end

local function test_cli_accepts_relative_and_absolute_project_root(tmp: string)
  local program = assert(Proc.executable())
  for index, selector in ipairs({ ".", "./", "absolute", "absolute-slash" }) do
    local root = project(tmp .. "/case-" .. tostring(index))
    assert(Fs.write(root .. "/suite/unrelated_test.tl", [[
local function test_unrelated()
  assert(true)
end
]]))
    local argument = selector == "." and "." or
      selector == "./" and "./" or
      selector == "absolute" and root or root .. "/"
    local output = tmp .. "/" .. selector .. ".out"
    local result = invoke(program, root, output, argument)
    assert(result.ok, assert(Fs.read(output)))
    local text = assert(Fs.read(output))
    assert(text:find("2 ran, 0 stood", 1, true), text)
  end
end

local function test_another_project_counts_none_of_the_cores_c(tmp: string)
  local program = assert(Proc.executable())
  local root = project(tmp)
  local output = tmp .. "/project.out"
  local result = invoke(program, root, output, "suite/selected_test.tl")
  assert(result.ok, assert(Fs.read(output)))
  local db = assert(Sqlite.open(root .. "/o/build.db", false))
  local lines = assert(Sqlite.text_rows(db,
    "SELECT COUNT(*) FROM coverage WHERE path LIKE 'core/%'"))
  local credits = assert(Sqlite.text_rows(db,
    "SELECT COUNT(*) FROM coverage_by_test WHERE hits LIKE '%core/%'"))
  assert(db:close())
  assert(lines[1][1] == "0", lines[1][1] .. " coverage rows name the core's C")
  assert(credits[1][1] == "0", credits[1][1] .. " tests are credited the core's C")
end

--- A test whose directory cannot be made fails as that test's own
--- failure, and the run reports it rather than ending on it.
local function test_a_test_without_a_directory_fails_alone(tmp: string)
  local root = project(tmp)
  local output = tmp .. "/nowhere.out"
  local environment = observations.environment()
  environment.TMPDIR = tmp .. "/missing"
  local fd = assert(Fs.open_write(output))
  local result = assert(Child.run({ assert(Proc.executable()), "test", "suite/selected_test.tl" }, {
    cwd = root, env = environment, stdout = fd, stderr = fd, timeout_ms = 30000,
  }))
  assert(Fs.close(fd))
  local text = assert(Fs.read(output))
  assert(not result.ok, text)
  assert(text:find("could not make a temporary directory", 1, true), text)
  assert(not text:find("attempt to perform arithmetic", 1, true), text)
end
