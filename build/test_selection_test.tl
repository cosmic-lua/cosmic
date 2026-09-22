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
  return assert(result, trouble)
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
