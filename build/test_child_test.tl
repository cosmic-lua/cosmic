--- A child of a test module ([`build.test_child`]): the module's own code, run in a process of this program started
--- again, with the words after the chunk as its arguments.
local Child = require("cosmic.child")
local Clock = require("cosmic.clock")
local Test = require("cosmic.test")
local test_child = require("build.test_child")
local this_program = require("build.this_program")

Test.policy{ profiles = { "cosmic" } }

--- A child that says its arguments, one a line, and exits with their count.
test_child.register("echo", function(args: {string}): integer
  for _, word in ipairs(args) do print(word) end
  return #args
end)

--- Runs the child `name` of this module with `args` and answers how it ended.
local function run(tmp: string, name: string, args: {string}): Child.Result
  local started = this_program.program(test_child.words(tmp, "build.test_child_test", name, args),
    { stdout = "capture", stderr = "capture", timeout_ns = Clock.seconds(30) })
  local result = assert(Child.run(started.argv, started.options))
  return result
end

local function test_a_child_runs_the_modules_own_code_with_the_words_it_is_handed(tmp: string)
  local result = run(tmp, "echo", { "one", "two words", "" })
  assert(result.code == 3 and result.stdout == "one\ntwo words\n\n", tostring(result.code) ..
      tostring(result.stdout) .. tostring(result.stderr))
end

local function test_a_child_nothing_registered_is_refused_by_name(tmp: string)
  local result = run(tmp, "nothing", {})
  assert(result.code == 1 and (result.stderr or ""):find("no child nothing is registered", 1, true) ~= nil,
    tostring(result.stderr))
end

local function test_a_name_is_registered_once()
  local ok, why = pcall(test_child.register, "echo", function(_: {string}): integer return 0 end)
  assert(not ok and tostring(why):find("echo is registered twice", 1, true) ~= nil, tostring(why))
end
