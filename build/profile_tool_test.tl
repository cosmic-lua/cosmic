--- `cosmic profile` run as this program on the profile of a real run: it names the chunk's own function and the C
--- function it called, prints no summary, and reads standard input for `-`. What each list adds up is in
--- build/profile_test.tl.

local Child = require("cosmic.child")
local Clock = require("cosmic.clock")
local Fs = require("cosmic.fs")
local Test = require("cosmic.test")
local tool_fixture = require("build.tool_fixture")

--- The program itself, which its tests start.
Test.policy{ profiles = { "cosmic" }, grants = { { path = "o/bin", letters = "rx" } } }

--- A chunk whose time goes to a function of its own and to string.find.
local CHUNK <const> = "local function spin(n: integer): integer local s = 0 for i = 1, n do s = s + i end return s end " ..
  "local x = ('ab'):rep(1000000) for _ = 1, 200 do spin(100000) local _ = x:find('abc', 1, true) end"

--- Runs CHUNK with its profile written under `tmp`/prof, and returns that directory.
local function profiled(tmp: string): string
  local dir = tmp .. "/prof"
  local vars = Test.environment()
  vars["COSMIC_PROFILE"] = dir
  vars["COSMIC_PROFILE_HZ"] = "2000"
  local started = Test.cosmic({ "-e", CHUNK },
    { env = vars, stdout = "capture", stderr = "capture", timeout_ns = Clock.seconds(60) })
  local result = assert(Child.run(started.argv, started.options))
  assert(result.ok, tostring(result.stderr))
  return dir
end

local function test_it_reports_a_real_profile_with_no_summary(tmp: string)
  local dir = profiled(tmp)
  local ran = tool_fixture.cosmic(tmp, { "profile", "prof" })
  assert(ran.code == 0 and ran.err == "", ran.out .. ran.err)
  assert(ran.out:match("^1 process, [%d.]+ ms cpu, [%d.]+ ms sampled on the cpu clock") ~= nil, ran.out)
  assert(ran.out:find("spin@-e:1\n", 1, true) ~= nil, ran.out)
  assert(ran.out:find("string.find@[C]\n", 1, true) ~= nil, ran.out)
  local names = assert(Fs.list(dir))
  local one = assert(Fs.read(dir .. "/" .. assert(names[1])))
  local piped = tool_fixture.cosmic(tmp, { "profile", "--by", "line", "-" }, one)
  assert(piped.code == 0 and piped.out:find("  -e:1\n", 1, true) ~= nil, piped.out .. piped.err)
end

local function test_a_file_that_is_not_a_profile_is_exit_5(tmp: string)
  assert(Fs.write(tmp .. "/x.prof", "hello\n"))
  local ran = tool_fixture.cosmic(tmp, { "profile", "x.prof" })
  assert(ran.code == 5 and ran.out == "", ran.out)
  assert(ran.err:find("cosmic: profile: x.prof: not a profile", 1, true) ~= nil, ran.err)
end
