--- What `cosmic fix` does under `COSMIC_GRAMMAR=new` on a project of its own: whether the tree builds is the new
--- checker's to say, in its words, and an `assert(...)` that spills is left alone (the wrapping is the fork's). It
--- declares `tool` because it starts this program.

local Child = require("cosmic.child")
local Clock = require("cosmic.clock")
local Fs = require("cosmic.fs")
local this_program = require("build.this_program")
local Test = require("cosmic.test")

--- The program itself, which its test starts.
Test.policy{ profiles = { "cosmic" }, grants = { { path = "o/bin", letters = "rx" } } }

--- `cosmic fix`, with `--check` where `check`, in `root`, compiling with the new checker, and what it said.
local function fix_new(root: string, check: boolean): Child.Result, string
  local words = check and { "fix", "--check" } or { "fix" }
  local env = this_program.environment()
  env["COSMIC_GRAMMAR"] = "new"
  local started = this_program.program(words, { cwd = root, env = env,
    stdout = "capture", stderr = "stdout", timeout_ns = Clock.seconds(120) })
  local result = assert(Child.run(started.argv, started.options))
  return result, result.stdout or ""
end

--- A project the new checker refuses fails the run, `--check` or not, in the checker's words (a code and its fix); fixed,
--- it passes.
local function test_a_tree_the_new_checker_refuses_fails_in_its_words(tmp: string)
  local root = tmp .. "/project"
  assert(Fs.mkdirs(root))
  assert(Fs.write(root .. "/a.tl", 'local x: integer = "no"\n\nreturn x\n'))
  for _, check in ipairs({ true, false }) do
    local failed, out = fix_new(root, check)
    assert(not failed.ok, out)
    assert(out:find("a.tl:1:", 1, true) ~= nil and out:find("): ", 1, true) ~= nil, out)
    assert(out:find("fix: the tree not building, ", 1, true) ~= nil, out)
  end
  assert(Fs.write(root .. "/a.tl", "local x: integer = 1\n\nreturn x\n"))
  local passed, out = fix_new(root, false)
  assert(passed.ok, out)
end

--- An `assert(...)` that passes on a second value is not wrapped in parentheses: the fork's checker names the spill and
--- `cosmic fix` writes the fix, the new checker's refusal is the run's failure, in its own words.
local function test_a_spilling_assert_is_refused_by_the_new_checker_and_left_as_written(tmp: string)
  local root = tmp .. "/project"
  assert(Fs.mkdirs(root))
  local source = 'local function read(): string | nil, string return "7", "" end\n' ..
    "return tonumber(assert(read()))\n"
  assert(Fs.write(root .. "/spill.tl", source))
  for _, check in ipairs({ true, false }) do
    local failed, out = fix_new(root, check)
    assert(not failed.ok, out)
    assert(out:find("spill.tl:2:8: no overload of `tonumber`", 1, true) ~= nil, out)
    assert(out:find("(overload_none)", 1, true) ~= nil, out)
    assert(out:find("fixed  spill.tl", 1, true) == nil and out:find("would fix  spill.tl", 1, true) == nil, out)
    assert(Fs.read(root .. "/spill.tl") == source, "the file was written")
  end
end
