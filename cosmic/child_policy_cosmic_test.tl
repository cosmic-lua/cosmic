--- [`Child.start`]'s `policy` starting this program: granted its own
--- file, it runs as its core by a relaunch, with no shell, cache or
--- promise beyond what the policy gives. A runner that is not root (every
--- sandboxed worker, and CI's) checks that its child runs its own core;
--- the copy a root caller's child runs (/run/cosmic-sandbox-cores) is
--- checked only by a run as root unsandboxed (`COSMIC_TEST_SANDBOX=0`),
--- as cosmic/child_policy_user_test.tl's root cases are, until a leg of
--- CI runs as root.

local Child = require("cosmic.child")
local Fs = require("cosmic.fs")
local Proc = require("cosmic.proc")
local Sandbox = require("cosmic.sandbox")
local Test = require("cosmic.test")
local searchable = require("build.searchable")
local build_paths = require("build.paths")
local ChildPolicy = require("build.child_policy_fixture")

--- The temporary directory, and this program, which the child runs. Every
--- test starts a child under a policy, which a host with no sandbox to give
--- cannot: the module is not applicable off Linux and skipped where Linux
--- refuses it.
Test.policy{
  profiles = { "cosmic" },
  grants = { { path = "o/bin", letters = "rx" } },
  env = { "TMPDIR" },
  requires = { "sandbox" },
}

--- Runs this program under `policy` on `args` from `cwd`: what it printed
--- and how it ended; skips the test where the host gives no sandbox.
local function ran(args: {string}, policy: Sandbox.Policy, cwd: string): Child.Result
  local argv: mut {string} = { (assert(Proc.executable())) }
  for _, word in ipairs(args) do argv[#argv + 1] = word end
  local result, why = Child.run(argv, { timeout_ns = Child.FOREVER, policy = policy, cwd = cwd, stdout = "capture",
    stderr = "capture" })
  if result == nil then
    assert(ChildPolicy.unsandboxable(tostring(why)), "the start was refused: " .. tostring(why))
    Test.skip(tostring(why))
  end
  local held = assert(result, "Test.skip ends the test where the start is refused")
  return held
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
  local work = scripted(tmp, 'print("ran")\n')
  local result = ran({ work .. "/run.tl" }, { profiles = { "cosmic" },
    grants = { { path = work, letters = "rwc" } } }, work)
  assert(result.code == 0 and result.stdout == "ran\n", tostring(result.code) .. ": " ..
      tostring(result.stdout) .. tostring(result.stderr))
end

local function test_this_program_ungranted_is_refused(tmp: string)
  local work = scripted(tmp, 'print("ran")\n')
  local result, why = Child.run({ assert(Proc.executable()), work .. "/run.tl" },
    { timeout_ns = Child.FOREVER, policy = { grants = { { path = work, letters = "rwc" } } }, cwd = work })
  assert(result == nil and why.message:find("sandbox:", 1, true) ~= nil, tostring(why))
end

local function test_a_descriptor_the_relaunch_hands_on_is_refused(tmp: string)
  local work = scripted(tmp, 'print("ran")\n')
  local relaunch = assert(Proc.relaunch())
  local taken: integer?
  for number in pairs(relaunch.fds) do taken = number end
  if taken == nil then
    Test.skip("this relaunch hands on no descriptor")
    return
  end
  local result, why = Child.run({ assert(Proc.executable()), work .. "/run.tl" },
    { timeout_ns = Child.FOREVER, policy = { profiles = { "cosmic" }, grants = { { path = work, letters = "rwc" } } },
      cwd = work, fds = { [taken] = 0 } })
  assert(result == nil and why.message:find("relaunch", 1, true) ~= nil, tostring(why))
end

local function test_this_program_under_nest_is_refused(tmp: string)
  local work = scripted(tmp, 'print("ran")\n')
  local result, why = Child.run({ (assert(Proc.executable())), work .. "/run.tl" },
    { timeout_ns = Child.FOREVER, policy = { profiles = { "cosmic" }, isolate = { "file" }, promises = { "nest" },
      grants = { { path = work, letters = "rwc" } } }, cwd = work })
  assert(result == nil and why.message:find("nest", 1, true) ~= nil and why.message:find("artifact and core", 1, true) ~= nil,
    tostring(why))
end

--- A file this program runs under a policy is run as `--standalone`
--- (COSMIC_STANDALONE), so a grant to read is enough and nothing is
--- written beside it; the policy may say otherwise.
local function test_a_file_runs_standalone_on_a_grant_to_read(tmp: string)
  local work = scripted(tmp, 'return function(argv: {string}): integer\n' ..
      '  print(table.concat(argv, ","))\n  return 0\nend\n')
  local result = ran({ work .. "/run.tl", "one", "two" }, { profiles = { "cosmic" },
    grants = { { path = work, letters = "r" } } }, work)
  assert(result.code == 0 and result.stdout == "one,two\n", tostring(result.code) .. ": " ..
      tostring(result.stdout) .. tostring(result.stderr))
  local names = assert(Fs.list(work))
  assert(#names == 1 and names[1] == "run.tl", "a standalone run wrote beside the file")
end

--- COSMIC_STANDALONE=0 in the policy builds the tree around the file, as
--- a run outside one does: its own modules beside it are found, and its
--- build directory, under the base the policy gives it, is written; a
--- grant to read alone refuses, saying where.
local function test_a_policy_may_build_the_tree_around_the_file(tmp: string)
  local work = scripted(tmp, 'local helper = require("helper")\n' ..
      'return function(argv: {string}): integer\n  print(helper .. (argv[1] or ""))\n  return 0\nend\n')
  assert(Fs.write(work .. "/helper.tl", 'local greeting: string = "from "\nreturn greeting\n'))
  searchable.share(work .. "/helper.tl")
  local home = assert(Fs.absolute(tmp)) .. "/builds"
  assert(Fs.mkdirs(home))
  local built = ran({ work .. "/run.tl", "beside" }, { profiles = { "cosmic" }, set_env = {
    COSMIC_STANDALONE = "0", COSMIC_BUILD_HOME = home }, grants = {
      { path = work, letters = "rwc" }, { path = home, letters = "rwc" } } }, work)
  assert(built.code == 0 and built.stdout == "from beside\n", tostring(built.code) .. ": " ..
      tostring(built.stdout) .. tostring(built.stderr))
  assert(assert(Fs.status(build_paths.required(work, { COSMIC_BUILD_HOME = home }) .. "/build.db")).exists,
    "the tree was not built in its build directory")
  assert(not assert(Fs.status(work .. "/o")).exists, "the tree was built into o/")
  local refused = ran({ work .. "/run.tl", "beside" }, { profiles = { "cosmic" }, grants = {
    { path = work, letters = "r" } } }, work)
  assert(refused.code ~= 0 and tostring(refused.stderr):find("COSMIC_STANDALONE=0", 1, true) ~= nil,
    tostring(refused.code) .. ": " .. tostring(refused.stderr))
end

--- A policy's grants are what the child may do once it runs: the start's
--- `rx` on the core, and the "cosmic" profile's on this program, are the
--- start's, which the core gives up at boot. So a child whose policy has
--- no `x` runs no program, its own core included. On macOS the core
--- applies the policy's Seatbelt profile itself at boot, in place of the
--- start, as macOS applies one profile to a process.
local function test_a_child_with_no_x_cannot_run_its_own_core_again(tmp: string)
  -- TODO: on macOS the trampoline's profile still grants the core `rx`;
  -- the core is to apply the profile itself at boot there too.
  if Sandbox.on_macos() then
    Test.skip("macOS holds a cosmic child by the trampoline's profile, which grants its core rx")
  end
  local work = scripted(tmp, table.concat({
    'local Child = require("cosmic.child")',
    'local Proc = require("cosmic.proc")',
    'local Fs = require("cosmic.fs")',
    'local own: string = assert(Proc.executable())',
    'local programs: {string} = { own }',
    'local link, _ = Fs.status("/proc/self/exe")',
    'if link ~= nil and link.exists then programs = { "/proc/self/exe", own } end',
    'for _, program in ipairs(programs) do',
    '  local result, why = Child.run({ program, "--version" }, { timeout_ns = Child.FOREVER, stdout = "capture", stderr = "capture" })',
    '  print(if result == nil then "refused: " .. tostring(why) else "ran" end)',
    'end',
  }, "\n") .. "\n")
  local result = ran({ work .. "/run.tl" }, { profiles = { "cosmic" }, promises = { "fork" },
    grants = { { path = work, letters = "rwc" } } }, work)
  local out = result.stdout or ""
  local _, refusals = out:gsub("refused: [^\n]*not permitted", "")
  local _, lines = out:gsub("\n", "")
  -- Two on Linux (/proc/self/exe and the core by its path), one on macOS.
  assert(result.code == 0 and refusals >= 1 and refusals == lines,
    tostring(result.code) .. ": " .. out .. tostring(result.stderr))
end
