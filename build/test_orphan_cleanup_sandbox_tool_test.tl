--- Ending a sandboxed worker also ends an orphan it left in another group.

local stand_in = require("build.stand_in")
local Test = require("cosmic.test")
local fixture = require("build.test_isolation_fixture")

Test.policy{
  profiles = { "cosmic" },
  grants = { { path = "o/bin", letters = "rx" }, { path = "/proc", letters = "r" } },
  promises = { "nest" },
  env = { "COSMIC_SANDBOX", "COSMIC_TEST_SANDBOX" },
  requires = { "sandbox", "path:/proc/thread-self/children" },
}

local function test_a_sandboxed_hung_workers_orphan_is_ended(tmp: string)
  local probe = assert(stand_in.build(tmp .. "/stand-in"))
  fixture.hung_runs(tmp, probe, true)
end
