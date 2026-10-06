--- A sandboxed hung or exiting worker fails alone while its sibling finishes.

local Test = require("cosmic.test")
local fixture = require("build.test_isolation_fixture")

Test.policy{
  profiles = { "cosmic" },
  grants = { { path = "o/bin", letters = "rx" }, { path = "/proc", letters = "r" } },
  promises = { "nest" },
  env = { "COSMIC_SANDBOX", "COSMIC_TEST_SANDBOX" },
  requires = { "sandbox" },
}

local function test_a_sandboxed_hung_or_exiting_test_fails_alone(tmp: string)
  fixture.hung_runs(tmp, nil, true)
end
