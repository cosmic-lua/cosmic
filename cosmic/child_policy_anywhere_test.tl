--- What a policy refuses before any child exists, and what a platform with no
--- sandbox does, in [`Child.start`]'s `policy` (cosmic/child.tl): the tests
--- of cosmic/child_policy_test.tl, its isolation, `nest`, user and system
--- siblings that hold on every platform, so they run on all of them. What a
--- sandbox does to a live child is in those modules, which `requires` one.

local Child = require("cosmic.child")
local Fs = require("cosmic.fs")
local Sandbox = require("cosmic.sandbox")
local Test = require("cosmic.test")
local sys = require("cosmic.sys")
local confine = require("build.confine")
local searchable = require("build.searchable")
local stand_in = require("build.stand_in")

--- The temporary directory and the environment the tests read; the system's
--- own paths, whose profile one test reads; and `nests`, since a start of
--- these policies is a root of its own where it gets as far as a child, which
--- a worker held by a Landlock ruleset cannot make.
Test.policy{ env = { "TMPDIR" }, promises = { "nest" }, profiles = { "system" } }

--- Whether `why`, a start's failure, is the platform or the host giving no
--- Landlock, seccomp or user namespace.
local function unsandboxable(why: string): boolean
  for _, word in ipairs({ "Landlock", "seccomp", "not implemented", "namespace", "own /proc",
      "root could not be built" }) do
    if why:find(word, 1, true) then return true end
  end
  return false
end

--- Ends the test where this host holds a child by Seatbelt, which refuses
--- what it cannot hold in words of its own, in cosmic/child_seatbelt_test.tl:
--- what a test reads of a refusal here is Landlock's and seccomp's, and
--- the namespaces' advice.
local function skip_where_seatbelt_holds(what: string)
  if assert(sys.uname()).sysname == "Darwin" then
    Test.skip(what .. " is answered in Landlock's and seccomp's words, which macOS does not use: " ..
        "cosmic/child_seatbelt_test.tl has Seatbelt's")
  end
end

