--- [`cosmic.test`]'s `skip`, in this process. What its `policy` takes is
--- cosmic/test_policy_test.tl's; what the build holds a declaration to, in
--- build/analyzer_test.tl.

local Child = require("cosmic.child")
local Test = require("cosmic.test")
local test_child = require("build.test_child")
local this_program = require("build.this_program")

--- The program itself, which the policy test below starts again, past its launcher.
Test.policy{ profiles = { "cosmic" } }

--- `skip` takes a reason: none, or an empty one, raises before the test
--- is counted skipped, so this test, which passes, is not.
local function test_skip_takes_a_reason()
  local ok, trouble: boolean, any = pcall(Test.skip, "")
  assert(not ok and tostring(trouble):find("test: skip's reason is empty", 1, true), tostring(trouble))
end

--- `module`'s table, whose fields a runner installs, as its untyped self.
local function fields_of(module: any): {string:any}
  if module is {string:any} then return module end
  return nil
end

--- `skip` records its reason with the runner and raises what the runner
--- answers, so the test ends there. Run under a stand-in runner, put back
--- as it was: this test's own runner would otherwise take the raise.
local function test_skip_raises_what_the_runner_answers()
  local ending: {string:string} = {}
  local given: mut {string} = {}
  local fake: {string:any} = {
    loaded = true,
    skipped = function(reason: string): {string:string}
      given[#given + 1] = reason
      return ending
    end,
  }
  local module = fields_of(Test)
  local own = module.__runner
  module.__runner = fake
  local ok, raised: boolean, any = pcall(Test.skip, "no kernel")
  module.__runner = own
  assert(not ok and raised == ending, tostring(raised))
  assert(#given == 1 and given[1] == "no kernel")
end

--- The child of the test below: a process of its own, in which this module's top level has run, and its `policy` with it.
--- It requires a module that calls `policy` too, as a test module must never, and prints what that was told.
test_child.register("policy", function(_args: {string}): integer
  local ok, why: boolean, any = pcall(require, "cosmic.test_policy_twice_test")
  print(tostring(ok) .. " " .. (tostring(why):gsub("^.-: test: ", "")))
  return 0
end)

--- `policy` is refused, saying where the first call was made, for a second.
local function test_policy_is_called_once(tmp: string)
  local started = this_program.program(test_child.words(tmp, "cosmic.test_test", "policy"),
    { stdout = "capture", stderr = "stdout", timeout_ns = 60000000000 })
  local result = assert(Child.run(started.argv, started.options))
  assert(result.code == 0, result.stdout)
  assert((result.stdout or ""):match("^false policy is called once, and .-:%d+ called it already; " ..
      "a test module never requires another that calls it\n$") ~= nil, result.stdout)
end

--- `policy` is refused once the module has loaded: the worker has told the runner, as it does for every test. Which
--- fields it translates, and how a build reads it, are cosmic/test_policy_test.tl's.
local function test_policy_is_called_at_the_top_of_a_test_module_while_it_loads()
  local ok, why: boolean, any = pcall(require, "cosmic.test_policy_twice_test")
  assert(not ok, "the policy of a module required after the load was taken")
  assert(tostring(why):find("test: policy is called at the top of a test module, while it loads", 1, true) ~= nil,
    tostring(why))
end
