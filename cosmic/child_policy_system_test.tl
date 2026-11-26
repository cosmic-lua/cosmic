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
  local policy: Sandbox.Policy = { grants = { { profile = "system" }, { path = tmp .. "/ro", letters = "r" } } }
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

--- A grant of each of `profiles`, then `grants`.
local function with_profiles(profiles: {string}, grants: {Sandbox.Grant}): {Sandbox.Grant}
  local out: mut {Sandbox.Grant} = {}
  for _, profile in ipairs(profiles) do out[#out + 1] = { profile = profile } end
  for _, grant in ipairs(grants) do out[#out + 1] = grant end
  return out
end

--- "system" reads the host's programs and runs none: the start grants
--- the shell it starts and the shell's loader, so the shell runs, and the
--- program the shell runs is refused. "programs" runs it.
local function test_the_system_profile_runs_no_program_and_programs_does(tmp: string)
  local function shell(profiles: {string}): string, integer
    local result, why = Child.run({ "/bin/sh", "-c", CAT .. " " .. tmp .. "/a; echo status=$?" },
      { timeout_ns = Child.FOREVER, policy = { grants = with_profiles(profiles, { { path = tmp, letters = "r" }, { calls = "fork" } }) },
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
  -- Where one file is both the shell and the program (busybox, as on
  -- Alpine), the start's grant of the shell runs the program too.
  local cat_real, _ = sys.realpath(CAT)
  local sh_real, _ = sys.realpath("/bin/sh")
  if cat_real ~= nil and cat_real == sh_real then
    assert(code == 0 and refused == "alpha\nstatus=0\n", refused)
  else
    assert(code == 0 and refused:find("status=126", 1, true) ~= nil and refused:find("alpha", 1, true) == nil, refused)
  end
  local ran, ran_code = shell({ "system", "programs" })
  assert(ran_code == 0 and ran == "alpha\nstatus=0\n", ran)
end

--- A limit this records, not a guard: no `x` stops an execve, and the
--- start grants the shell's ELF loader, which runs any program the policy
--- lets be read, so under "system" alone `ld.so /bin/cat` still runs cat.
--- A start that applies the policy after the program has started would
--- grant no loader, and would make this fail.
local function test_the_elf_loader_runs_a_readable_program_with_no_x(tmp: string)
  local files = assert(Sandbox.loaders("/bin/sh"))
  local loader = files[#files]
  if #files < 2 or loader == nil or not loader:find("ld", 1, true) then
    Test.skip("/bin/sh starts through no ELF loader on this host")
    return
  end
  searchable.open(tmp)
  assert(Fs.write(tmp .. "/a", "alpha\n"))
  local result, why = Child.run({ "/bin/sh", "-c", loader .. " " .. CAT .. " " .. tmp .. "/a" },
    { timeout_ns = Child.FOREVER, policy = { grants = { { profile = "system" }, { path = tmp, letters = "r" }, { calls = "fork" } } },
      stdout = "capture", stderr = "stdout" })
  if result == nil then
    if why.message:find("Landlock", 1, true) or why.message:find("seccomp", 1, true) or why.message:find("not implemented", 1, true) then
      Test.skip(tostring(why))
    end
    error("the start was refused: " .. tostring(why))
  end
  assert(result.code == 0 and result.stdout == "alpha\n", tostring(result.stdout))
end

--- The start grants no file the policy lets the program change: one a
--- `w` or `c` grant covers could be rewritten and then run, so it needs
--- an `x` grant of its own, and is refused without one.
local function test_the_start_grants_no_program_the_policy_lets_be_written(tmp: string)
  searchable.open(tmp)
  assert(Fs.mkdirs(tmp .. "/w"))
  local script = tmp .. "/w/run.sh"
  assert(Fs.write(script, "#!/bin/sh\necho ran\n"))
  assert(Fs.chmod(script, 493))
  local function start(letters: string): string
    local result, why = Child.run({ script }, { timeout_ns = Child.FOREVER, stdout = "capture", stderr = "stdout",
      policy = { grants = { { profile = "system" }, { path = tmp .. "/w", letters = letters } } } })
    if result == nil then
      if why.message:find("Landlock", 1, true) or why.message:find("seccomp", 1, true) or why.message:find("not implemented", 1, true) then
        Test.skip(tostring(why))
      end
      return why.message
    end
    return assert(result.stdout)
  end
  assert(start("r") == "ran\n", "a program only read is granted by the start")
  local refused = start("rwc")
  assert(refused:find("is not granted x", 1, true) ~= nil, refused)
  assert(start("rwxc") == "ran\n", "an x grant of its own runs it")
end
