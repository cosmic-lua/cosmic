local Child = require("cosmic.child")
local Clock = require("cosmic.clock")
local Fs = require("cosmic.fs")
local Test = require("cosmic.test")
local paths = require("build.paths")
local this_program = require("build.this_program")
local type _ = require("build.standalone")

Test.policy{ profiles = { "cosmic" }, grants = { { path = "build/paths.tl", letters = "r" } } }

local function test_resolution_makes_nothing(tmp: string)
  local root = tmp .. "/project"
  local directory, trouble = paths.directory(root, {})
  assert(directory == root .. "/o", trouble)
  assert(paths.required(root, {}) == directory)
  local present = assert(Fs.list(tmp))
  assert(#present == 0, "resolving output created a directory")
end

local function test_bootstrap_and_runtime_resolve_the_same_directory(tmp: string)
  local script = tmp .. "/paths.tl"
  assert(Fs.write(script, (assert(Fs.read("build/paths.tl")))))
  local root = tmp .. "/project"
  local started = this_program.program({ "--standalone", script, root }, {
    cwd = tmp, env = {}, stdout = "capture", stderr = "capture",
    timeout_ns = Clock.seconds(30),
  })
  local result = assert(Child.run(started.argv, started.options))
  assert(result.ok, tostring(result.stderr))
  assert(result.stdout == paths.required(root, {}) .. "\n", tostring(result.stdout))
  assert(Fs.exists(root) == false, "bootstrap resolution created the project")
end

local function test_bootstrap_refuses_missing_and_extra_roots(tmp: string)
  local script = tmp .. "/paths.tl"
  assert(Fs.write(script, (assert(Fs.read("build/paths.tl")))))
  for _, words in ipairs({ {}, { tmp, tmp } } as {{string}}) do
    local argv = { "--standalone", script }
    for _, word in ipairs(words) do argv[#argv + 1] = word end
    local started = this_program.program(argv, {
      env = {}, stdout = "capture", stderr = "capture", timeout_ns = Clock.seconds(30),
    })
    local result = assert(Child.run(started.argv, started.options))
    assert(result.code == 2, tostring(result.stderr))
    assert(result.stdout == "", tostring(result.stdout))
    assert(tostring(result.stderr):find("usage:", 1, true) ~= nil, tostring(result.stderr))
  end
end

local function test_an_empty_project_root_is_refused()
  local directory, trouble = paths.directory("", {})
  assert(directory == nil and trouble == "project root is empty", trouble)
  local ok, raised = pcall(paths.required, "", {})
  assert(not ok and raised == trouble, tostring(raised))
end
