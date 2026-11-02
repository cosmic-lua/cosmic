--- What the tests of the inputs a test declares share (build/test_policy_plan_tool_test.tl, build/test_sandbox_test.tl and
--- build/test_sandbox_tool_test.tl): an `Effective` to plan from. Test support.

local test_inputs = require("build.test_inputs")

local record test_inputs_fixture
end

--- An `Effective` holding `files` of the tree and nothing else declared.
--- @param files the files it holds
--- @return the declared inputs
function test_inputs_fixture.effective(files: {string}): test_inputs.Effective
  local out: test_inputs.Effective = { files = {}, reads = {}, host = {}, env = {}, network = {},
    tool = false, store = false }
  for _, file in ipairs(files) do out.files[file] = true end
  return out
end

return test_inputs_fixture
