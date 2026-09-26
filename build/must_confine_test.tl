--- End to end: `observations.must_confine`, and COSMIC_SANDBOX=must,
--- which makes every `confine` one, as `cosmic test` holds a suite to
--- them. Each suite runs in a `cosmic test` of its own: a spawn
--- `must_confine` refuses fails every capture running, the one that
--- runs the test included, so what a refusal does to a test is seen
--- from the run that reports it.

local Child = require("cosmic.child")
local Env = require("cosmic.env")
local Fs = require("cosmic.fs")
local Proc = require("cosmic.proc")
local observations = require("build.filesystem_observations")

-- What these tests start is this very program.
observations.confine({ reads = observations.itself() })

--- Runs `cosmic test` on `root` with `words` after it, answering what
--- it printed and whether it passed.
local function run(root: string, output: string, env: {string:string},
                   words?: {string}): string, boolean
  local fd = assert(Fs.open_write(output))
  local argv: {string} = { assert(Proc.executable()), "test" }
  for _, word in ipairs(words or {}) do argv[#argv + 1] = word end
  local result, trouble = Child.run(argv, {
    cwd = root, env = env, stdout = fd, stderr = fd,
    process_group = true, timeout_ms = 60000,
  })
  assert(Fs.close(fd))
  local text = assert(Fs.read(output))
  assert(result ~= nil, tostring(trouble) .. text)
  return text, result.ok
end

--- The environment a suite runs in: the pinned one, with no verdict cache
--- shared, and COSMIC_SANDBOX as `mode` has it.
local function environment(mode: string | nil): {string:string}
  local env = observations.environment()
  env.COSMIC_VERDICT_CACHE = "0"
  env.COSMIC_TEST_ALL = nil
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
local record Run
  passed: boolean
end
local record Observations
  confine: function(declared: {string:{string}} | nil)
  must_confine: function(declared: {string:{string}} | nil)
  call: function(fn: function(any...): (any...), argument: any, resolving?: {string:any}): Run
end
-- The worker's own, which a suite outside the tree cannot require.
local observations = package.loaded["build.filesystem_observations"] as Observations
local type raw_process = require("cosmic.internal.process")
local type Searcher = function(string): any, any

local function raw(): raw_process
  for _, searcher in ipairs(package.searchers as {Searcher}) do
    local loader, extra = searcher("build.filesystem_observations")
    if type(loader) == "function" and type(extra) == "table" then
      return (extra as {string:any}).process as raw_process
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

--- The line a run printed for one failing test, from its message on.
local function failure(text: string, name: string): string | nil
  return text:match("FAIL  suite%.refused_test " .. name .. ": ([^\n]*)")
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
  assert(Fs.mkdirs(root .. "/suite"))
  assert(Fs.write(root .. "/suite/refused_test.tl", preamble .. [[

--- Refusals are made in a capture of the test's own, whose stand-in
--- for spawn wraps `refusing`'s; the one running the test hears them
--- too.
local function test_passed_over(tmp: string)
  local inner: Run = nil
  refusing(function()
    inner = observations.call(function()
      observations.must_confine({})
      local ran, _ = Child.run({ "/bin/sh", "-c", "echo ran > " .. tmp .. "/ran" })
      observations.confine(nil)
      assert(ran == nil, "an unconfined shell ran in its place")
    end, nil, { tree = tmp, own = { tmp } })
  end)
  assert(Fs.stat(tmp .. "/ran") == nil, "nothing runs in its place")
  assert(not inner.passed, "the inner capture fails")
end

local function test_raised_too(tmp: string)
  refusing(function()
    observations.call(function()
      observations.must_confine({})
      local _, _ = Child.run({ "/bin/sh", "-c", "true" })
      observations.confine(nil)
    end, nil, { tree = tmp, own = { tmp } })
  end)
  error("its own failure")
end

local function test_too_many(tmp: string)
  local many: {string} = {}
  for i = 1, 70 do many[i] = tmp .. "/many" .. tostring(i) end
  observations.must_confine({ reads = many })
  local _, _ = Child.run({ "/bin/sh", "-c", "true" })
  observations.confine(nil)
end

local function test_pledged_alone()
  observations.must_confine({})
  local _, _ = raw().spawn("/bin/sh", { "sh", "-c", "true" }, nil, nil, nil, nil, nil, false,
    nil, { pledge = {} })
  observations.confine(nil)
end

local function test_stale(tmp: string)
  local taken: any = nil
  observations.call(function() taken = raw().spawn end, nil, { tree = tmp, own = { tmp } })
  observations.must_confine({})
  local spawn = taken as function(string, {string}, any, any, any, any, any, boolean): any
  local _ = spawn("/bin/sh", { "sh", "-c", "true" }, nil, nil, nil, nil, nil, false)
  observations.confine(nil)
end
]]))
  local text, ok = run(root, tmp .. "/out", environment(nil), { "--all" })
  assert(not ok, text)
  local refused = "must_confine: /bin/sh could not start confined: unveil and offline " ..
    "could not be applied: Operation not permitted (EPERM)"
  assert(failure(text, "test_passed_over") == refused, text)
  local raised = assert(failure(text, "test_raised_too"))
  assert(raised:sub(1, #refused + 12) == refused .. "; and then: " and
    raised:find("its own failure$"), text)
  assert(assert(failure(text, "test_too_many")):find("^must_confine: /bin/sh could not start " ..
    "confined: unveil could not be applied: %d+ paths, more than the 64 a sandbox unveils " ..
    "%(EINVAL%)$"), text)
  assert(assert(failure(text, "test_pledged_alone")):find("^must_confine: /bin/sh could not " ..
    "start confined: unveil and offline could not be applied: a sandbox of its own that does " ..
    "not unveil and take the network, which must_confine does not add to %(EINVAL%)$"), text)
  assert(assert(failure(text, "test_stale")):find("^must_confine: /bin/sh could not start " ..
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
  assert(Fs.mkdirs(root .. "/suite"))
  assert(Fs.mkdirs(hidden))
  assert(Fs.write(hidden .. "/f", "secret"))
  assert(Fs.write(root .. "/suite/data.txt", "in"))
  local real = assert(Fs.absolute(root .. "/suite/data.txt"))
  assert(Fs.write(root .. "/suite/real_test.tl", string.format([[
local Child = require("cosmic.child")
local Fs = require("cosmic.fs")
local record Run
  passed: boolean
end
local record Observations
  confine: function(declared: {string:{string}} | nil)
  must_confine: function(declared: {string:{string}} | nil)
  call: function(fn: function(any...): (any...), argument: any, resolving?: {string:any}): Run
end
-- The worker's own, which a suite outside the tree cannot require.
local observations = package.loaded["build.filesystem_observations"] as Observations

local function test_confined(tmp: string)
  observations.must_confine({ reads = { %q } })
  local r, _ = Child.run({ "/bin/sh", "-c",
    "test -e %s/f && exit 3; cat %s > out; " ..
    "if test -r /proc/self/net/dev; then grep -c : /proc/self/net/dev >> out; fi" },
    { cwd = tmp })
  observations.confine(nil)
  if r == nil then return end -- refused: the run says why
  assert(r.code == 0, "the confined shell exited " .. tostring(r.code))
  local out = assert(Fs.read(tmp .. "/out"))
  assert(out == "in" or out == "in1\n", out)
end
]], real, hidden, real)))
  local text, ok = run(root, tmp .. "/out", environment(nil), { "--all" })
  if ok then
    assert(text:find("1 ran", 1, true), text)
    return
  end
  local why = text:match("FAIL  suite%.real_test test_confined: ([^\n]*)")
  assert(why ~= nil and why:find("^must_confine: /bin/sh could not start confined: .+ could " ..
    "not be applied: .+ %(E[A-Z0-9]+%)$"), text)
  assert(Env.get("COSMIC_SANDBOX") ~= "must", "COSMIC_SANDBOX=must, but: " .. why)
end

--- COSMIC_SANDBOX=must makes every `confine` a `must_confine`, and runs
--- every test no key holds, as `--all` does, where a run without it
--- assumes one: a test that fell back to an unconfined process, passed
--- and so is assumed, runs again and fails. Any other value fails the
--- test that confines.
local function test_the_sandbox_mode_holds_confine_to_must_confine(tmp: string)
  local root = tmp .. "/root"
  assert(Fs.mkdirs(root .. "/suite"))
  assert(Fs.write(root .. "/suite/fallback_test.tl", [[
local Child = require("cosmic.child")
local record Run
  passed: boolean
end
local record Observations
  confine: function(declared: {string:{string}} | nil)
  must_confine: function(declared: {string:{string}} | nil)
  call: function(fn: function(any...): (any...), argument: any, resolving?: {string:any}): Run
end
-- The worker's own, which a suite outside the tree cannot require.
local observations = package.loaded["build.filesystem_observations"] as Observations

local function test_falls_back(tmp: string)
  local many: {string} = {}
  for i = 1, 70 do many[i] = tmp .. "/many" .. tostring(i) end
  observations.confine({ reads = many })
  local _, _ = Child.run({ "/bin/sh", "-c", "true" })
  observations.confine(nil)
end
]]))
  local text, ok = run(root, tmp .. "/first", environment(nil))
  assert(ok and text:find("1 ran", 1, true), text)
  text, ok = run(root, tmp .. "/assumed", environment(nil))
  assert(ok and text:find("0 ran, 0 stood, 1 assumed", 1, true), text)
  text, ok = run(root, tmp .. "/must", environment("must"))
  assert(not ok, text)
  assert(text:find("FAIL  suite.fallback_test test_falls_back: confine (COSMIC_SANDBOX=must): " ..
    "/bin/sh could not start confined: unveil could not be applied: ", 1, true), text)
  text, ok = run(root, tmp .. "/misspelt", environment("Must"))
  assert(not ok and text:find('COSMIC_SANDBOX is "Must"', 1, true), text)
end
