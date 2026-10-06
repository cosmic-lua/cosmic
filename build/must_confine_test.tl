--- End to end: [`confine.must_confine`] refuses a spawn it cannot hold to
--- what was declared, and a worker a Landlock ruleset holds is refused a
--- root of its own, as `cosmic test` holds a suite to them. Each suite runs
--- in a `cosmic test` of its own: a spawn `must_confine` refuses fails every
--- stand-in running, the one that runs the test included, so what a refusal
--- does to a test is seen from the run that reports it. These refusals are
--- the same on every host, so they run wherever the program does; the cases
--- that need a sandbox to confine a process are in
--- `must_confine_sandboxed_test.tl`.

local Fs = require("cosmic.fs")
local confine = require("build.confine")
local fixture = require("build.must_confine_fixture")
local sys = require("cosmic.sys")
local Test = require("cosmic.test")
local String = require("cosmic.string")

--- What these tests start is this very program, which runs the
--- tool's own modules besides the closure's, in a root of its own
--- (`nests`);; the variables are the ones a run
--- of it reads, which choose how its workers are held.
Test.policy{
  profiles = { "cosmic" },
  grants = { { path = "o/bin", letters = "rx" } },
  promises = { "nest" },
  env = { "COSMIC_SANDBOX", "COSMIC_TEST_SANDBOX" },
}
-- What these tests start is this very program.
confine.confine({ reads = confine.itself() })

local suite_tree, environment, failure_of = fixture.suite_tree, fixture.environment, fixture.failure_of

--- Runs `cosmic test` on `root` with `words` after it, answering what
--- it printed and whether it passed.
local function run(root: string, output: string, env: {string:string},
                   words?: {string}): string, boolean
  local ran = fixture.run(root, output, env, words)
  return ran.text, ran.ok
end

--- What the suites below share: the raw process table, and a way to
--- have it refuse every sandbox, as a kernel with no user namespaces
--- for this user does.
local preamble = [[
local Child = require("cosmic.child")
local Fs = require("cosmic.fs")
local sys = require("cosmic.sys")
local Test = require("cosmic.test")

Test.policy { grants = { { path = "bin/probe", letters = "r" } }, promises = { "nest" } }

local record Confine
  confine: function(declared: {string:{string}} | nil)
  must_confine: function(declared: {string:{string}} | nil)
  call: function(fn: function(any...): (any...), argument?: any, own?: {string}): {string:any}
end
-- The worker's own, which a suite outside the tree cannot require.
local confine = package.loaded["build.confine"] as Confine
local type raw_process = require("cosmic.internal.process")
local type Searcher = function(string): any, any

local function raw(): raw_process
  for _, searcher in ipairs(package.searchers as {Searcher}) do
    local loader, extra = searcher("build.confine")
    if type(loader) == "function" and type(extra) == "table" then
      return extra as raw_process
    end
  end
  error("no raw table")
end

local function refusing(fn: function())
  local process = raw()
  local spawn = process.spawn
  process.spawn = function(path: string, argv: {string}, environment: {string:string} | nil,
                           cwd: string | nil, stdin: integer | nil, stdout: integer | nil,
                           stderr: integer | nil, process_group: boolean,
                           fds?: {integer:integer}, sandbox?: raw_process.Sandbox,
                       credentials?: raw_process.Credentials):
                           integer | nil, string, integer
    if sandbox ~= nil then return nil, "Operation not permitted", sys.EPERM end
    return spawn(path, argv, environment, cwd, stdin, stdout, stderr, process_group, fds, sandbox, credentials)
  end
  local ok, trouble: boolean, any = pcall(fn)
  process.spawn = spawn
  if not ok then error(trouble, 0) end
end
]]

--- The line a run printed for one failing test of the refused suite.
local function failure(text: string, name: string): string | nil
  return failure_of(text, "refused_test", name)
end

