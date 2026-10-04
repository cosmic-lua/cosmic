--- [`Child.start`]'s `policy` starting this program: granted its own
--- file, it runs as its core by a relaunch, with no shell, cache or
--- promise beyond what the policy gives. A root runner's child runs a
--- shared copy of the core (/tmp/cosmic-sandbox-cores-0) as a user of
--- its own; any other runs its own.

local Child = require("cosmic.child")
local Fs = require("cosmic.fs")
local Proc = require("cosmic.proc")
local Sandbox = require("cosmic.sandbox")
local Test = require("cosmic.test")
local confine = require("build.confine")
local searchable = require("build.searchable")

--- The temporary directory, and this program, which the child runs.
Test.needs{ env = { "TMPDIR" }, tool = true }

--- Whether `why`, a start's failure, is the host giving no sandbox.
local function unsandboxable(why: string): boolean
  for _, word in ipairs({ "Landlock", "seccomp", "not implemented", "namespace", "own /proc" }) do
    if why:find(word, 1, true) then return true end
  end
  return false
end

--- Runs this program under `policy` on `args` from `cwd`: what it printed
--- and how it ended, or nil where the host gives no sandbox (skipped).
local function ran(args: {string}, policy: Sandbox.Policy, cwd: string): Child.Result
  local argv: {string} = { (assert(Proc.executable())) }
  for _, word in ipairs(args) do argv[#argv + 1] = word end
  local result, why = Child.run(argv, { policy = policy, cwd = cwd, stdout = "capture",
    stderr = "capture" })
  if result == nil then
    assert(unsandboxable(why), "the start was refused: " .. why)
    Test.skip(why)
  end
  return result
end

--- A directory every user may write, with a script in it.
local function scripted(tmp: string, text: string): string
  searchable.open(tmp)
  local work = tmp .. "/work"
  assert(Fs.mkdirs(work))
  searchable.share(work)
  assert(Fs.write(work .. "/run.tl", text))
  searchable.share(work .. "/run.tl")
  return work
end

local function test_this_program_runs_under_a_policy_that_grants_its_file(tmp: string)
  if not confine.sandbox_platform() then return end
  local work = scripted(tmp, 'print("ran")\n')
  local result = ran({ work .. "/run.tl" }, { profiles = { "cosmic" },
    grants = { { path = work, letters = "rwc" } } }, work)
  if result == nil then return end
  assert(result.code == 0 and result.stdout == "ran\n", tostring(result.code) .. ": " ..
      tostring(result.stdout) .. tostring(result.stderr))
end

local function test_this_program_ungranted_is_refused(tmp: string)
  if not confine.sandbox_platform() then return end
  local work = scripted(tmp, 'print("ran")\n')
  local result, why = Child.run({ assert(Proc.executable()), work .. "/run.tl" },
    { policy = { grants = { { path = work, letters = "rwc" } } }, cwd = work })
  assert(result == nil and why:find("sandbox:", 1, true), tostring(why))
end

local function test_a_descriptor_the_relaunch_hands_on_is_refused(tmp: string)
  if not confine.sandbox_platform() then return end
  local work = scripted(tmp, 'print("ran")\n')
  local relaunch = assert(Proc.relaunch())
  local taken: integer
  for number in pairs(relaunch.fds) do taken = number end
  if taken == nil then return end
  local result, why = Child.run({ assert(Proc.executable()), work .. "/run.tl" },
    { policy = { profiles = { "cosmic" }, grants = { { path = work, letters = "rwc" } } },
      cwd = work, fds = { [taken] = 0 } })
  assert(result == nil and why:find("relaunch", 1, true), tostring(why))
end
