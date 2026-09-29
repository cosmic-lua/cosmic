--- The cases of build/test_isolation_test.tl that run `cosmic test` on
--- a project of their own. Each test runs in a worker process of its
--- own: a test that hangs is ended at its deadline, one that ends its
--- process fails by itself, and neither takes the rest of the run with
--- it. What a test prints is shown only when it fails. They declare
--- `tool` because they start this program.

local Child = require("cosmic.child")
local Fs = require("cosmic.fs")
local Time = require("cosmic.time")
local sys = require("cosmic.sys")
local test = require("build.test")
local this_program = require("build.this_program")
local stand_in = require("build.stand_in")
local sandbox_skip = require("build.sandbox_skip")
local Test = require("cosmic.test")

--- A worker a test starts, to hang or exit, and /proc, where what a
--- hung one left running would be found; the program itself, which the
--- tests start, and roots of their own for its sandboxed workers
--- (`nests`); and what holds a run to sandboxing (`unsandboxed`).
Test.needs{
  host = { "/proc" },
  env = { "COSMIC_SANDBOX", "COSMIC_CI_REQUIRE_SANDBOX", "COSMIC_TEST_SANDBOX" },
  processes = true,
  tool = true,
  nests = true,
}

--- The environment a run of `cosmic test` these tests start is given:
--- its workers unsandboxed (`COSMIC_TEST_SANDBOX=0`), since what they
--- check is the runner's own handling of what a worker reads and leaves
--- of the host, which a sandbox would not let it reach.
local function environment(): {string:string}
  local env = this_program.environment()
  env.COSMIC_TEST_SANDBOX = "0"
  return env
end

