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
  local reply = assert(Fake.build(tmp .. "/fake", Fake.REPLY))
  local main = assert(Fake.build(tmp .. "/fake", "build.fake_main_fixture"))
  assert(reply ~= main, main)
  assert(Fake.reply(reply, tmp .. "/git", { [""] = { stdout = "reply\n" } }))
  assert(run({ tmp .. "/git" }).stdout == "reply\n")
  assert(run({ main }).stdout == "none\n\n")
end

local function test_a_place_with_nothing_given_clears_what_an_earlier_one_gave(tmp: string)
  local program = assert(Fake.build(tmp .. "/fake", "build.fake_main_fixture"))
  assert(Fake.place(program, tmp .. "/git", "abc1234"))
  assert(Fake.place(program, tmp .. "/git"))
  assert(run({ tmp .. "/git" }).stdout == "none\n\n")
end

local function test_a_reply_fake_answers_by_its_first_argument(tmp: string)
  local program = assert(Fake.build(tmp .. "/fake", Fake.REPLY))
  assert(Fake.reply(program, tmp .. "/git", {
    ["rev-parse"] = { stdout = "abc1234\n" },
    [""] = { stderr = "usage: git\n", code = 1 },
  }))
  local ran = assert(Child.run({ tmp .. "/git", "rev-parse", "HEAD" },
    { stdout = "capture", stderr = "capture", timeout_ns = Clock.seconds(30) }))
  assert(ran.code == 0 and ran.stdout == "abc1234\n" and ran.stderr == "", ran.stderr)
  local bare = assert(Child.run({ tmp .. "/git" },
    { stdout = "capture", stderr = "capture", timeout_ns = Clock.seconds(30) }))
  assert(bare.code == 1 and bare.stdout == "" and bare.stderr == "usage: git\n", bare.stderr)
  local other = assert(Child.run({ tmp .. "/git", "push" },
    { stdout = "capture", stderr = "capture", timeout_ns = Clock.seconds(30) }))
  assert(other.code == 127, tostring(other.code))
  assert((other.stderr or ""):find('no reply for "push"', 1, true) ~= nil, other.stderr)
end

local function test_a_reply_fake_falls_back_to_its_star_reply(tmp: string)
  local program = assert(Fake.build(tmp .. "/fake", Fake.REPLY))
  assert(Fake.reply(program, tmp .. "/zig", { ["*"] = { code = 0 } }))
  assert(run({ tmp .. "/zig", "build" }).code == 0)
end
