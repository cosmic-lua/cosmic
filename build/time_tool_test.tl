--- `cosmic time` run as this program: the real clock, the real
--- environment's zone, and the rule that it prints its answer and no
--- verdict line, exiting 0, 1 or 2. These start this program, so they
--- need `tool`; the arithmetic itself is in `time_test.tl`, against a
--- clock it can fix.

local Child = require("cosmic.child")
local Test = require("cosmic.test")
local this_program = require("build.this_program")

--- The program itself, which its tests start.
Test.needs{ tool = true }

local record Ran
  code: integer
  out: string
  err: string
end

local function cosmic(dir: string, words: {string}, tz?: string): Ran
  local env = this_program.environment()
  env.TZ = tz or "Asia/Tokyo"
  local started = this_program.program(words, {
    cwd = dir, env = env, stdout = "capture", stderr = "capture", timeout_ms = 30000,
  })
  local result = assert(Child.run(started.argv, started.options))
  return { code = result.code, out = result.stdout or "", err = result.stderr or "" }
end

local function test_now_prints_the_time_and_no_verdict(tmp: string)
  -- The wall clock is not asserted, only the shape of what it prints.
  local ran = cosmic(tmp, { "time", "now" })
  assert(ran.code == 0 and ran.err == "", ran.err)
  assert(ran.out:match("^%d%d%d%d%-%d%d%-%d%dT%d%d:%d%d:%d%d%+09:00\n$"), ran.out)
  local epoch = cosmic(tmp, { "time", "now", "--format", "epoch" })
  assert(epoch.code == 0 and epoch.out:match("^%d+\n$"), epoch.out)
  local http = cosmic(tmp, { "time", "now", "--format", "http", "--zone", "America/New_York" })
  assert(http.out:match(" GMT\n$"), http.out)
end

local function test_the_host_zone_is_the_default_the_zone_option_overrides(tmp: string)
  assert(cosmic(tmp, { "time", "convert", "@0" }).out == "1970-01-01T09:00:00+09:00\n")
  assert(cosmic(tmp, { "time", "convert", "@0" }, "America/New_York").out == "1969-12-31T19:00:00-05:00\n")
  assert(cosmic(tmp, { "time", "convert", "@0" }, "").out == "1970-01-01T00:00:00+00:00\n")
  assert(cosmic(tmp, { "time", "convert", "@0", "--to", "Europe/Berlin" }).out == "1970-01-01T01:00:00+01:00\n")
end

local function test_the_exit_status_is_the_verdict(tmp: string)
  local done = cosmic(tmp, { "time", "add", "2026-01-31", "1mo", "--clamp", "--zone", "UTC" })
  assert(done.code == 0 and done.out == "2026-02-28T00:00:00+00:00\n" and done.err == "", done.out .. done.err)
  local none = cosmic(tmp, { "time", "add", "2026-01-31", "1mo", "--zone", "UTC" })
  assert(none.code == 1 and none.out == "", none.out)
  assert(none.err:find("cosmic: time: 2026-02 has no day 31", 1, true), none.err)
  local negative = cosmic(tmp, { "time", "add", "2026-03-08T00:00:00Z", "-1d" })
  -- The text's own zone (here UTC) is the calendar it moves along.
  assert(negative.code == 0 and negative.out == "2026-03-07T00:00:00+00:00\n", negative.out)
  local bad = cosmic(tmp, { "time", "convert", "@0", "--to", "Mars/Base" })
  assert(bad.code == 2 and bad.out == "", bad.out)
  assert(not bad.err:find("time: FAIL", 1, true), bad.err)
  local usage = cosmic(tmp, { "time", "--bogus" })
  assert(usage.code == 2 and usage.out == "" and usage.err:find("no such option: --bogus", 1, true), usage.err)
end

--- Help reads the store's docs, which a test not declaring `store` is held
--- from, and one that does runs again on every edit to the tree; so it
--- is here, with the tests that start the program, not in-process.
local function test_help_names_the_verb_and_its_options(tmp: string)
  local ran = cosmic(tmp, { "time", "--help" })
  assert(ran.code == 0, ran.err)
  assert(ran.out:find("cosmic time", 1, true) and ran.out:find("--disambiguate", 1, true), ran.out)
end
