--- End to end: `confine.must_confine`, and COSMIC_SANDBOX=must,
--- which makes every `confine` one, as `cosmic test` holds a suite to
--- them. Each suite runs in a `cosmic test` of its own: a spawn
--- `must_confine` refuses fails every capture running, the one that
--- runs the test included, so what a refusal does to a test is seen
--- from the run that reports it.

local Child = require("cosmic.child")
local Env = require("cosmic.env")
local Fs = require("cosmic.fs")
local confine = require("build.confine")
local stand_in = require("build.stand_in")
local this_program = require("build.this_program")
local Test = require("cosmic.test")

--- What these tests start is this very program, which runs the
--- tool's own modules besides the closure's, in a root of its own
--- (`nests`); and what holds a run to sandboxing (`unsandboxed`).
Test.needs{
  env = { "COSMIC_SANDBOX", "COSMIC_CI_REQUIRE_SANDBOX", "COSMIC_TEST_SANDBOX" },
  tool = true,
  nests = true,
}

-- What these tests start is this very program.
confine.confine({ reads = confine.itself() })

--- Makes `root`, a tree for a suite, with a stand-in program
--- (build/stand_in.tl) at bin/probe for its tests to start, which
--- declare it: in the tree, since a sandboxed worker has a /tmp of its
--- own over this test's.
local function suite_tree(tmp: string, root: string)
  assert(Fs.mkdirs(root .. "/suite"))
  assert(Fs.mkdirs(root .. "/bin"))
  assert(stand_in.place(assert(stand_in.build(tmp .. "/stand-in")), root .. "/bin/probe"))
end

--- Runs `cosmic test` on `root` with `words` after it, answering what
--- it printed and whether it passed.
local function run(root: string, output: string, env: {string:string},
                   words?: {string}): string, boolean
  local fd = assert(Fs.open_write(output))
  local args: {string} = { "test" }
  for _, word in ipairs(words or {}) do args[#args + 1] = word end
  local started = this_program.program(args, {
    cwd = root, env = env, stdout = fd, stderr = fd,
    process_group = true, timeout_ms = 60000,
  })
  local result, trouble = Child.run(started.argv, started.options)
  assert(Fs.close(fd))
  local text = assert(Fs.read(output))
  assert(result ~= nil, tostring(trouble) .. text)
  return text, result.ok
end

--- Whether the run that printed `text` sandboxed none of its workers,
--- where that is allowed. The workers, and what they confine, nest in
--- this test's own sandbox, which a host may refuse (the kernel lets
--- root nest one only two deep: core/syscalls.c's `map_ids`); a case of a
--- confined process then has only the refusal to check. A run held to
--- sandboxing fails instead (COSMIC_TEST_SANDBOX=1, as CI's suites set
--- it, COSMIC_SANDBOX=must or COSMIC_CI_REQUIRE_SANDBOX=1): CI's
--- unprivileged runners nest them.
local function unsandboxed(text: string): boolean
  if text:find("; sandboxed)", 1, true) then return false end
  assert(not confine.held_to_sandbox(),
    "the run is held to sandboxing, but the run it started was not:\n" .. text)
  return true
end

--- The environment a suite runs in: the pinned one, with no verdict cache
--- shared, COSMIC_SANDBOX as `mode` has it, and its workers sandboxed
--- where they can be, whatever this run's switch: this one's own
--- sandbox may refuse theirs, which a run that requires one would fail
--- on.
local function environment(mode: string | nil): {string:string}
  local env = this_program.environment()
  env.COSMIC_VERDICT_CACHE = "0"
  env.COSMIC_TEST_ALL = nil
  env.COSMIC_TEST_SANDBOX = nil
  env.COSMIC_SANDBOX = mode
  return env
end

--- What the suites below share: the raw process table, and a way to
--- have it refuse every sandbox, as a kernel with no user namespaces
--- for this user does.
local preamble = [[
local Child = require("cosmic.child")
local Fs = require("cosmic.fs")
local sys = require("cosmic.sys")
local Test = require("cosmic.test")

Test.needs { reads = { "bin/probe" }, nests = true }

local record Run
  passed: boolean
end
local record Confine
  confine: function(declared: {string:{string}} | nil)
  must_confine: function(declared: {string:{string}} | nil)
end
local record Observations
  call: function(fn: function(any...): (any...), argument: any, resolving?: {string:any}): Run
end
-- The worker's own, which a suite outside the tree cannot require.
local confine = package.loaded["build.confine"] as Confine
local observations = package.loaded["build.filesystem_observations"] as Observations
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
                           fds?: {integer:integer}, sandbox?: raw_process.Sandbox):
                           integer | nil, string, integer
    if sandbox ~= nil then return nil, "Operation not permitted", sys.EPERM end
    return spawn(path, argv, environment, cwd, stdin, stdout, stderr, process_group, fds)
  end
  local ok, trouble: boolean, any = pcall(fn)
  process.spawn = spawn
  if not ok then error(trouble, 0) end
end
]]

