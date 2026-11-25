local Child = require("cosmic.child")
local Clock = require("cosmic.clock")
local Fake = require("cosmic.fake")
local _ = require("build.fake_main_fixture")

local function test_a_fake_runs_the_main_it_is_built_with(tmp: string)
  local program = assert(Fake.build(tmp .. "/fake", "build.fake_main_fixture"))
  local ran = assert(Child.run({ program, "a", "b" }, { stdout = "capture", timeout_ns = Clock.seconds(30) }))
  assert(ran.stdout == "a b\n", ran.stdout)
  assert(ran.code == 3, tostring(ran.code))
end

local function test_a_main_the_test_does_not_hold_is_refused(tmp: string)
  local program, trouble = Fake.build(tmp .. "/fake", "build.no_such_fake_main")
  assert(program == nil)
  assert(tostring(trouble):find("require build.no_such_fake_main from the test", 1, true), tostring(trouble))
end
