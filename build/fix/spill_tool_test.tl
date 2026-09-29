--- The case of build/fix/spill_test.tl that runs `cosmic fix` on a
--- project of its own, which wraps the assert the checker names. It
--- declares `tool` because it starts this program.

local Child = require("cosmic.child")
local Fs = require("cosmic.fs")
local this_program = require("build.this_program")
local Test = require("cosmic.test")

--- The program itself, which its test starts.
Test.needs{ tool = true }

local function fix(root: string, check: boolean): Child.Result
  local args: {string} = { "fix" }
  if check then args[#args + 1] = "--check" end
  local started = this_program.program(args, { cwd = root,
    stdout = "capture", stderr = "stdout", timeout_ms = 60000 })
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
