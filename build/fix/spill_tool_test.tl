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
Test.policy{ profiles = { "cosmic" }, grants = { { path = "o/bin", letters = "rx" } } }

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

--- A file that does not parse is refused by its own check and by the
--- build in the same words, which the run says once.
local function test_a_file_that_does_not_parse_is_refused_once(tmp: string)
  local root = tmp .. "/project"
  assert(Fs.mkdirs(root))
  assert(Fs.write(root .. "/a.tl", "local record A\nend\nlocal record A.B\nend\nreturn A\n"))
  local said = "a.tl:3:15: syntax error, expected identifier -- declare " ..
    "`record B ... end` inside `local record A ... end`: it is then A.B, here and in every " ..
    "module that requires this one\n"
  -- Named as the tree names it, and as `fix .` names it (`./a.tl`).
  for _, args in ipairs({ { "fix", "--check" }, { "fix", "--check", "." } }) do
    local started = this_program.program(args, { cwd = root,
      stdout = "capture", stderr = "stdout", timeout_ns = Clock.seconds(60) })
    local out = assert(assert(Child.run(started.argv, started.options)).stdout)
    local _, count = out:gsub("fix: FAIL  [^\n]*" .. said:gsub("%p", "%%%0"), "")
    assert(count == 1, out)
  end
end

--- A template the compiler refuses fails the run with its own
--- `file:line:col`, wherever the build meets it; one under `testdata/`,
--- which the build never makes a module of, is not looked at.
local function test_a_refused_template_fails_unless_it_is_testdata(tmp: string)
  local root = tmp .. "/project"
  assert(Fs.mkdirs(root .. "/testdata"))
  assert(Fs.write(root .. "/testdata/broken.tmpl", "{{broken"))
  assert(Fs.write(root .. "/a.tl", "return 1\n"))
  local passed = fix(root, true)
  assert(passed.ok, passed.stdout)
  assert(Fs.write(root .. "/page.tmpl", "{{type Page from a}}\n<a href={{.x}}>\n"))
  local failed = fix(root, true)
  assert(not failed.ok and assert(failed.stdout):find("page.tmpl:2:9: ", 1, true) ~= nil,
    failed.stdout)
end
