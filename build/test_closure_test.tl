--- A test worker lets its tests `require` of the tree only the modules
--- their module's import closure holds ([`build.test_inputs`]'
--- `modules`): the build follows a `require` of a literal name alone,
--- so a module reached another way is one a change to would not run
--- the test again. The core's own modules, which no file of the tree
--- is, load as ever. Those cases that run `cosmic test` on a project of
--- their own are in build/test_closure_tool_test.tl.

local test_inputs = require("build.test_inputs")

--- A `require` of `first` and `second` joined by a dot at run time. The parser refuses a computed name in a typed file
--- (`computed_require`), so the call is made from a chunk of Lua; the worker's hold is what stops one that gets past it.
local function dynamic_require(first: string, second: string): any
  local chunk = assert(load("return require((...))", "=dynamic_require"))
  local value: any = chunk(first .. "." .. second)
  return value
end

--- A module of the tree this module never requires by a literal name,
--- nor anything it requires, is refused, naming it and the module
--- whose closure it is outside. A test module is one: no module
--- requires one.
local function test_a_module_of_the_tree_outside_the_closure_is_refused()
  local ok, why = pcall(dynamic_require, "build", "flow_test")
  assert(not ok, "build.flow_test loaded")
  local text = tostring(why)
  assert(text:find("module 'build.flow_test' is outside the import closure of " ..
      "build.test_closure_test", 1, true), text)
  assert(text:find("a name computed at run time is not followed", 1, true), text)
  assert(text:find('or of build.test_closure_test itself: ' ..
      'local _ = require("build.flow_test")', 1, true), text)
end

--- A module the worker loaded for itself is no way around it:
--- [`build.dispatch`], the program's entry, which starts the worker and
--- which no test's closure holds.
local function test_a_module_the_worker_loaded_is_refused_too()
  local ok, why = pcall(dynamic_require, "build", "dispatch")
  assert(not ok, "build.dispatch loaded")
  assert(tostring(why):find("module 'build.dispatch' is outside the import closure",
    1, true), tostring(why))
end

--- A module of the closure loads by any name, as the one table its
--- literal `require` answered.
local function test_a_module_of_the_closure_loads()
  assert(dynamic_require("build", "test_inputs") == test_inputs)
end

--- A module of the core, which no file of the tree is, loads.
local function test_a_module_of_the_core_loads()
  local sys: any = dynamic_require("cosmic", "sys")
  assert(sys is {string:any} and sys.getpid ~= nil)
end
