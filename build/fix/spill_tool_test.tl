--- The cases of build/fix/spill_test.tl that run `cosmic fix` on a
--- project of its own, whose build wraps the assert the checker names
--- and fails the run on any other refusal. It declares `tool` because
--- it starts this program.

local Child = require("cosmic.child")
local Fs = require("cosmic.fs")
local this_program = require("build.this_program")
local Test = require("cosmic.test")
local Clock = require("cosmic.clock")

--- The program itself, which its test starts.
Test.needs{ tool = true }

local function fix(root: string, check: boolean): Child.Result
  local args: {string} = { "fix" }
  if check then args[#args + 1] = "--check" end
  local started = this_program.program(args, { cwd = root,
    stdout = "capture", stderr = "stdout", timeout_ns = Clock.seconds(60) })
  return (assert(Child.run(started.argv, started.options)))
end

--- `cosmic fix` builds the project, wraps the assert the checker names,
--- builds again, and stops once the checker names none; `--check` says
--- so without writing.
local function test_fix_wraps_what_the_checker_names(tmp: string)
  local root = tmp .. "/project"
  assert(Fs.mkdirs(root))
  local source = 'local function read(): string | nil, string return "7", "" end\n' ..
    'return tonumber(assert(read()))\n'
  assert(Fs.write(root .. "/spill.tl", source))
  local checked = fix(root, true)
  assert(not checked.ok and assert(checked.stdout):find("would fix  spill.tl", 1, true),
    checked.stdout)
  assert(Fs.read(root .. "/spill.tl") == source, "--check wrote")
  local fixed = fix(root, false)
  assert(fixed.ok and assert(fixed.stdout):find("fixed  spill.tl", 1, true), fixed.stdout)
  assert(Fs.read(root .. "/spill.tl") == 'local function read(): string | nil, string ' ..
      'return "7", "" end\nreturn tonumber((assert(read())))\n')
  local again = fix(root, false)
  assert(again.ok and assert(again.stdout):find("0 fixed", 1, true), again.stdout)
end

--- A project the build refuses fails the run, `--check` or not, with
--- the compiler's reasons: a PASS read as a tree that builds. Fixed,
--- it passes.
local function test_a_tree_the_build_refuses_fails(tmp: string)
  local root = tmp .. "/project"
  assert(Fs.mkdirs(root))
  assert(Fs.write(root .. "/a.tl", 'local x: integer = "no"\n\nreturn x\n'))
  for _, check in ipairs({ true, false }) do
    local failed = fix(root, check)
    local out = assert(failed.stdout)
    assert(not failed.ok, out)
    assert(out:find("fix: FAIL  a.tl: the compiler refused it\na.tl:1:20: ", 1, true) ~= nil, out)
    assert(out:find("fix: FAIL (the tree not building, ", 1, true) ~= nil, out)
  end
  assert(Fs.write(root .. "/a.tl", 'local x: integer = 1\n\nreturn x\n'))
  local passed = fix(root, false)
  assert(passed.ok, passed.stdout)
end

--- A `--check` counts a spill as a file to fix only in a file it
--- covers: one in another file leaves the tree refused, and fails it.
local function test_a_check_fails_on_a_spill_outside_it(tmp: string)
  local root = tmp .. "/project"
  assert(Fs.mkdirs(root))
  assert(Fs.write(root .. "/a.tl", "local x: integer = 1\n\nreturn x\n"))
  assert(Fs.write(root .. "/b.tl", 'local function read(): string | nil, string return "7", "" end\n' ..
      "return tonumber(assert(read()))\n"))
  local started = this_program.program({ "fix", "--check", "a.tl" }, { cwd = root,
    stdout = "capture", stderr = "stdout", timeout_ns = Clock.seconds(60) })
  local result = assert(Child.run(started.argv, started.options))
  local out = assert(result.stdout)
  assert(not result.ok, out)
  assert(out:find("fix: FAIL  b.tl: the compiler refused it", 1, true) ~= nil, out)
end
