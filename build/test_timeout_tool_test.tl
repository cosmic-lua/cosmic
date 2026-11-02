--- A module's `timeout` in [`Test.policy`] is the longest its tests may run,
--- where it is longer than the run's own (`--timeout`, COSMIC_TEST_TIMEOUT).
--- It is no way to hold a test to less, and the verdict's key holds the
--- limit the test ran under.

local Child = require("cosmic.child")
local Clock = require("cosmic.clock")
local Fs = require("cosmic.fs")
local Test = require("cosmic.test")
local this_program = require("build.this_program")

--- The program itself, which its tests start. A test that runs `cosmic test`
--- takes minutes where the host is loaded.
Test.policy{
  profiles = { "cosmic" },
  grants = { { path = "o/bin", letters = "rx" } },
  timeout = 180,
}

--- A project of three modules whose one test each sleeps two seconds:
--- one declares no timeout, one declares 100 seconds and one declares 1.
local function project(tmp: string): string
  local root = tmp .. "/project"
  assert(Fs.mkdirs(root .. "/suite"))
  local function module(name: string, policy: string)
    local head = if policy == "" then "" else 'local Test = require("cosmic.test")\n' .. policy .. "\n" end
    assert(Fs.write(root .. "/suite/" .. name .. "_test.tl", head .. [[

local function test_sleeps()
  require("cosmic.clock").sleep_ns(2000000000)
  assert(true)
end
]]))
  end
  module("plain", "")
  module("long", "Test.policy { timeout = 100 }")
  module("short", "Test.policy { timeout = 1 }")
  return root
end

--- Runs `cosmic test` with `words` in `root`, unsandboxed whatever this
--- run's switch, and answers what it said.
local function invoke(root: string, output: string, words: {string}): string
  local fd = assert(Fs.open_write(output))
  local env = this_program.environment()
  env["COSMIC_TEST_SANDBOX"] = "0"
  env["COSMIC_VERDICT_CACHE"] = "0"
  env["COSMIC_TEST_ALL"] = nil
  env["COSMIC_TEST_TIMEOUT"] = nil
  env["TMPDIR"] = Fs.dirname(output)
  local argv: mut {string} = { "test" }
  for _, word in ipairs(words) do argv[#argv + 1] = word end
  local started = this_program.program(argv, {
    cwd = root, env = env, stdout = fd, stderr = fd,
    process_group = true, timeout_ns = Clock.seconds(150),
  })
  local result, trouble = Child.run(started.argv, started.options)
  assert(Fs.close(fd))
  assert(result ~= nil, trouble)
  return (assert(Fs.read(output)))
end

--- Under `--timeout 1` the module that declares no limit times out and the
--- module that declares 100 seconds does not. A module's limit only
--- lengthens the run's: the one that declares 1 second is held to the run's.
local function test_a_module_declares_a_longer_limit(tmp: string)
  local root = project(tmp)
  local text = invoke(root, tmp .. "/one.out", { "--timeout", "1" })
  assert(text:find("2 of 3 tests failed", 1, true), text)
  assert(text:find("test: FAIL  suite.plain_test test_sleeps: timed out after 1 s", 1, true), text)
  assert(text:find("test: FAIL  suite.short_test test_sleeps: timed out after 1 s", 1, true), text)
  assert(not text:find("FAIL  suite.long_test", 1, true), text)
end

--- The limit a test ran under is in its key. A module that declares 100
--- seconds ran under 100 whichever `--timeout` was lower, so a run with
--- another `--timeout` stands on its verdict; a module that declares
--- none, or fewer seconds than the run gives, ran under the run's, so the
--- same run does not stand on its verdict. The module that declares 1
--- second passes under the run's 5, which a limit that shortened would not.
local function test_the_limit_a_verdict_stood_under_is_in_its_key(tmp: string)
  local root = project(tmp)
  local first = invoke(root, tmp .. "/first.out", { "--timeout", "5" })
  assert(first:find("3 tests passed", 1, true), first)
  local second = invoke(root, tmp .. "/second.out", { "--timeout", "6" })
  assert(second:find("3 tests passed", 1, true), second)
  -- plain ran under 6 seconds where it ran under 5; long and short stood:
  -- long under its 100, short under the run's 6 -- which moved it too.
  assert(second:find("1 stood", 1, true), second)
  assert(second:find("2 ran", 1, true), second)
end
