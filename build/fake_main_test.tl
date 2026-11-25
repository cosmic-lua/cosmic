local Child = require("cosmic.child")
local Clock = require("cosmic.clock")
local Fake = require("cosmic.fake")
local _ = require("build.fake_main_fixture")

local function run(argv: {string}): Child.Result
  return assert(Child.run(argv, { stdout = "capture", timeout_ns = Clock.seconds(30) }))
end

local function test_a_fake_runs_the_main_it_is_built_with(tmp: string)
  local program = assert(Fake.build(tmp .. "/fake", "build.fake_main_fixture"))
  local ran = run({ program, "a", "b" })
  assert(ran.stdout == "none\na b\n", ran.stdout)
  assert(ran.code == 3, tostring(ran.code))
end

local function test_a_placed_copy_reads_what_it_was_given(tmp: string)
  local program = assert(Fake.build(tmp .. "/fake", "build.fake_main_fixture"))
  assert(Fake.place(program, tmp .. "/git", "abc1234"))
  assert(Fake.place(program, tmp .. "/zig"))
  assert(run({ tmp .. "/git", "rev-parse" }).stdout == "abc1234\nrev-parse\n")
  assert(run({ tmp .. "/zig" }).stdout == "none\n\n")
end

local function test_a_main_the_test_does_not_hold_is_refused(tmp: string)
  local program, trouble = Fake.build(tmp .. "/fake", "build.no_such_fake_main")
  assert(program == nil)
  assert(tostring(trouble):find("require build.no_such_fake_main from the test", 1, true), tostring(trouble))
end

local function test_one_dir_holds_a_fake_of_each_main(tmp: string)
  local probe = assert(Fake.build(tmp .. "/fake"))
  local main = assert(Fake.build(tmp .. "/fake", "build.fake_main_fixture"))
  assert(probe ~= main, main)
  assert(run({ probe, "print probe" }).stdout == "probe\n")
  assert(run({ main }).stdout == "none\n\n")
end

local function test_a_place_with_nothing_given_clears_what_an_earlier_one_gave(tmp: string)
  local program = assert(Fake.build(tmp .. "/fake", "build.fake_main_fixture"))
  assert(Fake.place(program, tmp .. "/git", "abc1234"))
  assert(Fake.place(program, tmp .. "/git"))
  assert(run({ tmp .. "/git" }).stdout == "none\n\n")
end
