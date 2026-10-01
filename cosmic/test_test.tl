--- [`cosmic.test`]'s `skip`, in this process. What its `needs` takes, as it
--- runs, is in cosmic/test_tool_test.tl, which a script run by this
--- program shows; what the build holds a declaration to, in
--- build/analyzer_test.tl.

local Test = require("cosmic.test")

--- `skip` takes a reason: none, or an empty one, raises before the test
--- is counted skipped, so this test, which passes, is not.
local function test_skip_takes_a_reason()
  for _, reason in ipairs({ "", 1, false, nil } as {any}) do
    local ok, trouble: boolean, any = pcall(Test.skip as function(any), reason)
    assert(not ok and tostring(trouble):find("skip takes a reason", 1, true), tostring(trouble))
  end
  local ok, trouble: boolean, any = pcall(Test.skip as function(any), nil)
  assert(not ok and tostring(trouble):find("skip takes a reason", 1, true), tostring(trouble))
end
