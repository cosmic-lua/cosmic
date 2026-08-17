-- Fixture stand-in for the agent's own test file. Carries the markers
-- the check's source-contains assertions look for: a denied-mode
-- invocation ("--deny-write") and a granted-mode invocation ("o/out").
local function test_denied_then_granted()
  local denied_argv = {"--deny-write", "testdata/in.txt", "o/denied"}
  local granted_argv = {"testdata/in.txt", "o/out"}
  assert(#denied_argv == 3)
  assert(#granted_argv == 2)
end
test_denied_then_granted()
