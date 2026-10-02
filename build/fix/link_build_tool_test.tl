--- The case of build/fix/fix_test.tl that runs `cosmic fix` on a
--- project of its own that no build has been made of: what its links
--- name must not turn on whether a `cosmic test` ran first. It declares
--- `tool` because it starts this program.

local Child = require("cosmic.child")
local Fs = require("cosmic.fs")
local this_program = require("build.this_program")
local Test = require("cosmic.test")
local String = require("cosmic.string")
local Time = require("cosmic.time")

--- The program itself, which its test starts.
Test.needs{ tool = true }

local function check(root: string): string
  local started = this_program.program({ "fix", "--check" }, { cwd = root,
    stdout = "capture", stderr = "stdout", timeout_ns = Time.seconds(60) })
  local result = assert(Child.run(started.argv, started.options))
  assert(not result.ok, result.stdout)
  local out: {string} = {}
  for line in String.lines(assert(result.stdout)) do
    if line:find(": link: ", 1, true) ~= nil then out[#out + 1] = line end
  end
  return table.concat(out, "\n")
end

--- A project with no `o/` yet: `fix --check` builds it before reading
--- what a link names, so a link through a module's alias resolves and
--- a plain span naming one of its symbols would link, as a check after
--- that build says too.
local function test_fix_links_alike_before_and_after_a_build(tmp: string)
  local root = tmp .. "/project"
  assert(Fs.mkdirs(root))
  assert(Fs.write(root .. "/other.tl", "local record other\nend\n\n--- Answers one.\n" ..
    "function other.thing(): integer\n  return 1\nend\n\nreturn other\n"))
  assert(Fs.write(root .. "/a.tl", 'local Other = require("other")\n\n' ..
    "--- Two, from [`Other.thing`] and `Other.thing`.\n" ..
    "local function two(): integer\n  return Other.thing() + 1\nend\n\nreturn two\n"))
  local want = "fix: FAIL  a.tl:3: link: `Other.thing` would link to other.thing"
  local fresh = check(root)
  assert(fresh == want, "fresh:\n" .. fresh)
  local built = check(root)
  assert(built == want, "built:\n" .. built)
end

--- A project whose build fails (a type error in one file) still checks
--- a link through an alias to a standard library module: one the
--- module lacks fails, though the project's own symbols are unknown.
local function test_a_failed_build_still_checks_a_standard_librarys_members(tmp: string)
  local root = tmp .. "/project"
  assert(Fs.mkdirs(root))
  assert(Fs.write(root .. "/a.tl", 'local Fs = require("cosmic.fs")\n\n--- Reads with [`Fs.nosuch`].\n' ..
    'local function f(): string return (Fs.read("x")) end\n\nreturn f\n'))
  assert(Fs.write(root .. "/b.tl", 'local x: integer = "no"\n\nreturn x\n'))
  local found = check(root)
  assert(found == "fix: FAIL  a.tl:3: link: Fs.nosuch does not resolve (cosmic.fs has no nosuch)",
    found)
end

--- A project whose build fails, met while resolving a link to a
--- symbol, fails the run: the compiler's refusal is on stderr, and a
--- PASS after it read as a tree that builds. Fixed, the same run passes.
local function test_a_failed_build_fails_the_run(tmp: string)
  local root = tmp .. "/project"
  assert(Fs.mkdirs(root))
  assert(Fs.write(root .. "/a.tl", 'local Fs = require("cosmic.fs")\n\n--- Reads with [`Fs.read`].\n' ..
    'local function f(): string return (Fs.read("x")) end\n\nreturn f\n'))
  assert(Fs.write(root .. "/b.tl", 'local x: integer = "no"\n\nreturn x\n'))
  local function run(): Child.Result
    local started = this_program.program({ "fix" }, { cwd = root,
      stdout = "capture", stderr = "capture", timeout_ns = Time.seconds(60) })
    return (assert(Child.run(started.argv, started.options)))
  end
  local failed = run()
  local out = assert(failed.stdout)
  assert(not failed.ok, out)
  assert(out:find("fix: FAIL  links: not rebuilt, resolved from the last build: b.tl: ", 1, true) ~= nil, out)
  assert(out:find("fix: FAIL (the tree not building, ", 1, true) ~= nil, out)
  assert(Fs.write(root .. "/b.tl", 'local x: integer = 1\n\nreturn x\n'))
  local passed = run()
  assert(passed.ok, tostring(passed.stdout) .. tostring(passed.stderr))
end
