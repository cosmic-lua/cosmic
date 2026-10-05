--- `cosmic rand` run as this program: real standard input and output,
--- no verdict line, and the exit status. These start this program, so
--- they need `tool`; the draws themselves are in `rand_test.tl`.

local Child = require("cosmic.child")
local Clock = require("cosmic.clock")
local Test = require("cosmic.test")
local this_program = require("build.this_program")

--- The program itself, which its tests start.
Test.policy{ profiles = { "cosmic" } }

local record Ran
  code: integer
  out: string
  err: string
end

local function cosmic(dir: string, words: {string}, input?: string): Ran
  local started = this_program.program(words, {
    cwd = dir, stdout = "capture", stderr = "capture", input = input,
    timeout_ns = Clock.seconds(30),
  })
  local result = assert(Child.run(started.argv, started.options))
  return { code = result.code, out = result.stdout or "", err = result.stderr or "" }
end

local function test_it_prints_data_and_no_verdict_line(tmp: string)
  local ran = cosmic(tmp, { "rand", "uuid", "--v7", "-n", "3" })
  assert(ran.code == 0 and ran.err == "", ran.err)
  local count = 0
  for line in ran.out:gmatch("[^\n]+") do
    assert(line:match("^%x+%-%x+%-7%x+%-[89ab]%x+%-%x+$"), line)
    count = count + 1
  end
  assert(count == 3, ran.out)
  local token = cosmic(tmp, { "rand", "token" })
  assert(token.code == 0 and #token.out == 44 and token.err == "", token.out)
end

local function test_standard_input_and_a_seed_replay(tmp: string)
  local ran = cosmic(tmp, { "rand", "shuffle", "--seed", "1" }, "a\nb\nc\nd\n")
  assert(ran.code == 0 and ran.out == "b\nd\nc\na\n" and ran.err == "", ran.out .. ran.err)
  local negative = cosmic(tmp, { "rand", "int", "-5", "-5" })
  assert(negative.code == 0 and negative.out == "-5\n", negative.out .. negative.err)
end

local function test_usage_is_exit_2_with_no_verdict(tmp: string)
  local seeded = cosmic(tmp, { "rand", "token", "--seed", "1" })
  assert(seeded.code == 2 and seeded.out == "", seeded.out)
  assert(seeded.err:find("cosmic: rand: --seed is refused with token", 1, true), seeded.err)
  assert(not seeded.err:find("rand: FAIL", 1, true), seeded.err)
  local backwards = cosmic(tmp, { "rand", "int", "3", "1" })
  assert(backwards.code == 2 and backwards.out == "", backwards.out)
  local big = cosmic(tmp, { "rand", "token", "--bytes", "1048577" })
  assert(big.code == 2 and big.out == "", big.out)
end

local function test_help_names_the_verb_and_its_options(tmp: string)
  local ran = cosmic(tmp, { "rand", "--help" })
  assert(ran.code == 0, ran.err)
  assert(ran.out:find("cosmic rand", 1, true) and ran.out:find("--seed", 1, true), ran.out)
end
