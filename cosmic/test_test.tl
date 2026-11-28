--- [`cosmic.test`]'s `skip`, in this process. What its `policy` takes is
--- cosmic/test_policy_test.tl's; what the build holds a declaration to, in
--- build/analyzer_test.tl.

local Child = require("cosmic.child")
local Test = require("cosmic.test")
local test_child = require("build.test_child")

--- The program itself, which the policy test below starts again, past its launcher.
Test.policy{ profiles = { "cosmic" } }

--- `skip` takes a reason: none, or an empty one, raises before the test
--- is counted skipped, so this test, which passes, is not.
local function test_skip_takes_a_reason()
  Test.raises(function() Test.skip("") end, "test: skip's reason is empty")
end

--- `raises` returns the message of a call that raises, whole, and refuses
--- (naming what it expected) a call that returns or says something else.
local function test_raises_answers_the_message_and_refuses_otherwise()
  assert(Test.raises(function() error("boom: it broke", 0) end, "it broke") == "boom: it broke")
  assert(Test.raises(function() error("any", 0) end) == "any")
  Test.raises(function() Test.raises(function() end, "x") end,
    'expected a raise naming "x", but the call returned')
  Test.raises(function() Test.raises(function() error("else", 0) end, "x") end,
    'naming "x", but it raised: else')
end

--- `equal` passes on the same text, and on a difference fails with the change as a unified diff, named and cut.
local function test_equal_shows_the_change_as_a_diff()
  Test.equal("a\nb\n", "a\nb\n")
  local said = Test.raises(function() Test.equal("a\nb\nc\n", "a\nB\nc\n", "the table") end, "the table differs")
  assert(said:find("--- want\n+++ got\n@@ -1,3 +1,3 @@\n a\n-b\n+B\n c", 1, true) ~= nil, said)
  local long_want: mut {string} = {}
  local long_got: mut {string} = {}
  for i = 1, 100 do
    local old_line = "old " .. tostring(i)
    local new_line = "new " .. tostring(i)
    long_want[#long_want + 1] = old_line
    long_got[#long_got + 1] = new_line
  end
  local cut = Test.raises(function()
    Test.equal(table.concat(long_want, "\n") .. "\n", table.concat(long_got, "\n") .. "\n")
  end, "text differs")
  assert(cut:find("more diff lines", 1, true) ~= nil and cut:find("old 100", 1, true) == nil, cut)
end

--- `module`'s table, whose fields a runner installs, as its untyped self.
local function fields_of(module: any): mut {string:any}
  if module is mut {string:any} then return module end -- checked: is_on_record
  error("fields_of: the module is not a table with string keys", 2)
end

--- `skip` records its reason with the runner and raises what the runner's
--- `skipped` returns, so the test ends there. Run under a stand-in
--- runner, put back as it was: this test's own runner would otherwise
--- take the raise.
local function test_skip_raises_what_the_runner_answers()
  local ending: {string:string} = {}
  local given: mut {string} = {}
  local fake: {string:any} = {
    loaded = true, -- checked: any_use
    skipped = function(reason: string): {string:string} -- checked: any_use
      given[#given + 1] = reason
      return ending
    end,
  }
  local module = fields_of(Test)
  local own = module.__runner -- checked: map_field
  module.__runner = fake -- checked: map_field
  local ok, raised: boolean, any = pcall(Test.skip, "no kernel")
  module.__runner = own -- checked: map_field
  assert(not ok and raised == ending, tostring(raised))
  assert(#given == 1 and given[1] == "no kernel")
end

--- `mode` returns what the runner says of the run. Run under stand-in
--- runners, put back as it was.
local function test_mode_reads_what_the_runner_says()
  local module = fields_of(Test)
  local own = rawget(module, "__runner")
  rawset(module, "__runner", { types_checked = true })
  local checked = Test.mode().types_checked
  rawset(module, "__runner", { types_checked = false })
  local plain = Test.mode().types_checked
  rawset(module, "__runner", own)
  assert(checked and not plain)
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
  local started = Test.cosmic(test_child.words(tmp, "cosmic.test_test", "policy"),
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
