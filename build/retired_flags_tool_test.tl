--- The flags of earlier releases, refused at the top level of the command line with the command that replaced each
--- (build/dispatch.tl). It declares `tool` because it starts this program.

local Child = require("cosmic.child")
local Clock = require("cosmic.clock")
local Test = require("cosmic.test")
local this_program = require("build.this_program")

Test.policy{ profiles = { "cosmic" }, grants = { { path = "o/bin", letters = "rx" } } }

--- Runs the program with `words` as its command line and answers the result.
local function started_with(tmp: string, words: {string}): Child.Result
  local started = this_program.program(words, { env = this_program.environment(), cwd = tmp,
    stdout = "capture", stderr = "capture", timeout_ns = Clock.seconds(60) })
  return (assert(Child.run(started.argv, started.options)))
end

local function says(r: Child.Result, text: string): boolean
  return (r.stderr or ""):find(text, 1, true) ~= nil
end

--- A flag an earlier release took at the top level is refused with the command that replaced it, exiting 2 as the
--- removed `migrate` verb does.
local function test_a_retired_top_level_flag_is_refused_with_its_replacement(tmp: string)
  local replacements <const>: {string: {string}} = {
    ["--make"] = { "cosmic build", "cosmic test" },
    ["--docs"] = { "cosmic docs" },
    ["--check-types"] = { "cosmic test --check-types" },
    ["--check-format"] = { "cosmic fix --check" },
  }
  for flag, instead in pairs(replacements) do
    local r = started_with(tmp, { flag, "x.tl" })
    assert(r.code == 2 and (r.stdout or "") == "", flag .. ": " .. tostring(r.code) .. tostring(r.stdout))
    assert(says(r, flag .. " was removed"), flag .. ": " .. tostring(r.stderr))
    for _, command in ipairs(instead) do
      assert(says(r, command), flag .. " names no " .. command .. ": " .. tostring(r.stderr))
    end
    assert(not says(r, "no such option"), tostring(r.stderr))
  end
end

--- A flag that was never a flag is still told as one.
local function test_another_unknown_flag_is_still_no_such_option(tmp: string)
  local r = started_with(tmp, { "--nosuch" })
  assert(r.code == 2 and says(r, "no such option: --nosuch"), tostring(r.stderr))
end

--- `--check-types` is a current flag of `cosmic test`: only the top level refuses it.
local function test_check_types_is_still_a_flag_of_test(tmp: string)
  local r = started_with(tmp, { "test", "--help" })
  assert(r.code == 0, tostring(r.code) .. tostring(r.stderr))
  assert((r.stdout or ""):find("--check-types", 1, true) ~= nil, tostring(r.stdout))
  assert(not says(r, "was removed"), tostring(r.stderr))
end
