--- [`Child.start`]'s `policy` starting this program: granted its file or
--- not, it runs as its core by a relaunch, with no shell, cache or promise
--- beyond what the policy gives. A runner that is not root (every
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

--- The temporary directory, this program, which the child runs, and
--- `nest`, since a child of `isolate` file is a root of its own, which a
--- worker held by a Landlock ruleset cannot make. Every
--- test starts a child under a policy, which a host with no sandbox to give
--- cannot: the module is not applicable off Linux and skipped where Linux
--- refuses it.
Test.policy{
  profiles = { "cosmic" },
  grants = { { path = "o/bin", letters = "rx" }, { calls = "nest" } },
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

--- This program needs no grant of its own file to start: its core is the start's, as a host program's start is.
local function test_this_program_runs_under_a_policy_that_grants_none_of_it(tmp: string)
  local work = scripted(tmp, 'print("ran")\n')
  local result = ran({ work .. "/run.tl" }, { grants = { { path = work, letters = "rwc" } } }, work)
  assert(result.code == 0 and result.stdout == "ran\n", tostring(result.code) .. ": " ..
      tostring(result.stdout) .. tostring(result.stderr))
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
    { timeout_ns = Child.FOREVER, policy = { grants = { { path = work, letters = "rwc" } } },
      cwd = work, fds = { [taken] = 0 } })
  assert(result == nil and why.message:find("relaunch", 1, true) ~= nil, tostring(why))
end

local function test_this_program_under_nest_is_refused(tmp: string)
  local work = scripted(tmp, 'print("ran")\n')
  local result, why = Child.run({ (assert(Proc.executable())), work .. "/run.tl" },
    { timeout_ns = Child.FOREVER, policy = { isolate = { "file" },
      grants = { { path = work, letters = "rwc" }, { calls = "nest" } } }, cwd = work })
  assert(result == nil and why.message:find("nest", 1, true) ~= nil and why.message:find("artifact and core", 1, true) ~= nil,
    tostring(why))
end

--- A file this program runs under a policy is run as `--standalone`
--- (COSMIC_STANDALONE), so a grant to read is enough and nothing is
--- written beside it; the policy may say otherwise.
local function test_a_file_runs_standalone_on_a_grant_to_read(tmp: string)
  local work = scripted(tmp, 'return function(argv: {string}): integer\n' ..
      '  print(table.concat(argv, ","))\n  return 0\nend\n')
  local result = ran({ work .. "/run.tl", "one", "two" }, { grants = { { path = work, letters = "r" } } }, work)
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
  local built = ran({ work .. "/run.tl", "beside" }, { setup = { set_env = {
    COSMIC_STANDALONE = "0", COSMIC_BUILD_HOME = home } }, grants = {
      { path = work, letters = "rwc" }, { path = home, letters = "rwc" } } }, work)
  assert(built.code == 0 and built.stdout == "from beside\n", tostring(built.code) .. ": " ..
      tostring(built.stdout) .. tostring(built.stderr))
  assert(assert(Fs.status(build_paths.required(work, { COSMIC_BUILD_HOME = home }) .. "/build.db")).exists,
    "the tree was not built in its build directory")
  assert(not assert(Fs.status(work .. "/o")).exists, "the tree was built into o/")
  local refused = ran({ work .. "/run.tl", "beside" }, { grants = {
    { path = work, letters = "r" } } }, work)
  assert(refused.code ~= 0 and tostring(refused.stderr):find("COSMIC_STANDALONE=0", 1, true) ~= nil,
    tostring(refused.code) .. ": " .. tostring(refused.stderr))
end

--- A policy's grants are what the child may do once it runs: the start's
--- `rx` on the core is the start's, which the core gives up at boot. So a child whose policy has
--- no `x` runs no program, its own core included. On macOS the core
--- applies the policy's Seatbelt profile itself at boot, in place of the
--- start, as macOS applies one profile to a process.
local function test_a_child_with_no_x_cannot_run_its_own_core_again(tmp: string)
  -- Linux runs a core by /proc/self/exe as well as by its path.
  local linux = not Sandbox.on_macos()
  local work = scripted(tmp, table.concat({
    'local Child = require("cosmic.child")',
    'local Proc = require("cosmic.proc")',
    'local own: string = assert(Proc.executable())',
    'local programs: {string} = ' .. (if linux then '{ "/proc/self/exe", own }' else '{ own }' end),
    'for _, program in ipairs(programs) do',
    '  local result, why = Child.run({ program, "--version" }, { timeout_ns = Child.FOREVER, stdout = "capture", stderr = "capture" })',
    '  print(if result == nil then "refused: " .. tostring(why) else "ran" end)',
    'end',
  }, "\n") .. "\n")
  local result = ran({ work .. "/run.tl" }, { grants = { { path = work, letters = "rwc" }, { calls = "fork" } } }, work)
  local out = result.stdout or ""
  local _, refusals = out:gsub("refused: [^\n]*not permitted: running \"[^\n]*", "")
  assert(result.code == 0 and refusals == (if linux then 2 else 1 end),
    tostring(result.code) .. ": " .. out .. tostring(result.stderr))
end

--- Under `isolate` file a cosmic child's core holds itself at boot to the
--- grants by their names in the root, without the start's `rx` on itself:
--- a policy with no `x` runs no program, its own core included, by its
--- path or by /proc/self/exe. The root's own /proc and the /tmp of `tmp`
--- are in that layer too, so the child still reads the one and writes the
--- other.
local function test_a_cosmic_child_under_isolate_file_cannot_run_its_own_core_again(tmp: string)
  local work = scripted(tmp, table.concat({
    'local Child = require("cosmic.child")',
    'local Fs = require("cosmic.fs")',
    'local Proc = require("cosmic.proc")',
    'for _, program in ipairs({ "/proc/self/exe", assert(Proc.executable()) }) do',
    '  local result, why = Child.run({ program, "--version" }, { timeout_ns = Child.FOREVER, stdout = "capture", stderr = "capture" })',
    '  print(if result == nil then "refused: " .. tostring(why) else "ran" end)',
    'end',
    'local wrote, _ = Fs.write("/tmp/x", "hi")',
    'print("tmp: " .. tostring(wrote == true))',
    'local status, _ = Fs.read("/proc/self/status")',
    'print("proc: " .. tostring(status ~= nil))',
  }, "\n") .. "\n")
  local held = ran({ work .. "/run.tl" },
    { isolate = { "file" }, setup = { tmp = true }, grants = { { path = work, letters = "r" }, { calls = "fork" } } }, work)
  local out = held.stdout or ""
  local _, refusals = out:gsub("refused: [^\n]*not permitted: running \"[^\n]*", "")
  assert(held.code == 0 and refusals == 2, tostring(held.code) .. ": " .. out .. tostring(held.stderr))
  assert(out:find("tmp: true\n", 1, true) ~= nil and out:find("proc: true\n", 1, true) ~= nil, out)
end

--- Under `isolate` file the root places a grant with no `from` at its
--- real path and reaches its name by a link, which it cannot make where a
--- shorter grant beneath the name was placed first: the core's layer
--- names the real path, as the root places it, so the grant still reads
--- there.
local function test_a_linked_grant_reads_under_isolate_file_beside_a_grant_beneath_it(tmp: string)
  local proj = assert(Fs.absolute(tmp)) .. "/work/very/long/long/path/proj"
  local work = scripted(tmp, 'local Fs = require("cosmic.fs")\n' ..
      'local text, _ = Fs.read(' .. string.format("%q", proj .. "/f") .. ')\nprint("read: " .. tostring(text))\n')
  assert(Fs.mkdirs(proj))
  assert(Fs.mkdirs(work .. "/q/s"))
  assert(Fs.mkdirs(work .. "/z"))
  assert(Fs.write(proj .. "/f", "hi"))
  assert(Fs.symlink(proj, work .. "/z/l"))
  assert(Fs.symlink(work .. "/q/s", proj .. "/s"))
  for _, path in ipairs({ work .. "/very", work .. "/very/long", work .. "/very/long/long",
      work .. "/very/long/long/path", proj, proj .. "/f", work .. "/q", work .. "/q/s", work .. "/z" }) do
    searchable.share(path)
  end
  local held = ran({ work .. "/run.tl" }, { isolate = { "file" }, grants = {
    { path = work .. "/run.tl", letters = "r" }, { path = "z/l", letters = "r" },
    { path = "z/l/s", letters = "r" } } }, work)
  local out = held.stdout or ""
  assert(held.code == 0 and out == "read: hi\n", tostring(held.code) .. ": " .. out .. tostring(held.stderr))
end
