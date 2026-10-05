--- [`cosmic.test`]'s `skip`, in this process. What its `needs` takes, as it
--- runs, is in cosmic/test_tool_test.tl, which a script run by this
--- program shows; what the build holds a declaration to, in
--- build/analyzer_test.tl.

local Test = require("cosmic.test")

--- `skip` takes a reason: none, or an empty one, raises before the test
--- is counted skipped, so this test, which passes, is not.
local function test_skip_takes_a_reason()
  for _, reason in ipairs({ 1, false, nil } as {any}) do
    local ok, trouble: boolean, any = pcall(Test.skip as function(any), reason)
    assert(not ok and tostring(trouble):find("test: skip's reason is not a string", 1, true),
      tostring(trouble))
  end
  local ok, trouble: boolean, any = pcall(Test.skip as function(any), "")
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
  local given: {string} = {}
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
