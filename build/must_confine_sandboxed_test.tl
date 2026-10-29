--- End to end: what [`confine.must_confine`] does where the kernel confines a process: it runs held to what was declared,
--- or the test fails naming what could not be applied. The child (build/must_confine_children_test.tl) starts its
--- processes in this test's own sandbox, which nests, so these declare `nests` and are not applicable where the host gives
--- no nest (`requires`). The refusals the same on every host are in `must_confine_test.tl`.

local Fs = require("cosmic.fs")
local Test = require("cosmic.test")
local confine = require("build.confine")
local fixture = require("build.must_confine_fixture")
local _ = require("build.must_confine_children_test")

--- What these tests start is this very program, which runs the tool's own modules besides the closure's, in a root of its
--- own (`nests`).
Test.policy{
  profiles = { "cosmic" },
  grants = { { path = "o/bin", letters = "rx" } },
  promises = { "nest" },
  requires = { "nest" },
}
-- What these tests start is this very program.
confine.confine({ reads = confine.itself() })

--- Where the kernel confines a process, one under `must_confine` runs held to what was declared -- not seeing what it was
--- not given, and with no network but a loopback -- and its test passes; where it does not, the test fails naming what
--- could not be applied. It never runs unconfined.
local function test_a_must_confined_process_is_confined_or_refused(tmp: string)
  -- the directory the process may change is its own: the files it must not see are beside it, not in it
  local own = tmp .. "/own"
  local hidden = tmp .. "/hidden"
  assert(Fs.mkdirs(own) and Fs.mkdirs(hidden))
  assert(Fs.write(hidden .. "/f", "secret"))
  local data = tmp .. "/data.txt"
  assert(Fs.write(data, "in"))
  local said = fixture.run(tmp, "confined", { fixture.probe(tmp), own, data, hidden .. "/f" })
  assert(said.code == 0, said.text)
  local outcome = fixture.field(said, "confined")
  if outcome == "ok" then return end
  assert(outcome:find("^must_confine: %S+ could not start confined: .+ could not be applied: .+ %(E[A-Z0-9]+%)$") ~= nil,
    said.text)
  Test.skip("a sandboxed worker could not confine what it started: " .. outcome)
end
