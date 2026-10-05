--- A test worker lets its tests `require` of the tree only the modules
--- their module's import closure holds ([`build.test_inputs`]'
--- `modules`): the build follows a `require` of a literal name alone,
--- so a module reached another way is one a change to would not run
--- the test again. The core's own modules, which no file of the tree
--- is, load as ever. Those cases that run `cosmic test` on a project of
--- their own are in build/test_closure_tool_test.tl.

local test_inputs = require("build.test_inputs")

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
--- [`build.dispatch`], the program's entry, which starts the worker and
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
