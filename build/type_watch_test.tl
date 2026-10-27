--- [`TypeWatch.during`] skips its test in a checked run too: no compile writes the checks of returns and fields yet, so a pass would be partial.

local Test = require("cosmic.test")
local TypeWatch = require("build.type_watch")

Test.policy{}

local function test_a_checked_run_skips_for_want_of_boundary_checks()
  local reason = TypeWatch.skip_reason(true)
  assert(reason:find("boundary checks are not compiled in", 1, true) ~= nil, reason)
end

local function test_a_plain_run_skips_and_names_the_flag()
  local reason = TypeWatch.skip_reason(false)
  assert(reason:find("--check-types", 1, true) ~= nil, reason)
end

--- Reported skipped, not passed: `during` ends the test where it is called, so the assert is reached only if it does not.
local function test_during_ends_the_test_as_a_skip()
  TypeWatch.during(function() end)
  assert(false, "during did not skip")
end
