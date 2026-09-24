--- CLI coverage for test-module selection. The child project contains an
--- unrelated failing test, so a passing selected run proves it was not loaded.

local Child = require("cosmic.child")
local Env = require("cosmic.env")
local Fs = require("cosmic.fs")
local Proc = require("cosmic.proc")
local Sqlite = require("cosmic.sqlite")

local function invoke(program: string, root: string, output: string,
    selector: string): Child.Result
  local fd = assert(Fs.open_write(output))
  local result, trouble = Child.run({ program, "test", selector }, {
    cwd = root, env = Env.all(), stdout = fd, stderr = fd,
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