--- Whether the run that said `text` sandboxed none of its workers, where
--- that is allowed. The workers nest in this test's own sandbox, which a
--- host may refuse (the kernel lets root nest one only two deep,
--- core/syscalls.c's `map_ids`, where a root runner cannot run its
--- workers as a user of their own: build.test_sandbox's `runs_as`);
--- the sandboxed case then checks only what
--- the unsandboxed one does. It says it is skipped (`Test.skip`),
--- which a run held to sandboxing fails
--- (COSMIC_TEST_SANDBOX=1, as CI's suites set it, COSMIC_SANDBOX=must or
--- COSMIC_CI_REQUIRE_SANDBOX=1): CI's unprivileged runners nest them.
local function unsandboxed(text: string): boolean
  if text:find("; sandboxed)", 1, true) ~= nil then return false end
  sandbox_skip.nested(text)
  return true
end

local function invoke(root: string, output: string, args: {string},
    env?: {string:string}): Child.Result
  local words: {string} = { "test" }
  for _, value in ipairs(args) do words[#words + 1] = value end
  local fd = assert(Fs.open_write(output))
  local started = this_program.program(words, {
    cwd = root, env = env or environment(), stdout = fd, stderr = fd, timeout_ms = 60000,
  })
  local result, trouble = Child.run(started.argv, started.options)
  assert(Fs.close(fd))
  return (assert(result, trouble))
end

--- A hung test that also started a process group of its own, which the
--- end of its worker's group does not reach -- the stand-in `probe`,
--- placed at the project's bin/probe and named by `marker`, which it
--- keeps running; a test that ends its own process after printing; and
--- a quiet one that passes. With no `probe`, the hung test has none to
--- start, for a run that never runs it.
local function project(tmp: string, marker: string, probe?: string): string
  local root = tmp .. "/project"
  assert(Fs.mkdirs(root .. "/suite"))
  if probe ~= nil then
    assert(Fs.mkdirs(root .. "/bin"))
    assert(stand_in.place(probe, root .. "/bin/probe"))
  end
  local hang = [[
local Child = require("cosmic.child")
local sys = require("cosmic.sys")
local Test = require("cosmic.test")

Test.needs { reads = { "bin/probe" } }

local held: {Child.Handle} = {}
local function test_hangs()
  held[1] = assert(Child.start({ "bin/probe", "sleep-forever", "MARKER" }))
  -- Still running a moment on, so what is found gone below was there:
  -- a probe that never started, or ended at once, fails this instead
  -- of timing out.
  local _, _ = sys.nanosleep(300 * 1000 * 1000)
  local state = assert(held[1]:try_wait())
  assert(not state.finished, "the probe is not running")
  while true do end
end
]]
  assert(Fs.write(root .. "/suite/hang_test.tl", (hang:gsub("MARKER", marker))))
  assert(Fs.write(root .. "/suite/exits_test.tl", [[
local Fs = require("cosmic.fs")
local Proc = require("cosmic.proc")
local function test_exits()
  Fs.put(Fs.stdout, "said something\n")
  Proc.exit(0)
end
]]))
  assert(Fs.write(root .. "/suite/fine_test.tl", [[
local Fs = require("cosmic.fs")
local function test_fine()
  Fs.put(Fs.stdout, "quiet\n")
end
]]))
  return root
end

--- The processes /proc lists whose command line holds `marker`: every
--- one this process can see, in its own pid namespace and those
--- beneath it.
local function running(marker: string): {string}
  local found: {string} = {}
  for _, name in ipairs(Fs.list("/proc") or {}) do
    if name:match("^%d+$") ~= nil then
      local line = Fs.read("/proc/" .. name .. "/cmdline") or ""
      if line:find(marker, 1, true) ~= nil then found[#found + 1] = name end
    end
  end
  return found
end

--- A hung test is ended at its deadline, and so is every process it
--- left running -- its worker's process group and the strays the
--- runner adopts, unsandboxed; its worker's pid namespace, sandboxed
--- (`build.test_sandbox`) -- while the rest of the run goes on.
local function test_a_hung_or_exiting_test_fails_alone(tmp: string)
  local probe = assert(stand_in.build(tmp .. "/stand-in"))
  for _, mode in ipairs({ "0", "" }) do
    local marker = "cosmic-hang-" .. tostring(Time.monotonic_ns())
    local here = tmp .. "/mode" .. mode
    local root = project(here, marker, probe)
    local output = here .. "/run.out"
    -- The failing tests' directories are kept; they are kept here.
    local env = environment()
    env.TMPDIR = here .. "/temp"
    env.COSMIC_TEST_SANDBOX = mode
    assert(Fs.mkdirs(env.TMPDIR))
    local started = Time.monotonic_ns()
    local result = invoke(root, output, { "--timeout", "1", "--jobs", "2" }, env)
    local text = assert(Fs.read(output))
    assert(not result.ok, text)
    assert(Time.monotonic_ns() - started < 30 * 1000 * 1000 * 1000, text)
    assert(text:find("suite.hang_test test_hangs: timed out after 1 s", 1, true), text)
    assert(text:find("suite.exits_test test_exits: the test process exited with status 0 " ..
      "before it reported", 1, true), text)
    assert(text:find("  | said something", 1, true), text)
    assert(not text:find("quiet", 1, true), text)
    assert(text:find("2 of 3 failed", 1, true), text)
    local sandboxed = text:find("; sandboxed)", 1, true) ~= nil
    if mode == "0" then
      assert(not sandboxed, text)
    else
      sandboxed = not unsandboxed(text)
    end
    assert(text:find(sandboxed and "its pid namespace was ended" or "its process group was ended",
      1, true), text)
    -- Where the runner can find what a dead worker left behind (Linux),
    -- the process the hung test left running is gone too.
    if Fs.exists("/proc/self/task") then
      local left = running(marker)
      assert(#left == 0, mode .. ": left running: " .. table.concat(left, " "))
    end
  end
end

--- An unsandboxed worker still running keeps what it left running
--- after the process that started it ended, which the runner adopts,
--- while another worker ends. `late` is orphaned to the runner from a
--- worker that started nothing in a group of its own, and so adopts
--- nothing itself; it is told to finish only after the other worker has
--- ended. Started two at a time in the order of their paths, `then`
--- starts only once `ends` has ended and the runner has ended the
--- strays it would.
local function test_a_running_workers_orphan_outlives_another_worker(tmp: string)
  local probe = assert(stand_in.build(tmp .. "/stand-in"))
  local root = tmp .. "/project"
  local shared = tmp .. "/shared"
  assert(Fs.mkdirs(root .. "/suite"))
  assert(Fs.mkdirs(root .. "/bin"))
  assert(Fs.mkdirs(shared))
  assert(stand_in.place(probe, root .. "/bin/probe"))
  assert(stand_in.place(probe, shared .. "/late", "wait-for $DIR/go\nwrite $DIR/done done"))
  local await = [[
local Fs = require("cosmic.fs")
local sys = require("cosmic.sys")
local Time = require("cosmic.time")

local function await(path: string, seconds: integer)
  local deadline = Time.monotonic_ns() + seconds * 1000 * 1000 * 1000
  while Fs.exists(path) ~= true do
    assert(Time.monotonic_ns() < deadline, "waited for " .. path)
    local _, _ = sys.nanosleep(5 * 1000 * 1000)
  end
end
]]
  local function place(name: string, source: string)
    local text = source:gsub("SHARED", function(): string return shared end)
    assert(Fs.write(root .. "/suite/" .. name, text))
  end
  local function write(name: string, body: string) place(name, await .. body) end
  write("orphans_test.tl", [[
local Child = require("cosmic.child")

local function test_orphans()
  -- In this worker's group, as `late` is, and so no subreaper made.
  local r = assert(Child.run({ "bin/probe", "start SHARED/late" },
    { process_group = false, timeout_ms = 30000 }))
  assert(r.ok)
  assert(Fs.write("SHARED/ready", ""))
  await("SHARED/then", 30)
  assert(Fs.write("SHARED/go", ""))
  await("SHARED/done", 10)
end
]])
  write("ends_test.tl", [[
local function test_ends()
  await("SHARED/ready", 30)
end
]])
  place("then_test.tl", [[
local Fs = require("cosmic.fs")
local function test_then()
  assert(Fs.write("SHARED/then", ""))
end
]])
  local output = tmp .. "/run.out"
  local result = invoke(root, output, { "--jobs", "2" })
  local text = assert(Fs.read(output))
  assert(result.ok, text)
  assert(Fs.exists(shared .. "/done"), text)
end

local function test_limits_must_be_positive_whole_numbers(tmp: string)
  local root = project(tmp, "unused")
  local output = tmp .. "/limits.out"
  local result = invoke(root, output, { "--timeout", "0", "suite/fine_test.tl" })
  assert(result.code == 2, assert(Fs.read(output)))
  assert(assert(Fs.read(output)):find("--timeout must be a positive whole number", 1, true))
  result = invoke(root, output, { "--jobs", "x", "suite/fine_test.tl" })
  assert(result.code == 2, assert(Fs.read(output)))
  local env = environment()
  env.COSMIC_TEST_TIMEOUT = "soon"
  result = invoke(root, output, { "suite/fine_test.tl" }, env)
  assert(result.code == 2, assert(Fs.read(output)))
  assert(assert(Fs.read(output)):find("COSMIC_TEST_TIMEOUT must be", 1, true))
  env.COSMIC_TEST_TIMEOUT = "5"
  result = invoke(root, output, { "suite/fine_test.tl" }, env)
  assert(result.ok, assert(Fs.read(output)))
end

--- The runner removes a passing test's directory, the real one behind
--- the link included, and leaves a failing test's to look at.
local function test_a_passing_tests_directory_is_removed(tmp: string)
  local root = tmp .. "/project"
  local temp = tmp .. "/temp"
  assert(Fs.mkdirs(root .. "/suite"))
  assert(Fs.mkdirs(temp))
  assert(Fs.write(root .. "/suite/left_test.tl", [[
local Fs = require("cosmic.fs")
local function test_passes(tmp: string)
  assert(Fs.write(tmp .. "/kept", "x"))
end
local function test_fails(tmp: string)
  assert(Fs.write(tmp .. "/kept", "x"))
  error("fails")
end
]]))
  local env = environment()
  env.TMPDIR = temp
  local output = tmp .. "/left.out"
  local result = invoke(root, output, { "suite/left_test.tl" }, env)
  local text = assert(Fs.read(output))
  assert(not result.ok, text)
  assert(text:find("1 of 2 failed", 1, true), text)
  assert(text:find("its directory is kept: " .. assert(Fs.absolute(temp)) .. "/cosmic-test-",
    1, true), text)
  local left: {string} = {}
  for _, name in ipairs((assert(Fs.list(temp)))) do
    if name:sub(1, 12) == "cosmic-test-" and name:sub(1, 21) ~= "cosmic-test-children-" then
      left[#left + 1] = name
    end
  end
  assert(#left == 1, table.concat(left, ", "))
  local scratch = temp .. "/" .. left[1]
  assert(assert(Fs.read(scratch .. "/real/kept")) == "x")
  assert(assert(sys.lstat(scratch .. "/tmp")).kind == "link")
end

--- A run cancelled by SIGTERM ends every worker it had running and
--- removes each one's directory: a test it ended never finished, so
--- nothing in its directory is left to look at.
local function test_a_cancelled_run_removes_its_ended_workers_directories(tmp: string)
  local root = tmp .. "/project"
  local temp = tmp .. "/temp"
  local marks = tmp .. "/marks"
  assert(Fs.mkdirs(root .. "/suite"))
  assert(Fs.mkdirs(temp))
  assert(Fs.mkdirs(marks))
  assert(Fs.write(root .. "/suite/held_test.tl", [[
local Env = require("cosmic.env")
local Fs = require("cosmic.fs")
local Test = require("cosmic.test")
Test.needs { env = { "MARKS" } }
local function hold(tmp: string, name: string)
  assert(Fs.write(tmp .. "/kept", "x"))
  assert(Fs.write(assert(Env.get("MARKS")) .. "/" .. name, "x"))
  while true do end
end
local function test_first(tmp: string) hold(tmp, "first") end
local function test_second(tmp: string) hold(tmp, "second") end
]]))
  local env = environment()
  env.TMPDIR = temp
  env.MARKS = marks
  local output = tmp .. "/cancelled.out"
  local fd = assert(Fs.open_write(output))
  local held = this_program.program(
    { "test", "--jobs", "2", "--timeout", "60", "suite/held_test.tl" },
    { cwd = root, env = env, stdout = fd, stderr = fd })
  local runner, trouble = Child.start(held.argv, held.options)
  assert(Fs.close(fd))
  local handle <close> = assert(runner, trouble)
  local deadline = Time.monotonic_ns() + 30 * 1000 * 1000 * 1000
  while not (Fs.exists(marks .. "/first") and Fs.exists(marks .. "/second")) do
    assert(Time.monotonic_ns() < deadline, assert(Fs.read(output)))
    -- Leaves the runner running, as a timed `wait` would not.
    local done, _ = Child.wait_any({ handle }, 50)
    assert(done == nil, "the runner ended before its tests started\n" .. assert(Fs.read(output)))
  end
  assert(handle:stop(sys.SIGTERM))
  local result = assert(handle:wait(30000))
  local text = assert(Fs.read(output))
  assert(not result.timed_out and result.signal == sys.SIGTERM, text)
  assert(text:find("test: cancelled; every running test was ended", 1, true), text)
  local left: {string} = {}
  for _, name in ipairs((assert(Fs.list(temp)))) do
    if name:sub(1, 12) == "cosmic-test-" and name:sub(1, 21) ~= "cosmic-test-children-" then
      left[#left + 1] = name
    end
  end
  assert(#left == 0, table.concat(left, ", ") .. "\n" .. text)
end

--- A run cancelled after a test failed names that test's directory,
--- which it keeps, as a finished run's report does.
local function test_a_cancelled_run_names_a_failed_tests_directory(tmp: string)
  local root = tmp .. "/project"
  local temp = tmp .. "/temp"
  local marks = tmp .. "/marks"
  assert(Fs.mkdirs(root .. "/suite"))
  assert(Fs.mkdirs(temp))
  assert(Fs.mkdirs(marks))
  -- One job at a time: the held test starts only once the failed one's
  -- result is collected.
  assert(Fs.write(root .. "/suite/failed_test.tl", [[
local Env = require("cosmic.env")
local Fs = require("cosmic.fs")
local Test = require("cosmic.test")
Test.needs { env = { "MARKS" } }
local function test_a_fails(tmp: string)
  assert(Fs.write(tmp .. "/kept", "x"))
  error("fails")
end
local function test_b_holds()
  assert(Fs.write(assert(Env.get("MARKS")) .. "/held", "x"))
  while true do end
end
]]))
  local env = environment()
  env.TMPDIR = temp
  env.MARKS = marks
  local output = tmp .. "/cancelled.out"
  local fd = assert(Fs.open_write(output))
  local failed = this_program.program(
    { "test", "--jobs", "1", "--timeout", "60", "suite/failed_test.tl" },
    { cwd = root, env = env, stdout = fd, stderr = fd })
  local runner, trouble = Child.start(failed.argv, failed.options)
  assert(Fs.close(fd))
  local handle <close> = assert(runner, trouble)
  local deadline = Time.monotonic_ns() + 20 * 1000 * 1000 * 1000
  while not Fs.exists(marks .. "/held") do
    assert(Time.monotonic_ns() < deadline, assert(Fs.read(output)))
    local done, _ = Child.wait_any({ handle }, 50)
    assert(done == nil, "the runner ended before its tests started\n" .. assert(Fs.read(output)))
  end
  assert(handle:stop(sys.SIGTERM))
  local result = assert(handle:wait(5000))
  local text = assert(Fs.read(output))
  assert(not result.timed_out and result.signal == sys.SIGTERM, text)
  assert(text:find("test: cancelled; every running test was ended", 1, true), text)
  assert(text:find("test: FAIL  suite.failed_test test_a_fails: ", 1, true), text)
  local named = text:match("its directory is kept: ([^\n]+)/real")
  assert(named ~= nil and named:find(assert(Fs.absolute(temp)) .. "/cosmic-test-", 1, true) == 1,
    text)
  assert(assert(Fs.read(named .. "/real/kept")) == "x", text)
end

--- A fixture runtime's startup hooks pause one startup for a handshake;
--- a worker inheriting them would pause too, with nobody to release it.
local function test_workers_start_without_the_startup_hooks(tmp: string)
  local root = tmp .. "/project"
  assert(Fs.mkdirs(root .. "/suite"))
  assert(Fs.write(root .. "/suite/hooks_test.tl", [[
local Env = require("cosmic.env")
local Test = require("cosmic.test")
Test.needs { env = { "KEPT_BY_THE_WORKER" } }
local function test_no_hooks()
  assert(Env.get("COSMIC_PORTABLE_STARTUP_TEST_READY") == nil)
  assert(Env.get("KEPT_BY_THE_WORKER") == "yes")
end
]]))
  local env = environment()
  env.COSMIC_PORTABLE_STARTUP_TEST_READY = tmp .. "/never"
  env.KEPT_BY_THE_WORKER = "yes"
  local output = tmp .. "/hooks.out"
  local result = invoke(root, output, { "suite/hooks_test.tl" }, env)
  assert(result.ok, assert(Fs.read(output)))
  local kept = test.worker_environment({ COSMIC_PORTABLE_STARTUP_TEST_GO = "x",
    COSMIC_PORTABLE_CACHE = "c", PATH = "p", COSMIC_REBOOTED = "1", OLDPWD = "/elsewhere",
    _ = "/usr/bin/timeout", SHLVL = "2", COSMIC_BUILD_CACHE = "/shared/cache.db",
    COSMIC_VERDICT_CACHE = "/shared/verdicts.db", COSMIC_TEST_NO_SHARED = "1",
    COSMIC_TEST_KEY = "declared" })
  assert(kept.COSMIC_PORTABLE_STARTUP_TEST_GO == nil)
  -- Nor whether this run stands on shared verdicts: a `cosmic test` a
  -- test starts says that for itself. Nor the retired switch CI's driver
  -- still sets for the release it pins.
  assert(kept.COSMIC_TEST_NO_SHARED == nil and kept.COSMIC_TEST_KEY == nil)
  -- Neither cache every checkout shares is a worker's, unless its test
  -- names one for what it starts.
  assert(kept.COSMIC_BUILD_CACHE == "0" and kept.COSMIC_VERDICT_CACHE == "0")
  -- How this run was started -- after a tool rebuilt itself, from a
  -- shell that was elsewhere before, or from a script rather than a
  -- terminal (the shell's depth) -- is no worker's to see.
  assert(kept.COSMIC_REBOOTED == nil and kept.OLDPWD == nil and kept._ == nil)
  assert(kept.SHLVL == nil)
  assert(kept.COSMIC_PORTABLE_CACHE == "c" and kept.PATH == "p")
end
