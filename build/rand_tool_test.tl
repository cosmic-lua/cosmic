--- `cosmic rand` run as this program: real standard input and output,
--- no summary, and the exit status. These start this program, so
--- they need `tool`; the draws themselves are in `rand_test.tl`.

local Rand = require("cosmic.rand")
local Test = require("cosmic.test")
local tool_fixture = require("build.tool_fixture")

--- The program itself, which its tests start.
Test.policy{ profiles = { "cosmic" }, grants = { { path = "o/bin", letters = "rx" } } }

local function test_it_prints_data_and_no_summary(tmp: string)
  local ran = tool_fixture.cosmic(tmp, { "rand", "uuid", "--v7", "-n", "3" })
  assert(ran.code == 0 and ran.err == "", ran.err)
  local count = 0
  for line in ran.out:gmatch("[^\n]+") do
    assert(line:match("^%x+%-%x+%-7%x+%-[89ab]%x+%-%x+$"), line)
    count = count + 1
  end
  assert(count == 3, ran.out)
  local token = tool_fixture.cosmic(tmp, { "rand", "token" })
  assert(token.code == 0 and #token.out == 44 and token.err == "", token.out)
end

local function test_standard_input_and_a_seed_replay(tmp: string)
  local ran = tool_fixture.cosmic(tmp, { "rand", "shuffle", "--seed", "1" }, "a\nb\nc\nd\n")
  assert(ran.code == 0 and ran.out == "b\nd\nc\na\n" and ran.err == "", ran.out .. ran.err)
  local negative = tool_fixture.cosmic(tmp, { "rand", "int", "-5", "-5" })
  assert(negative.code == 0 and negative.out == "-5\n", negative.out .. negative.err)
end

--- Each subcommand has its own help, by either spelling, and a refusal names only its usage.
local function test_each_subcommand_has_its_own_help(tmp: string)
  for _, line in ipairs({ { "help", "rand", "gamma" }, { "rand", "gamma", "--help" }, { "rand", "help", "gamma" } }) do
    local helped = tool_fixture.cosmic(tmp, line)
    assert(helped.code == 0 and helped.out:find("^usage: cosmic rand gamma %[options%]") ~= nil and
        helped.out:find("--shape <k>", 1, true) ~= nil and helped.out:find("--bytes", 1, true) == nil, helped.out)
  end
  local listed = tool_fixture.cosmic(tmp, { "help", "rand" })
  assert(listed.out:find("\n  uuid [options]", 1, true) ~= nil, listed.out)
  local refused = tool_fixture.cosmic(tmp, { "rand", "uuid", "--bytes", "3" })
  assert(refused.code == 2 and refused.err:find("rand: uuid: no such option: --bytes; usage: cosmic rand uuid", 1,
    true) ~= nil and refused.err:find("token", 1, true) == nil, refused.err)
  for _, line in ipairs({ { "help", "rand", "uuidd" }, { "rand", "uuidd", "--help" } }) do
    local unknown = tool_fixture.cosmic(tmp, line)
    assert(unknown.code == 2 and unknown.err:find("did you mean uuid?", 1, true) ~= nil, unknown.err)
  end
end

--- A subcommand of a subcommand has its own help too, by either spelling.
local function test_a_nested_subcommand_has_its_own_help(tmp: string)
  for _, line in ipairs({ { "help", "tailscale", "file", "get" }, { "tailscale", "file", "get", "--help" },
      { "tailscale", "help", "file", "get" } }) do
    local helped = tool_fixture.cosmic(tmp, line)
    assert(helped.code == 0 and helped.out:find("^usage: cosmic tailscale file get %[options%] <dir>") ~= nil and
        helped.out:find("--conflict", 1, true) ~= nil, helped.out .. helped.err)
  end
  local unknown = tool_fixture.cosmic(tmp, { "help", "tailscale", "file", "gett" })
  assert(unknown.code == 2 and unknown.err:find("tailscale file has no command gett; did you mean get?", 1, true) ~= nil,
    unknown.err)
  local leaf = tool_fixture.cosmic(tmp, { "help", "tailscale", "status", "x" })
  assert(leaf.code == 2 and leaf.err:find("tailscale status has no commands of its own, so not x", 1, true) ~= nil,
    leaf.err)
end

local function test_usage_is_exit_2_with_no_summary(tmp: string)
  local seeded = tool_fixture.cosmic(tmp, { "rand", "token", "--seed", "1" })
  assert(seeded.code == 2 and seeded.out == "", seeded.out)
  assert(seeded.err:find("cosmic: rand: token: --seed is refused", 1, true), seeded.err)
  assert(not seeded.err:find("rand: FAIL", 1, true), seeded.err)
  local backwards = tool_fixture.cosmic(tmp, { "rand", "int", "3", "1" })
  assert(backwards.code == 2 and backwards.out == "", backwards.out)
  local big = tool_fixture.cosmic(tmp, { "rand", "token", "--bytes", "1048577" })
  assert(big.code == 2 and big.out == "", big.out)
end

local function test_help_names_the_verb_and_its_options(tmp: string)
  local ran = tool_fixture.cosmic(tmp, { "rand", "--help" })
  assert(ran.code == 0, ran.err)
  assert(ran.out:find("cosmic rand", 1, true) and ran.out:find("--seed", 1, true), ran.out)
  for _, name in ipairs({ "uuid", "token", "int", "pick", "shuffle", "normal", "gamma" }) do
    assert(ran.out:find("`" .. name .. " ", 1, true) or ran.out:find("|" .. name, 1, true),
      "the help does not name " .. name)
  end
  for _, flag in ipairs({ "--mean", "--stddev", "--shape", "--scale" }) do
    assert(ran.out:find(flag, 1, true), "the help does not name " .. flag)
  end
end

local function test_normal_and_gamma_print_one_float_a_line(tmp: string)
  local seeded = tool_fixture.cosmic(tmp, { "rand", "normal", "-n", "2", "--seed", "4", "--mean", "-5" })
  assert(seeded.code == 0 and seeded.err == "", seeded.err)
  local source = Rand.new(4)
  assert(seeded.out == ("%.17g\n%.17g\n"):format(source:normal(-5.0, 1.0), source:normal(-5.0, 1.0)), seeded.out)
  local gamma = tool_fixture.cosmic(tmp, { "rand", "gamma", "--shape", "2", "--scale", "3", "--seed", "4" })
  assert(gamma.code == 0 and gamma.out == ("%.17g\n"):format(Rand.new(4):gamma(2.0, 3.0)), gamma.out .. gamma.err)
  local entropy = tool_fixture.cosmic(tmp, { "rand", "normal", "-n", "3" })
  assert(entropy.code == 0 and #entropy.out > 6 and entropy.err == "", entropy.out)
  local refused = tool_fixture.cosmic(tmp, { "rand", "gamma" })
  assert(refused.code == 2 and refused.out == "", refused.out)
  assert(refused.err:find("cosmic: rand: gamma: --shape is required", 1, true), refused.err)
end
