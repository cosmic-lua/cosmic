--- The runner ends an orphan whose process group its dead worker cannot
--- reach. That needs the kernel's children list, which a container's /proc
--- may hide even when its /proc/self/status is readable.

local Test = require("cosmic.test")
local stand_in = require("build.stand_in")
local fixture = require("build.test_isolation_fixture")

Test.policy{
  profiles = { "cosmic", "proc" },
  grants = { { path = "o/bin", letters = "rx" } },
  promises = { "nest" },
  env = { "COSMIC_SANDBOX", "COSMIC_TEST_SANDBOX" },
  requires = { "path:/proc/thread-self/children" },
}

local function test_a_hung_workers_orphan_is_ended(tmp: string)
  local probe = assert(stand_in.build(tmp .. "/stand-in"))
  fixture.hung_runs(tmp, probe, false)
end
