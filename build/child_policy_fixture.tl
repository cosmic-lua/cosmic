--- What the tests of [`Child.start`]'s `policy` on a live child share
--- (cosmic/child_policy_*_test.tl): when a start's refusal is the host
--- giving no sandbox, and a stand-in run under a policy. Test support.

local Child = require("cosmic.child")
local Fs = require("cosmic.fs")
local Sandbox = require("cosmic.sandbox")
local Test = require("cosmic.test")
local sys = require("cosmic.sys")
local searchable = require("build.searchable")
local stand_in = require("build.stand_in")

local record child_policy_fixture
  --- What a script left and how its program ended.
  record Outcome
    code: integer
    said: string
  end

  --- The program, a working directory and a directory every user may search.
  record Place
    probe: string
    work: string
  end
end

--- Whether `why`, a start's failure, is the platform or the host giving no
--- Landlock, seccomp, user namespace, root or idmapped mount (a container's
--- runtime may refuse one on a file system that supports it).
--- @param why the start's failure
--- @return whether the host, not the policy, is what refused
function child_policy_fixture.unsandboxable(why: string): boolean
  for _, word in ipairs({ "Landlock", "seccomp", "not implemented", "namespace", "own /proc",
      "root could not be built", "an idmapped mount of " }) do
    if why:find(word, 1, true) then return true end
  end
  return false
end

--- Runs `script` in `program` under `policy`, starting in `cwd`: its output
--- (stderr beside stdout) and how it ended. Skips the test where the host
--- gives no sandbox; fails it where the start is refused for another
--- reason, which `refused` is told.
--- @param program the program, which takes `script` as its one argument
--- @param policy the policy to start it under
--- @param cwd the directory it starts in
--- @param script what it is told to do
--- @return how it ended
function child_policy_fixture.under(program: string, policy: Sandbox.Policy, cwd: string, script: string): child_policy_fixture.Outcome
  local result, why = Child.run({ program, script },
    { policy = policy, cwd = cwd, stdout = "capture", stderr = "stdout" })
  if result == nil then
    assert(child_policy_fixture.unsandboxable(why), "the start was refused: " .. why)
    Test.skip(why)
    error("Test.skip ends the test where it is called")
  end
  return { code = result.code or -1, said = result.stdout or "" }
end

--- Why a start under `policy` is refused, "" for none. Skips the test where
--- the refusal is the host's.
--- @param program the program to start
--- @param policy the policy to start it under
--- @param cwd the directory it starts in
--- @return the refusal
function child_policy_fixture.refused(program: string, policy: Sandbox.Policy, cwd: string): string
  local handle, why = Child.start({ program, "print hi" }, { policy = policy, cwd = cwd })
  if handle ~= nil then
    local _, _ = handle:wait()
    return ""
  end
  -- A refusal of the policy itself is the answer; the host's is a skip.
  if child_policy_fixture.unsandboxable(why) and not why:find("^child: start: sandbox: ") then
    Test.skip(why)
  end
  return why
end

--- A permission mode written in octal.
local function octal(text: string): integer
  return assert(math.tointeger(tonumber(text, 8)))
end

--- Builds the stand-in and a working directory in `tmp`, opened to
--- everyone as a sandbox's own user needs it of the host's tree, whatever
--- the umask they were made under.
--- @param tmp the test's temporary directory
--- @return the stand-in and the working directory
function child_policy_fixture.placed(tmp: string): child_policy_fixture.Place
  searchable.open(tmp)
  local probe = assert(stand_in.build(tmp .. "/stand-in"))
  assert(sys.chmod(probe, octal("755")))
  searchable.open(Fs.dirname(probe))
  local work = tmp .. "/work"
  assert(Fs.mkdirs(work))
  assert(sys.chmod(work, octal("755")))
  return { probe = probe, work = work }
end

return child_policy_fixture