--- The line a run printed for one failing test of `module`, from its
--- message on.
local function failure_of(text: string, module: string, name: string): string | nil
  return text:match("FAIL  suite%." .. module .. " " .. name .. ": ([^\n]*)")
end

--- The line a run printed for one failing test of the refused suite.
local function failure(text: string, name: string): string | nil
  return failure_of(text, "refused_test", name)
end

--- A spawn `must_confine` refuses does not start, and fails the test
--- that made it -- one that passed over the spawn's failure, made in a
--- capture of its own (every running capture hears it), and one that
--- raised besides, whose own failure is kept after it --
--- naming the program, the part of the sandbox, why, and the errno's
--- name. So too a process given more paths than a sandbox unveils; one
--- started with a sandbox of its own that does not unveil and take the
--- network; and one started through a spawn taken during a capture that
--- has since ended.
local function test_a_refused_spawn_fails_the_test_whatever_it_made_of_it(tmp: string)
  local root = tmp .. "/root"
  suite_tree(tmp, root)
  assert(Fs.write(root .. "/suite/refused_test.tl", preamble .. [[

--- Refusals are made in a capture of the test's own, whose stand-in
--- for spawn wraps `refusing`'s; the one running the test hears them
--- too.
local function test_passed_over(tmp: string)
  local inner: Run = nil
  refusing(function()
    inner = observations.call(function()
      confine.must_confine({ reads = { "bin/probe" } })
      local ran, _ = Child.run({ "bin/probe", "write " .. tmp .. "/ran ran" })
      confine.confine(nil)
      assert(ran == nil, "an unconfined process ran in its place")
    end, nil, { tree = tmp, own = { tmp } })
  end)
  assert(Fs.stat(tmp .. "/ran") == nil, "nothing runs in its place")
  assert(not inner.passed, "the inner capture fails")
end

local function test_raised_too(tmp: string)
  refusing(function()
    observations.call(function()
      confine.must_confine({ reads = { "bin/probe" } })
      local _, _ = Child.run({ "bin/probe", "exit 0" })
      confine.confine(nil)
    end, nil, { tree = tmp, own = { tmp } })
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

local function test_stale(tmp: string)
  local taken: any = nil
  observations.call(function() taken = raw().spawn end, nil, { tree = tmp, own = { tmp } })
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
  assert(raised:sub(1, #refused + 12) == refused .. "; and then: " and
    raised:find("its own failure$"), text)
  assert(assert(failure(text, "test_too_many")):find("^must_confine: bin/probe could not start " ..
    "confined: unveil could not be applied: %d+ paths, more than the 256 a sandbox unveils " ..
    "%(EINVAL%)$"), text)
  assert(assert(failure(text, "test_pledged_alone")):find("^must_confine: bin/probe could not " ..
    "start confined: unveil and offline could not be applied: a sandbox of its own that does " ..
    "not unveil and take the network, which must_confine does not add to %(EINVAL%)$"), text)
  assert(assert(failure(text, "test_stale")):find("^must_confine: bin/probe could not start " ..
    "confined: unveil and offline could not be applied: started through a spawn taken " ..
    "while an earlier capture ran %(EINVAL%)$"), text)
end

--- Where the kernel confines a process, one under `must_confine` runs
--- held to what was declared -- not seeing what it was not given, and
--- with no network but a loopback -- and its test passes; where it does
--- not, the test fails naming what could not be applied, and under
--- COSMIC_SANDBOX=must, which says this host confines, this test fails
--- with it. It never runs unconfined.
local function test_a_must_confined_process_is_confined_or_refused(tmp: string)
  local root, hidden = tmp .. "/root", tmp .. "/hidden"
  suite_tree(tmp, root)
  assert(Fs.mkdirs(hidden))
  assert(Fs.write(hidden .. "/f", "secret"))
  assert(Fs.write(root .. "/suite/data.txt", "in"))
  local real = assert(Fs.absolute(root .. "/suite/data.txt"))
  assert(Fs.write(root .. "/suite/real_test.tl", string.format([[
local Child = require("cosmic.child")
local Fs = require("cosmic.fs")
local Test = require("cosmic.test")

Test.needs { reads = { "bin/probe" }, nests = true }

local record Confine
  confine: function(declared: {string:{string}} | nil)
  must_confine: function(declared: {string:{string}} | nil)
end
-- The worker's own, which a suite outside the tree cannot require.
local confine = package.loaded["build.confine"] as Confine

local function test_confined(tmp: string)
  local probe = assert(Fs.absolute("bin/probe"))
  confine.must_confine({ reads = { %q, probe } })
  local r, _ = Child.run({ probe,
    "exists %s/f 3; copy %s out; " ..
    "present /proc/self/net/dev && grep-count /proc/self/net/dev : || exit 0" },
    { cwd = tmp, stdout = "capture" })
  confine.confine(nil)
  if r == nil then return end -- refused: the run says why
  assert(r.code == 0, "the confined process exited " .. tostring(r.code))
  local out = assert(Fs.read(tmp .. "/out"))
  assert(out == "in" and (r.stdout == "" or r.stdout == "1\n"), out .. tostring(r.stdout))
end
]], real, hidden, real)))
  local text, ok = run(root, tmp .. "/out", environment(nil), { "--all" })
  if ok then
    assert(text:find("1 ran", 1, true), text)
    return
  end
  local why = text:match("FAIL  suite%.real_test test_confined: ([^\n]*)")
  assert(why ~= nil and why:find("^must_confine: %S*bin/probe could not start confined: .+ could " ..
    "not be applied: .+ %(E[A-Z0-9]+%)$"), text)
  if unsandboxed(text) then return end
  assert(Env.get("COSMIC_SANDBOX") ~= "must", "COSMIC_SANDBOX=must, but: " .. why)
end

--- COSMIC_SANDBOX=must makes every `confine` a `must_confine`, and runs
--- every test no key holds, as `--all` does, where a run without it
--- assumes one; a sandboxed run keys every test by it. A test that fell
--- back to an unconfined process and passed is assumed or stands without
--- it, and runs again and fails with it. Any other value fails the test
--- that confines.
local function test_the_sandbox_mode_holds_confine_to_must_confine(tmp: string)
  local root = tmp .. "/root"
  suite_tree(tmp, root)
  assert(Fs.write(root .. "/suite/fallback_test.tl", [[
local Child = require("cosmic.child")
local Fs = require("cosmic.fs")
local Test = require("cosmic.test")

Test.needs { reads = { "bin/probe" }, nests = true }

local record Confine
  confine: function(declared: {string:{string}} | nil)
  must_confine: function(declared: {string:{string}} | nil)
end
-- The worker's own, which a suite outside the tree cannot require.
local confine = package.loaded["build.confine"] as Confine

local function test_falls_back(tmp: string)
  local probe = assert(Fs.absolute("bin/probe"))
  local many: {string} = { probe }
  for i = 1, 300 do many[#many + 1] = tmp .. "/many" .. tostring(i) end
  confine.confine({ reads = many })
  local r = assert(Child.run({ probe, "exit 0" }))
  confine.confine(nil)
  assert(r.ok, "the process it fell back to did not run")
end
]]))
  local text, ok = run(root, tmp .. "/first", environment(nil))
  assert(ok and text:find("1 ran", 1, true), text)
  -- Unsandboxed, it is assumed; sandboxed, it stands on its declared
  -- key, which holds the mode below.
  text, ok = run(root, tmp .. "/assumed", environment(nil))
  assert(ok and text:find(unsandboxed(text) and "0 ran, 0 stood, 1 assumed" or "0 ran, 1 stood",
    1, true), text)
  text, ok = run(root, tmp .. "/must", environment("must"))
  assert(not ok, text)
  assert(text:find("FAIL  suite%.fallback_test test_falls_back: confine %(COSMIC_SANDBOX=must%): " ..
    "%S*bin/probe could not start confined: unveil could not be applied: "), text)
  text, ok = run(root, tmp .. "/misspelt", environment("Must"))
  assert(not ok and text:find('COSMIC_SANDBOX is "Must"', 1, true), text)
end

--- A worker a Landlock ruleset holds -- one whose module does not
--- declare `nests` -- cannot give a process a root of its own, whose
--- mounts the kernel refuses under the ruleset: a start in one, through
--- `confine` or a sandbox of its own that unveils, is refused outright,
--- naming `nests`, and fails the test however it took the refusal,
--- rather than fall back to running the process unconfined; so does
--- a run of `cosmic test` that such a worker's process starts, asked to
--- sandbox its workers, and the audit names `nests`. Every process of
--- the worker's learns of the hold from its environment
--- (`confine.held_variable`), which an unsandboxed run is given here to
--- stand for it, the same on every host; sandboxed, the worker is held
--- by a ruleset in fact.
local function test_a_worker_held_by_landlock_is_refused_a_root_of_its_own(tmp: string)
  local root = tmp .. "/root"
  suite_tree(tmp, root)
  assert(Fs.write(root .. "/suite/held_test.tl", [[
local Child = require("cosmic.child")
local Fs = require("cosmic.fs")
local Test = require("cosmic.test")
local type raw_process = require("cosmic.internal.process")

Test.needs { reads = { "bin/probe" } }

local record Confine
  confine: function(declared: {string:{string}} | nil)
end
-- The worker's own, which a suite outside the tree cannot require.
local confine = package.loaded["build.confine"] as Confine
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

local function test_confined(tmp: string)
  confine.confine({ reads = { "bin/probe" } })
  local ran, _ = Child.run({ "bin/probe", "write " .. tmp .. "/ran ran" })
  confine.confine(nil)
  assert(ran == nil, "an unconfined process ran in its place")
  assert(Fs.stat(tmp .. "/ran") == nil, "nothing runs in its place")
end

local function test_own_sandbox()
  local pid, _ = raw().spawn("bin/probe", { "bin/probe", "exit 0" }, nil, nil, nil, nil, nil,
    false, nil, { unveil = { reads = { "bin/probe" } }, offline = true })
  assert(pid == nil, "a process started in a root of its own")
end

local function test_plain()
  assert(Child.run({ "bin/probe", "exit 0" }))
end
]]))
  local env = environment(nil)
  env.COSMIC_TEST_SANDBOX = "0"
  env[confine.held_variable] = "suite.outer_test"
  local text, ok = run(root, tmp .. "/held", env, { "--all" })
  assert(not ok and text:find("(2 of 3 failed", 1, true), text)
  local function refusal(module: string): string
    return "bin/probe cannot start in a root of its own: " .. module .. "'s worker is held " ..
      "by a Landlock ruleset, under which the kernel refuses every mount; declare " ..
      "nests = true in its Test.needs"
  end
  local refused = refusal("suite.outer_test")
  assert(failure_of(text, "held_test", "test_confined") == refused, text)
  assert(failure_of(text, "held_test", "test_own_sandbox") == refused, text)
  local audited, _ = run(root, tmp .. "/audit", env, { "--audit" })
  assert(audited:find("    nests        bin/probe", 1, true), audited)
  assert(audited:find("  declare: Test.needs { reads = { \"bin/probe\" }, nests = true }", 1,
    true), audited)
  -- Asked to sandbox its workers, a run started there refuses to.
  env.COSMIC_TEST_SANDBOX = nil
  text, ok = run(root, tmp .. "/nested", env)
  assert(not ok and text:find("test: this run was started in suite.outer_test's worker, " ..
    "which a Landlock ruleset holds", 1, true) and
    text:find("declare nests = true in its Test.needs", 1, true), text)
  -- Sandboxed, its own worker is held so.
  env[confine.held_variable] = nil
  text, ok = run(root, tmp .. "/sandboxed", env, { "--all" })
  if unsandboxed(text) then return end
  assert(not ok and text:find("(2 of 3 failed", 1, true), text)
  refused = refusal("suite.held_test")
  assert(failure_of(text, "held_test", "test_confined") == refused, text)
  assert(failure_of(text, "held_test", "test_own_sandbox") == refused, text)
end
