--- A worker a Landlock ruleset holds -- one whose module does not declare `nests` -- is refused a root of its own, in
--- fact: the runner marks it with its module's name ([`confine.held_variable`]), and a child of this program that
--- confines a process it starts finds the start refused, naming the promise. The same refusal, the same on every host with
--- the hold given to a child by hand, is in `must_confine_test.tl`. This module declares no `nests`, which is the point.

local Env = require("cosmic.env")
local sys = require("cosmic.sys")
local Test = require("cosmic.test")
local confine = require("build.confine")
local fixture = require("build.must_confine_fixture")
local _ = require("build.must_confine_children_test")

Test.policy{
  cpu_features = true,
  profiles = { "cosmic" },
  grants = { { path = "o/bin", letters = "rx" } },
}

local function test_a_sandboxed_worker_is_held_by_a_ruleset_and_refused_a_root_of_its_own(tmp: string)
  local held = Env.get(confine.held_variable)
  if held == nil then
    if assert(sys.uname()).sysname == "Linux" then
      Test.skip("this worker is not sandboxed, so no ruleset holds it")
    end
    Test.skip("a ruleset holds a worker on Linux alone")
    return
  end
  local probe = fixture.probe(tmp)
  local said = fixture.run(tmp, "held", { probe, tmp }, { [confine.held_variable] = held })
  assert(said.code == 0, said.text)
  local refused = probe .. " cannot start in a root of its own: " .. held .. "'s worker is held by a Landlock " ..
    "ruleset, under which the kernel refuses every mount; declare the promise \"nest\" in its Test.policy"
  assert(fixture.field(said, "confined") == refused, said.text)
  assert(fixture.field(said, "own_sandbox") == refused, said.text)
end