--- A spawn `must_confine` refuses does not start, and fails the test
--- that made it, naming the program, the part of the sandbox, why, and
--- the errno's name. It fails a test that passed over the spawn's
--- failure in a stand-in of its own (every running stand-in hears it),
--- and one that raised besides, whose own failure follows. So too a
--- process given more paths than a sandbox unveils; one started with a
--- sandbox of its own that does not unveil and take the network; and one
--- started through a spawn taken during a stand-in that has since ended.
local function test_a_refused_spawn_fails_the_test_whatever_it_made_of_it(tmp: string)
  local root = tmp .. "/root"
  suite_tree(tmp, root)
  assert(Fs.write(root .. "/suite/refused_test.tl", preamble .. [[

--- Refusals are made under a stand-in of the test's own, which
--- for spawn wraps `refusing`'s; the one running the test hears them
--- too.
local function test_passed_over(tmp: string)
  local inner: {string:any} = nil
  refusing(function()
    inner = confine.call(function()
      confine.must_confine({ reads = { "bin/probe" } })
      local ran, _ = Child.run({ "bin/probe", "write " .. tmp .. "/ran ran" })
      confine.confine(nil)
      assert(ran == nil, "an unconfined process ran in its place")
    end, nil, { tmp })
  end)
  assert(Fs.stat(tmp .. "/ran") == nil, "nothing runs in its place")
  assert(not inner.ok, "the inner stand-in's call fails")
end

local function test_raised_too(tmp: string)
  refusing(function()
    local _ = confine.call(function()
      confine.must_confine({ reads = { "bin/probe" } })
      local _, _ = Child.run({ "bin/probe", "exit 0" })
      confine.confine(nil)
    end, nil, { tmp })
  end)
  error("its own failure")
end

local function test_too_many(tmp: string)
  local many: {string} = {}
  for i = 1, 300 do many[i] = tmp .. "/many" .. tostring(i) end
  confine.must_confine({ reads = many })
  local _, _ = Child.run({ "bin/probe", "exit 0" })
  confine.confine(nil)
end

local function test_pledged_alone()
  confine.must_confine({ reads = { "bin/probe" } })
  local _, _ = raw().spawn("bin/probe", { "bin/probe", "exit 0" }, nil, nil, nil, nil, nil, false,
    nil, { pledge = {} })
  confine.confine(nil)
end

local function test_a_policys_grants_alone()
  confine.must_confine({ reads = { "bin/probe" } })
  local _, _ = raw().spawn("bin/probe", { "bin/probe", "exit 0" }, nil, nil, nil, nil, nil, false,
    nil, { grants = {}, promises = {} })
  confine.confine(nil)
end

local function test_stale(tmp: string)
  local taken: any = nil
  local _ = confine.call(function() taken = raw().spawn end, nil, { tmp })
  confine.must_confine({ reads = { "bin/probe" } })
  local spawn = taken as function(string, {string}, any, any, any, any, any, boolean): any
  local _ = spawn("bin/probe", { "bin/probe", "exit 0" }, nil, nil, nil, nil, nil, false)
  confine.confine(nil)
end
]]))
  local text, ok = run(root, tmp .. "/out", environment(nil), { "--all" })
  assert(not ok, text)
  local refused = "must_confine: bin/probe could not start confined: unveil and offline " ..
    "could not be applied: Operation not permitted (EPERM)"
  assert(failure(text, "test_passed_over") == refused, text)
  local raised = assert(failure(text, "test_raised_too"))
  assert(String.starts_with(raised, refused .. "; and then: ") and
      raised:find("its own failure$"), text)
  assert(assert(failure(text, "test_too_many")):find("^must_confine: bin/probe could not start " ..
      "confined: unveil could not be applied: %d+ paths, more than the 256 a sandbox unveils " ..
      "%(EINVAL%)$"), text)
  assert(assert(failure(text, "test_pledged_alone")):find("^must_confine: bin/probe could not " ..
      "start confined: unveil and offline could not be applied: a sandbox of its own that does " ..
      "not unveil and take the network, which must_confine does not add to %(EINVAL%)$"), text)
  assert(assert(failure(text, "test_a_policys_grants_alone")):find("^must_confine: bin/probe " ..
      "could not start confined: unveil and offline could not be applied: a sandbox of its own " ..
      "that does not unveil and take the network, which must_confine does not add to " ..
      "%(EINVAL%)$"), text)
  assert(assert(failure(text, "test_stale")):find("^must_confine: bin/probe could not start " ..
      "confined: unveil and offline could not be applied: started through a spawn taken " ..
      "while an earlier stand%-in ran %(EINVAL%)$"), text)
