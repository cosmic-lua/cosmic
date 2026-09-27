--- A test worker lets its tests `require` of the tree only the modules
--- their module's import closure holds (`build.test_inputs`'
--- `modules`): the build follows a `require` of a literal name alone,
--- so a module reached another way is one a change to would not run
--- the test again. The core's own modules, which no file of the tree
--- is, load as ever.

local Child = require("cosmic.child")
local Fs = require("cosmic.fs")
local Proc = require("cosmic.proc")
local observations = require("build.filesystem_observations")
local test_inputs = require("build.test_inputs")
local Test = require("cosmic.test")

--- What these tests start is this very program, which runs the
--- tool's own modules besides the closure's.
Test.needs{ tool = true }

-- What these tests start is this very program.
observations.confine({ reads = observations.itself() })

--- `name` built at run time, so the build cannot follow it.
local function computed(...: string): string
  return table.concat({ ... }, ".")
end

--- A module of the tree this module never requires by a literal name,
--- nor anything it requires, is refused, naming it and the module
--- whose closure it is outside. A test module is one: no module
--- requires one.
local function test_a_module_of_the_tree_outside_the_closure_is_refused()
  local ok, why = pcall(require, computed("build", "flow_test"))
  assert(not ok, "build.flow_test loaded")
  local text = tostring(why)
  assert(text:find("module 'build.flow_test' is outside the import closure of " ..
    "build.test_closure_test", 1, true), text)
  assert(text:find("nor pcall(require, ...) is followed", 1, true), text)
  assert(text:find('or of build.test_closure_test itself: ' ..
    'local _ = require("build.flow_test")', 1, true), text)
end

--- A module the worker loaded for itself is no way around it:
--- `build.dispatch`, the program's entry, which starts the worker and
--- which no test's closure holds.
local function test_a_module_the_worker_loaded_is_refused_too()
  local ok, why = pcall(require, computed("build", "dispatch"))
  assert(not ok, "build.dispatch loaded")
  assert(tostring(why):find("module 'build.dispatch' is outside the import closure",
    1, true), tostring(why))
end

--- A module of the closure loads by any name, as the one table its
--- literal `require` answered.
local function test_a_module_of_the_closure_loads()
  assert(require(computed("build", "test_inputs")) == test_inputs)
end

--- A module of the core, which no file of the tree is, loads.
local function test_a_module_of_the_core_loads()
  local sys: any = require(computed("cosmic", "sys"))
  assert(sys is {string:any} and sys.getpid ~= nil)
end

--- Runs `cosmic test` on `root`, answering whether it passed and what
--- it printed.
local function run(root: string, output: string): boolean, string
  local fd = assert(Fs.open_write(output))
  local result, trouble = Child.run({ assert(Proc.executable()), "test" }, {
    cwd = root, env = observations.environment(), stdout = fd, stderr = fd,
    process_group = true, timeout_ms = 60000,
  })
  assert(Fs.close(fd))
  local text = assert(Fs.read(output))
  assert(result ~= nil, tostring(trouble) .. text)
  return result.ok, text
end

--- In a project of its own, a test that requires its helper by a
--- computed name fails, naming it; one that requires it by a literal
--- name passes, and so does a computed require of the standard
--- library, which the binary carries rather than the project's tree.
local function test_a_project_test_requiring_outside_its_closure_fails(tmp: string)
  local root = tmp .. "/project"
  assert(Fs.mkdirs(root .. "/suite"))
  assert(Fs.write(root .. "/suite/helper.tl", "return { answer = 42 }\n"))
  assert(Fs.write(root .. "/suite/static_test.tl", table.concat({
    'local helper = require("suite.helper")',
    "local function test_static()",
    "  assert(helper.answer == 42)",
    "end",
  }, "\n") .. "\n"))
  assert(Fs.write(root .. "/suite/dynamic_test.tl", table.concat({
    'local name = "suite." .. "helper"',
    "local function test_dynamic()",
    "  local helper: any = require(name)",
    "  assert(helper ~= nil)",
    "end",
    "local function test_standard_library()",
    '  local json: any = require("cosmic." .. "json")',
    "  assert(json ~= nil)",
    "end",
  }, "\n") .. "\n"))
  local ok, text = run(root, tmp .. "/run.out")
  assert(not ok, text)
  assert(text:find("test: FAIL  suite.dynamic_test test_dynamic: suite.dynamic_test:3: " ..
    "module 'suite.helper' is outside the import closure of suite.dynamic_test", 1, true), text)
  assert(text:find("(1 of 3 failed", 1, true), text)
end