--- A grant of the program itself, which a child needs to run at all.
local function itself(program: string, more?: {Sandbox.Grant}): {Sandbox.Grant}
  local grants: {Sandbox.Grant} = { { path = program, letters = "rx" } }
  for _, grant in ipairs(more or {}) do grants[#grants + 1] = grant end
  return grants
end

--- A copy of `grants` with `more` after them.
local function with(grants: {Sandbox.Grant}, ...: Sandbox.Grant): {Sandbox.Grant}
  local out: {Sandbox.Grant} = {}
  for _, grant in ipairs(grants) do out[#out + 1] = grant end
  for _, grant in ipairs({ ... }) do out[#out + 1] = grant end
  return out
end

--- Why a start under `policy` is refused before any child exists.
local function refused(argv: {string}, policy: Sandbox.Policy): string
  local handle, why = Child.start(argv, { policy = policy })
  assert(handle == nil, "the start was not refused")
  return why
end

--- The stand-in, built in the test's directory, which is searchable.
local function stand_in_of(tmp: string): string
  return (assert(stand_in.build(searchable.open(tmp) .. "/stand-in")))
end

--- The directories a policy's `tmp` made that are still in the temporary directory.
local function sandbox_directories(): {string}
  local found: {string} = {}
  for _, name in ipairs((assert(Fs.list(sys.getenv("TMPDIR") or "/tmp")))) do
    if name:find("^cosmic%-sandbox%-") then found[#found + 1] = name end
  end
  return found
end

--- Where the platform has no sandbox (anything but Linux), a start under a
--- policy is refused for that, naming the missing Landlock, seccomp or
--- namespace, and no child runs, whatever the policy holds it to. A platform
--- that has one runs the child, in the modules that `require` it.
local function test_a_start_under_a_policy_is_refused_where_the_platform_has_no_sandbox(tmp: string)
  local sysname = assert(sys.uname()).sysname
  if sysname == "Linux" or sysname == "Darwin" then
    Test.skip("a platform with a sandbox answers this where a test requires one")
  end
  local probe = stand_in_of(tmp)
  local policies: {Sandbox.Policy} = {
    { grants = itself(probe) },
    { isolate = { "proc" }, grants = itself(probe) },
    { isolate = { "file" }, grants = itself(probe) },
    { isolate = { "file" }, promises = { "nest" }, grants = itself(probe) },
    { user = sys.getuid(), grants = itself(probe) },
    { isolate = { "proc" }, limits = { processes = 4 }, grants = itself(probe) },
    { tmp = true, grants = itself(probe) },
    { profiles = { "system" }, grants = itself(probe) },
  }
  for i, policy in ipairs(policies) do
    -- It starts in the directory that holds the probe: under isolate file the
    -- start directory must be at, beneath or above a grant.
    local result, why = Child.run({ probe, "print hi" }, { policy = policy, cwd = probe:match("^(.*)/") })
    assert(result == nil, "policy " .. i .. " started a child where there is no sandbox")
    assert(unsandboxable(why), "policy " .. i .. ": " .. why)
  end
end

local function test_a_program_nobody_granted_does_not_start_and_the_failure_names_the_grant(tmp: string)
  local probe = stand_in_of(tmp)
  local real = assert(sys.realpath(probe))
  local none, why = Child.start({ probe, "print hi" }, { policy = {} })
  assert(none == nil)
  assert(why:find("^child: start: sandbox: "), why)
  assert(why:find(real, 1, true) and why:find("r and x", 1, true), why)
  assert(why:find("system", 1, true) and why:find("the program", 1, true), why)
  -- Read without run names what is missing.
  local read, trouble = Child.start({ probe, "print hi" },
    { policy = { grants = { { path = probe, letters = "r" } } } })
  assert(read == nil and trouble:find("not granted x:", 1, true), trouble)
end

local function test_an_interpreter_must_be_granted_too(tmp: string)
  local probe = stand_in_of(tmp)
  assert(Fs.mkdirs(tmp .. "/scripts"))
  assert(Fs.write(tmp .. "/scripts/run", "#!" .. probe .. "\nprint scripted\n", 493))
  local policy: Sandbox.Policy = { grants = { { path = tmp .. "/scripts", letters = "rx" } } }
  local none, why = Child.start({ tmp .. "/scripts/run" }, { policy = policy })
  assert(none == nil and why:find("interpreter", 1, true) and why:find(assert(sys.realpath(probe)), 1, true), why)
end

local function test_a_program_named_without_a_path_must_be_found(tmp: string)
  local probe = stand_in_of(tmp)
  local none, why = Child.start({ "no-such-program-here" }, { policy = { grants = itself(probe) } })
  assert(none == nil and why:find("no-such-program-here", 1, true), why)
end

local function test_env_beside_a_policy_raises(tmp: string)
  local probe = stand_in_of(tmp)
  local ok, why = pcall(Child.start, { probe }, { policy = { grants = itself(probe) }, env = {} })
  assert(not ok and tostring(why):find("policy and env exclude each other", 1, true), tostring(why))
  local other, trouble = pcall(Child.start, { probe }, { policy = {}, sandbox = { offline = true } })
  assert(not other and tostring(trouble):find("policy and sandbox", 1, true), tostring(trouble))
end

local function test_a_policy_that_is_not_met_fails_naming_the_field(tmp: string)
  skip_where_seatbelt_holds("a policy that is not met")
  local probe = stand_in_of(tmp)
  local base = itself(probe)
  local function grants(): {Sandbox.Grant}
    local copy: {Sandbox.Grant} = {}
    for i, grant in ipairs(base) do copy[i] = grant end
    return copy
  end
  local cases: {{any}} = {
    { { grants = grants(), connect = { "example.com:443" } }, 'connect "example.com:443"' },
    { { grants = grants(), set_env_digests = { X = string.rep("0", 64) } }, 'set_env_digests "X"' },
  }
  for _, case in ipairs(cases) do
    local none, why = Child.start({ probe, "print hi" }, { policy = case[1] as Sandbox.Policy })
    assert(none == nil, case[2])
    assert(why:find("^child: start: sandbox: ") and why:find(case[2] as string, 1, true), why)
    assert(why:find("not yet available", 1, true) or why:find("cannot start", 1, true), why)
  end
  local from = grants()
  from[#from + 1] = { path = "/data", letters = "r", from = "/srv/data" }
  local none, why = Child.start({ probe }, { policy = { grants = from } })
  assert(none == nil and why:find('grant "/data"', 1, true) and why:find("from", 1, true), why)
  assert(why:find('isolate "file"', 1, true), why)
end

local function test_a_policy_that_does_not_merge_fails_naming_the_field(tmp: string)
  local probe = stand_in_of(tmp)
  local none, why = Child.start({ probe }, { policy = { grants = { { path = probe, letters = "q" } } } })
  assert(none == nil and why:find("/grants/0/letters", 1, true), why)
  local profile, trouble = Child.start({ probe }, { policy = { profiles = { "bogus" } } })
  assert(profile == nil and trouble:find("bogus", 1, true), trouble)
end

local function test_a_policy_of_too_many_grants_fails_before_it_makes_anything(tmp: string)
  skip_where_seatbelt_holds("the most grants")
  local probe = stand_in_of(tmp)
  local before = #sandbox_directories()
  for _, count in ipairs({ 256, 300 }) do
    local grants = itself(probe)
    for i = #grants + 1, count do grants[i] = { path = tmp .. "/g" .. i, letters = "r" } end
    local none, why = Child.start({ probe, "print hi" }, { policy = { grants = grants, tmp = true } })
    assert(none == nil and why:find("^child: start: sandbox: grants: ") and why:find("256", 1, true), why)
    assert(#sandbox_directories() == before, count .. " grants left a directory behind")
  end
end

local function test_from_needs_isolate_file_and_what_is_not_met_stays_refused(tmp: string)
  skip_where_seatbelt_holds("what is not met")
  local probe = stand_in_of(tmp)
  local function says(policy: Sandbox.Policy): string
    return refused({ probe, "print hi" }, policy)
  end
  local from = says({ grants = { { path = probe, letters = "rx" },
    { path = "/data", letters = "r", from = tmp } } })
  assert(from:find("from", 1, true) and from:find("isolate", 1, true) and from:find("file", 1, true), from)
  assert(says({ connect = { "example.com:443" } }):find("connect", 1, true))
  assert(says({ promises = { "nest" } }):find("nest", 1, true))
  local counted = says({ limits = { processes = 4 } })
  assert(counted:find("limits.processes", 1, true) and counted:find("isolate", 1, true), counted)
  -- /tmp is the sandbox's own where tmp asks for it.
  local clash = says({ isolate = { "file" }, tmp = true, grants = {
    { path = probe, letters = "rx" }, { path = "/tmp", letters = "r" } } })
  assert(clash:find("/tmp", 1, true) and clash:find("tmp", 1, true), clash)
  local proc = says({ isolate = { "file" }, grants = {
    { path = probe, letters = "rx" }, { path = "/proc", letters = "r", from = tmp } } })
  assert(proc:find("/proc", 1, true) and proc:find("from", 1, true), proc)
end

--- The grants, and the directory beside them, of the nest refusals below: the
--- program, a working directory, one that can be written and one, `extra`,
--- that only the first sandbox is given.
local function nest_grants(tmp: string): {Sandbox.Grant}, string, string
  local probe = stand_in_of(tmp)
  local work = tmp .. "/work"
  assert(Fs.mkdirs(work .. "/rw") and Fs.mkdirs(tmp .. "/extra"))
  return { { path = probe, letters = "rx" }, { path = work, letters = "r" },
    { path = work .. "/rw", letters = "rwc" } }, probe, tmp .. "/extra"
end

local function test_nest_needs_isolate_file_and_says_so(tmp: string)
  skip_where_seatbelt_holds("nest")
  local grants, probe = nest_grants(tmp)
  for _, isolate in ipairs({ {}, { "proc" } }) do
    local why = refused({ probe }, { isolate = isolate, promises = { "nest" }, grants = grants })
    assert(why:find("nest", 1, true) and why:find("isolate \"file\"", 1, true), why)
  end
end

local function test_nest_refuses_what_a_root_cannot_hold(tmp: string)
  skip_where_seatbelt_holds("nest")
  local grants, probe, extra = nest_grants(tmp)
  local function without(letters: string, path: string): string
    return refused({ probe }, { isolate = { "file" }, promises = { "nest" },
      grants = with(grants, { path = path, letters = letters }) })
  end
  -- Landlock told writing a file from making one in a directory, and running
  -- from reading; a bind does not.
  local made = without("w", extra)
  assert(made:find("add `c`", 1, true) and made:find("nest", 1, true), made)
  local run = without("x", extra)
  assert(run:find("add `r`", 1, true), run)
  local created = without("c", extra)
  assert(created:find("add `w`", 1, true), created)
end

--- A root caller that cannot map the user its child runs as is refused
--- before any child, naming why. It needs a worker that is root whose
--- capabilities lack CAP_SETUID, CAP_SETGID or CAP_SETFCAP in effect, so it
--- is skipped (Test.skip) where the worker is not root, as in every
--- sandboxed run, and where root can map, which is the host that runs the
--- tests of a root caller in cosmic/child_policy_root_user_test.tl.
-- The TODO in cosmic/child_policy_root_user_test.tl, on requiring `root`, holds here too.
local function test_a_root_caller_that_cannot_map_a_user_fails_naming_why()
  if sys.getuid() ~= 0 then
    Test.skip("this worker is not root: a root run sandboxes its workers as users of their own")
    return
  end
  if confine.may_map_ids() then
    Test.skip("this process can map the user a sandbox runs as, so none of its starts is refused for it")
    return
  end
  local handle, why = Child.start({ "/bin/true" }, { policy = { isolate = { "proc" }, profiles = { "system" } }, cwd = "/" })
  assert(handle == nil, "the start was not refused")
  assert(why:find("never runs as root", 1, true) and why:find("CAP_SETFCAP", 1, true), why)
end

--- A program and a directory to start it in.
local function place(tmp: string): string, string
  local probe = stand_in_of(tmp)
  local work = assert(Fs.mkdirs(tmp .. "/work") and tmp .. "/work")
  return probe, work
end

local function test_processes_without_isolation_fails_naming_what_it_needs(tmp: string)
  skip_where_seatbelt_holds("limits.processes")
  local probe = place(tmp)
  local why = refused({ probe, "print hi" }, { grants = { { path = probe, letters = "rx" } },
    limits = { processes = 8 } })
  assert(why:find("^child: start: sandbox: limits.processes") and why:find("isolate", 1, true), why)
end

local function test_processes_above_the_callers_hard_limit_fails_naming_it(tmp: string)
  skip_where_seatbelt_holds("limits.processes")
  local probe, work = place(tmp)
  local hard = assert(sys.getrlimit(sys.RLIMIT_NPROC)).hard
  if hard == math.maxinteger then return end
  local why = refused({ probe, "print hi" }, { isolate = { "proc" }, grants = {
    { path = probe, letters = "rx" }, { path = work, letters = "r" } },
    limits = { processes = hard + 1 } })
  if Sandbox.counts_per_namespace(assert(sys.uname()).release) then
    assert(why:find("hard limit on processes", 1, true), why)
  else
    assert(why:find("Linux 5.17", 1, true), why)
  end
end

local function test_every_path_of_the_profile_exists_and_is_read_only_or_run()
  local system = assert(Sandbox.profile("system"))
  assert(#system.grants > 0 or sys.stat("/usr") == nil)
  for _, grant in ipairs(system.grants) do
    assert(sys.stat(grant.path) ~= nil, grant.path)
    assert(not grant.letters:find("[wcu]") or grant.path == "/dev/null", grant.path .. " grants " .. grant.letters)
  end
end
