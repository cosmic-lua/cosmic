--- A module that calls [`Test.policy`] at its top, for cosmic/test_test.tl to require from a process whose test module has
--- called it already, or after its module has loaded: a call [`cosmic.test`] refuses at run time, and a test module calls
--- `policy` at its top alone. It is no test.

local Test = require("cosmic.test")

Test.policy{}

local record test_policy_twice
end

return test_policy_twice
