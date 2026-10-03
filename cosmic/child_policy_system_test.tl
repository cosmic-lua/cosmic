--- [`Child.start`]'s `policy` with the "system" profile (cosmic/sandbox.tl)
--- on a host program, a dynamically linked one where the host has them:
--- the profile is what lets one start, and nothing past it is reachable.
--- A host whose kernel gives no Landlock or seccomp, and every platform
--- but Linux, skips them (build.sandbox_skip).

local Child = require("cosmic.child")
local Fs = require("cosmic.fs")
local Sandbox = require("cosmic.sandbox")
local Test = require("cosmic.test")
local sys = require("cosmic.sys")
local sandbox_skip = require("build.sandbox_skip")

--- A host program starts, so the system's own paths are given.
Test.needs{ system = true }

local CAT <const> = "/bin/cat"

--- Runs `/bin/cat file` under `policy`: its output and status, or nil,
--- having skipped the test, where the host gives no sandbox.
local function cat(policy: Sandbox.Policy, file: string): string, integer
  local result, why = Child.run({ CAT, file }, { policy = policy, stdout = "capture", stderr = "stdout" })
  if result == nil then
    if why:find("Landlock", 1, true) or why:find("seccomp", 1, true) or why:find("not implemented", 1, true) then
      sandbox_skip.refused(why)
      return nil, -1
    end
    error("the start was refused: " .. why)
  end
  return result.stdout, result.code or -1
end

local function test_the_system_profile_lets_a_host_program_read_what_is_granted(tmp: string)
  if sys.stat(CAT) == nil then return end
  assert(Fs.mkdirs(tmp .. "/ro") and Fs.mkdirs(tmp .. "/other"))
  assert(Fs.write(tmp .. "/ro/a", "alpha\n") and Fs.write(tmp .. "/other/b", "beta\n"))
  local policy: Sandbox.Policy = { profiles = { "system" }, grants = { { path = tmp .. "/ro", letters = "r" } } }
  local said, code = cat(policy, tmp .. "/ro/a")
  if said == nil then return end
  assert(code == 0 and said == "alpha\n", code .. ": " .. said)
  local sibling, status = cat(policy, tmp .. "/other/b")
  assert(status ~= 0 and sibling:find("Permission denied", 1, true), sibling)
  -- The profile reaches the system's own files and no other of the host's.
  if sys.stat("/etc/passwd") ~= nil then
    local passwd, found = cat(policy, "/etc/passwd")
    assert(found == 0 and passwd ~= "", "the system profile grants /etc/passwd")
  end
  local shadow, hidden = cat(policy, "/etc/hostname")
  assert(hidden ~= 0 or shadow == "", "/etc/hostname was read: " .. shadow)
end

local function test_without_the_profile_the_loader_is_not_granted_and_the_start_says_so(tmp: string)
  if sys.stat(CAT) == nil then return end
  local real = assert(sys.realpath(CAT))
  local none, why = Child.start({ CAT, tmp }, { policy = { grants = { { path = real, letters = "rx" } } } })
  -- A static program, as on some hosts, needs nothing more and starts.
  if none ~= nil then return end
  assert(why:find("^child: start: sandbox: ") and why:find("interpreter", 1, true), why)
  assert(why:find("system", 1, true), why)
end

local function test_every_path_of_the_profile_exists_and_is_read_only_or_run()
  local system = assert(Sandbox.profile("system"))
  assert(#system.grants > 0 or sys.stat("/usr") == nil)
  for _, grant in ipairs(system.grants) do
    assert(sys.stat(grant.path) ~= nil, grant.path)
    assert(not grant.letters:find("[wcu]") or grant.path == "/dev/null", grant.path .. " grants " .. grant.letters)
  end
end
