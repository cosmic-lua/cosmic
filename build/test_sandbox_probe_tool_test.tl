--- The entry of the program that [`build.test_sandbox_probe`]'s
--- `available` starts once a `cosmic test`
--- (`cosmic test --sandbox-probe <program>`, cmd/cosmic/main.tl): a hold by
--- a Landlock ruleset, and so a host with Landlock's (`requires`).

local Array = require("cosmic.array")
local Child = require("cosmic.child")
local Clock = require("cosmic.clock")
local Test = require("cosmic.test")
local confine = require("build.confine")
local this_program = require("build.this_program")

--- The program itself, which the entry is of.
Test.policy{
  profiles = { "cosmic" },
  grants = { { path = "o/bin", letters = "rx" } },
  requires = { "landlock" },
}

--- Starts the program with `words` and answers how it ended.
local function started(tmp: string, words: {string}): Child.Result
  local start = this_program.program(words, { cwd = tmp, stdout = "capture", stderr = "capture",
    timeout_ns = Clock.seconds(30) })
  local result = assert(Child.run(start.argv, start.options))
  return result
end

--- The words `available` starts the program with are an entry of the
--- program: it holds itself and exits 0, saying nothing. Were they
--- dispatch's to read, `test` would refuse the option and every run's
--- probe would fail as a defect.
local function test_the_entry_holds_the_process_and_exits_0(tmp: string)
  -- `itself` lists the running program first.
  local program = Array.at(confine.itself(), 1)
  local result = started(tmp, { "test", "--sandbox-probe", program })
  assert(result.code == 0, tostring(result.code) .. tostring(result.stderr))
  assert(result.stdout == "" and result.stderr == "", tostring(result.stdout) .. tostring(result.stderr))
end

--- A probe told no program, or more than one, is refused before it
--- holds anything.
local function test_the_entry_refuses_any_other_count_of_programs(tmp: string)
  local refused: {{string}} = { { "test", "--sandbox-probe" }, { "test", "--sandbox-probe", "a", "b" } }
  for _, words in ipairs(refused) do
    local result = started(tmp, words)
    assert(result.code == 2, tostring(result.code))
    assert(result.stderr == "usage: cosmic test --sandbox-probe <program>\n", tostring(result.stderr))
  end
end
