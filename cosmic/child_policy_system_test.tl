--- [`Child.start`]'s `policy` with the "system" profile (cosmic/sandbox/policy.tl)
--- on a host program, a dynamically linked one where the host has them:
--- the profile reads what one needs to run, the start grants the program
--- itself, and nothing past them is reachable.
--- They need a sandbox and /bin/cat of the host (`requires`): where the
--- platform has no sandbox they are not applicable, and where this host's
--- kernel gives no Landlock or seccomp they skip (Test.skip).

local Child = require("cosmic.child")
local Fs = require("cosmic.fs")
local Sandbox = require("cosmic.sandbox")
local Test = require("cosmic.test")
local sys = require("cosmic.sys")
local searchable = require("build.searchable")

--- A host program starts, so the system's own paths are given, and the
--- program itself, which the host must have.
Test.policy{
  profiles = { "system" },
  grants = { { path = "/bin/cat", letters = "r" }, { path = "/bin/sh", letters = "r" } },
  requires = { "sandbox", "path:/bin/cat", "path:/bin/sh" },
}

local CAT <const> = "/bin/cat"

--- Runs `/bin/cat file` under `policy`: its output and status; the test is
--- skipped where this host gives no Landlock or seccomp.
local function cat(policy: Sandbox.Policy, file: string): string, integer
  local result, why = Child.run({ CAT, file }, { timeout_ns = Child.FOREVER, policy = policy, stdout = "capture", stderr = "stdout" })
  if result == nil then
    if why.message:find("Landlock", 1, true) or why.message:find("seccomp", 1, true) or why.message:find("not implemented", 1, true) then
      Test.skip(tostring(why))
    end
    error("the start was refused: " .. tostring(why))
  end
  local out = assert(result.stdout, "stdout = \"capture\" captures it")
  return out, result.code or -1
end

local function test_the_system_profile_lets_a_host_program_read_what_is_granted(tmp: string)
  searchable.open(tmp)
  assert(Fs.mkdirs(tmp .. "/ro"))
  assert(Fs.mkdirs(tmp .. "/other"))
  assert(Fs.write(tmp .. "/ro/a", "alpha\n"))
  assert(Fs.write(tmp .. "/other/b", "beta\n"))
  local policy: Sandbox.Policy = { profiles = { "system" }, grants = { { path = tmp .. "/ro", letters = "r" } } }
  local said, code = cat(policy, tmp .. "/ro/a")
  assert(code == 0 and said == "alpha\n", tostring(code) .. ": " .. said)
  local sibling, status = cat(policy, tmp .. "/other/b")
  assert(status ~= 0 and sibling:find("Permission denied", 1, true) ~= nil, sibling)
  -- The profile reaches the system's own files and no other of the host's.
  if sys.stat("/etc/passwd") ~= nil then
    local passwd, found = cat(policy, "/etc/passwd")
    assert(found == 0 and passwd ~= "", "the system profile grants /etc/passwd")
  end
  local shadow, hidden = cat(policy, "/etc/hostname")
  assert(hidden ~= 0 or shadow == "", "/etc/hostname was read: " .. shadow)
end

--- "system" reads the host's programs and runs none: the start grants
--- the shell it starts and the shell's loader, so the shell runs, and the
--- program the shell runs is refused. "programs" runs it.
local function test_the_system_profile_runs_no_program_and_programs_does(tmp: string)
  local function shell(profiles: {string}): string, integer
    local result, why = Child.run({ "/bin/sh", "-c", CAT .. " " .. tmp .. "/a; echo status=$?" },
      { timeout_ns = Child.FOREVER, policy = { profiles = profiles, promises = { "fork" }, grants = { { path = tmp, letters = "r" } } },
        stdout = "capture", stderr = "stdout" })
    if result == nil then
      if why.message:find("Landlock", 1, true) or why.message:find("seccomp", 1, true) or why.message:find("not implemented", 1, true) then
        Test.skip(tostring(why))
      end
      error("the start was refused: " .. tostring(why))
    end
    return assert(result.stdout, "stdout = \"capture\" captures it"), result.code or -1
  end
  searchable.open(tmp)
  assert(Fs.write(tmp .. "/a", "alpha\n"))
  local refused, code = shell({ "system" })
  assert(code == 0 and refused:find("status=126", 1, true) ~= nil and refused:find("alpha", 1, true) == nil, refused)
  local ran, ran_code = shell({ "system", "programs" })
  assert(ran_code == 0 and ran == "alpha\nstatus=0\n", ran)
end
