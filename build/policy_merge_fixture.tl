--- The merge of policies the tests of [`cosmic.sandbox`] and
--- [`cosmic.policy`] build their cases from (cosmic/sandbox_test.tl and
--- cosmic/policy_test.tl). Test support.

local Sandbox = require("cosmic.sandbox")

local record policy_merge_fixture
end

--- The merged policy of `...`, which must merge.
--- @param ... the policies to merge
--- @return the merge
function policy_merge_fixture.merged(...: Sandbox.Policy): Sandbox.Policy
  local out, why = Sandbox.merge(...)
  assert(out ~= nil, why)
  return out
end

return policy_merge_fixture