end

--- A worker a Landlock ruleset holds -- one whose module does not
--- declare `nests` -- cannot give a process a root of its own, whose
--- mounts the kernel refuses under the ruleset: a start in one, through
--- `confine` or a sandbox of its own that unveils, is refused outright,
--- naming `nests`, and fails the test however it took the refusal,
--- rather than fall back to running the process unconfined; so does
--- a run of `cosmic test` that such a worker's process starts, asked to
--- sandbox its workers. Every process of
--- the worker's learns of the hold from its environment
--- ([`confine.held_variable`]), which an unsandboxed run is given here to
--- stand for it, the same on every host; sandboxed, the worker is held
--- by a ruleset in fact (`must_confine_sandboxed_test.tl`).
local function test_a_worker_held_by_landlock_is_refused_a_root_of_its_own(tmp: string)
  local root = tmp .. "/root"
  fixture.held_suite(tmp, root)
  local env = environment(nil)
  env.COSMIC_TEST_SANDBOX = "0"
  env[confine.held_variable] = "suite.outer_test"
  local text, ok = run(root, tmp .. "/held", env, { "--all" })
  assert(not ok and text:find("(2 of 3 failed", 1, true), text)
  local refused = fixture.refusal("suite.outer_test")
  assert(failure_of(text, "held_test", "test_confined") == refused, text)
  assert(failure_of(text, "held_test", "test_own_sandbox") == refused, text)
  -- Asked to sandbox its workers, a run started there refuses to.
  env.COSMIC_TEST_SANDBOX = nil
  text, ok = run(root, tmp .. "/nested", env)
  assert(not ok and text:find("test: this run was started in suite.outer_test's worker, " ..
      "which a Landlock ruleset holds", 1, true) and
      text:find("declare the promise \"nest\" in its Test.policy", 1, true), text)
end

--- Where the platform has no sandbox to confine with, a process under
--- `must_confine` is refused, not run unconfined: its test fails naming
--- the part of the sandbox that could not be applied. This branches on the
--- platform because where it can confine, the process runs held to what was
--- declared, which `must_confine_sandboxed_test.tl` checks (`requires`).
local function test_a_must_confined_process_is_refused_where_no_sandbox_is_given(tmp: string)
  if assert(sys.uname()).sysname == "Linux" then
    Test.skip("a platform with a sandbox answers this where a test requires one")
  end
  local root = tmp .. "/root"
  fixture.confined_suite(tmp, root)
  local text, ok = run(root, tmp .. "/out", environment(nil), { "--all" })
  assert(not ok, text)
  local why = text:match("FAIL  suite%.real_test test_confined: ([^\n]*)")
  assert(why ~= nil and why:find("^must_confine: %S*bin/probe could not start confined: .+ could " ..
      "not be applied: .+ %(E[A-Z0-9]+%)$"), text)
end

--- Where the platform has no sandbox, a `confine` that cannot confine falls
--- back to an unconfined process and its test passes, and stands on a
--- second run. This branches on the platform because where it can
--- confine, COSMIC_SANDBOX=must is checked too, by
--- `must_confine_sandboxed_test.tl` (`requires`).
local function test_a_confine_falls_back_and_stands_where_no_sandbox_is_given(tmp: string)
  if assert(sys.uname()).sysname == "Linux" then
    Test.skip("a platform with a sandbox answers this where a test requires one")
  end
  local root = tmp .. "/root"
  fixture.fallback_suite(tmp, root)
  local text, ok = run(root, tmp .. "/first", environment(nil))
  assert(ok and text:find("1 ran", 1, true), text)
  text, ok = run(root, tmp .. "/stood", environment(nil))
  assert(ok and text:find("0 ran, 1 stood", 1, true), text)
end
