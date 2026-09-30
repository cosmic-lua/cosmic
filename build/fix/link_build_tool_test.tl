--- The case of build/fix/fix_test.tl that runs `cosmic fix` on a
--- project of its own that no build has been made of: what its links
--- name must not turn on whether a `cosmic test` ran first. It declares
--- `tool` because it starts this program.

local Child = require("cosmic.child")
local Fs = require("cosmic.fs")
local this_program = require("build.this_program")
local Test = require("cosmic.test")

--- The program itself, which its test starts.
Test.needs{ tool = true }

local function check(root: string): string
  local started = this_program.program({ "fix", "--check" }, { cwd = root,
    stdout = "capture", stderr = "stdout", timeout_ms = 60000 })
  local result = assert(Child.run(started.argv, started.options))
  assert(not result.ok, result.stdout)
  local out: {string} = {}
  for line in (assert(result.stdout) .. "\n"):gmatch("([^\n]*)\n") do
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
