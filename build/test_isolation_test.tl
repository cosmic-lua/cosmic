--- Each test runs in a worker process of its own: a test that hangs is
--- ended at its deadline, one that ends its process fails by itself,
--- and neither takes the rest of the run with it. What a test prints is
--- shown only when it fails.

local Child = require("cosmic.child")
local Env = require("cosmic.env")
local Fs = require("cosmic.fs")
local Proc = require("cosmic.proc")
local Time = require("cosmic.time")
local sys = require("cosmic.sys")
local test = require("build.test")
local worker = require("build.test_worker")
local observations = require("build.filesystem_observations")

-- What these tests start is this very program.
observations.confine({ reads = observations.itself() })

local function invoke(root: string, output: string, args: {string},
    env?: {string:string}): Child.Result
  local argv: {string} = { assert(Proc.executable()), "test" }
  for _, value in ipairs(args) do argv[#argv + 1] = value end
  local fd = assert(Fs.open_write(output))
  local result, trouble = Child.run(argv, {
    cwd = root, env = env or Env.all(), stdout = fd, stderr = fd, timeout_ms = 60000,
  })
  assert(Fs.close(fd))
  return (assert(result, trouble))
end

--- A hung test that also started a process group of its own, which the
--- end of its worker's group does not reach; a test that ends its own
--- process after printing; and a quiet one that passes.
local function project(tmp: string): string, string
  local root = tmp .. "/project"
  local pidfile = tmp .. "/nested.pid"
  assert(Fs.mkdirs(root .. "/suite"))
  local hang = [[
local Child = require("cosmic.child")
local held: {Child.Handle} = {}
local function test_hangs()
  held[1] = assert(Child.start({ "/bin/sh", "-c",
    "sleep 60 & printf %s $! >'PIDFILE'; wait" }))
  while true do end
end
]]
  assert(Fs.write(root .. "/suite/hang_test.tl", (hang:gsub("PIDFILE", pidfile))))
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
  return root, pidfile
end

local function test_a_hung_or_exiting_test_fails_alone(tmp: string)
  local root, pidfile = project(tmp)
  local output = tmp .. "/run.out"
  -- The failing tests' directories are kept; they are kept here.
  local env = Env.all()
  env.TMPDIR = tmp .. "/temp"
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
  -- Where the runner can find what a dead worker left behind (Linux),
  -- the hung test's own process group is gone too.
  if Fs.exists("/proc/self/task") then
    local pid = assert(math.tointeger(tonumber((assert(Fs.read(pidfile))))))
    local alive, _, errno = sys.kill(pid, 0)
    assert(not alive and errno == sys.ESRCH, "nested process " .. tostring(pid) .. " survived")
  end
end

local function test_limits_must_be_positive_whole_numbers(tmp: string)
  local root = project(tmp)
  local output = tmp .. "/limits.out"
  local result = invoke(root, output, { "--timeout", "0", "suite/fine_test.tl" })
  assert(result.code == 2, assert(Fs.read(output)))
  assert(assert(Fs.read(output)):find("--timeout must be a positive whole number", 1, true))
  result = invoke(root, output, { "--jobs", "x", "suite/fine_test.tl" })
  assert(result.code == 2, assert(Fs.read(output)))
  local env = Env.all()
  env.COSMIC_TEST_TIMEOUT = "soon"
  result = invoke(root, output, { "suite/fine_test.tl" }, env)
  assert(result.code == 2, assert(Fs.read(output)))
  assert(assert(Fs.read(output)):find("COSMIC_TEST_TIMEOUT must be", 1, true))
  env.COSMIC_TEST_TIMEOUT = "5"
  result = invoke(root, output, { "suite/fine_test.tl" }, env)
  assert(result.ok, assert(Fs.read(output)))
end

--- A test's directory is reached through a link, so a path resolved on
--- one side of a comparison and not the other fails here as it does
--- under macOS's /var; the one this test itself was handed is too.
local function test_a_test_directory_is_reached_through_a_link(tmp: string)
  local st = assert(sys.lstat(tmp))
  assert(st.kind == "link", tmp .. " is a " .. st.kind)
  local resolved = assert(Fs.absolute(tmp))
  assert(resolved ~= tmp, resolved)
  assert(Fs.is_dir(resolved))
  local scratch = assert(test.scratch())
  assert(assert(Fs.absolute(scratch)) == scratch, scratch)
  assert(assert(Fs.readlink(scratch .. "/tmp")) == "real")
  assert(assert(Fs.absolute(scratch .. "/tmp")) == scratch .. "/real")
  assert(Fs.remove_tree(scratch))
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
  local env = Env.all()
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
local function hold(tmp: string, name: string)
  assert(Fs.write(tmp .. "/kept", "x"))
  assert(Fs.write(assert(Env.get("MARKS")) .. "/" .. name, "x"))
  while true do end
end
local function test_first(tmp: string) hold(tmp, "first") end
local function test_second(tmp: string) hold(tmp, "second") end
]]))
  local env = Env.all()
  env.TMPDIR = temp
  env.MARKS = marks
  local output = tmp .. "/cancelled.out"
  local fd = assert(Fs.open_write(output))
  local runner, trouble = Child.start(
    { assert(Proc.executable()), "test", "--jobs", "2", "--timeout", "60", "suite/held_test.tl" },
    { cwd = root, env = env, stdout = fd, stderr = fd })
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
local function test_a_fails(tmp: string)
  assert(Fs.write(tmp .. "/kept", "x"))
  error("fails")
end
local function test_b_holds()
  assert(Fs.write(assert(Env.get("MARKS")) .. "/held", "x"))
  while true do end
end
]]))
  local env = Env.all()
  env.TMPDIR = temp
  env.MARKS = marks
  local output = tmp .. "/cancelled.out"
  local fd = assert(Fs.open_write(output))
  local runner, trouble = Child.start(
    { assert(Proc.executable()), "test", "--jobs", "1", "--timeout", "60", "suite/failed_test.tl" },
    { cwd = root, env = env, stdout = fd, stderr = fd })
  assert(Fs.close(fd))
  local handle <close> = assert(runner, trouble)
  local deadline = Time.monotonic_ns() + 30 * 1000 * 1000 * 1000
  while not Fs.exists(marks .. "/held") do
    assert(Time.monotonic_ns() < deadline, assert(Fs.read(output)))
    local done, _ = Child.wait_any({ handle }, 50)
    assert(done == nil, "the runner ended before its tests started\n" .. assert(Fs.read(output)))
  end
  assert(handle:stop(sys.SIGTERM))
  local result = assert(handle:wait(30000))
  local text = assert(Fs.read(output))
  assert(not result.timed_out and result.signal == sys.SIGTERM, text)
  assert(text:find("test: cancelled; every running test was ended", 1, true), text)
  assert(text:find("test: FAIL  suite.failed_test test_a_fails: ", 1, true), text)
  local named = text:match("its directory is kept: ([^\n]+)/real")
  assert(named ~= nil and named:find(assert(Fs.absolute(temp)) .. "/cosmic-test-", 1, true) == 1,
    text)
  assert(assert(Fs.read(named .. "/real/kept")) == "x", text)
end

--- A file under the tree named through a link outside it is still the
--- tree's: a test that writes a counter the environment names by such
--- a path stands on its second run, as it does named from the root.
local function test_a_tree_path_spelled_through_a_link_is_keyable(tmp: string)
  local root = tmp .. "/project"
  assert(Fs.mkdirs(root .. "/suite"))
  assert(Fs.write(root .. "/suite/counts_test.tl", [[
local Env = require("cosmic.env")
local Fs = require("cosmic.fs")
local function test_counts()
  local counter = assert(Env.get("COUNTER"))
  local before, _ = Fs.read(counter)
  assert(Fs.write(counter, (before or "") .. "x\n"))
end
]]))
  assert(Fs.symlink(root, tmp .. "/link"))
  local env = Env.all()
  env.TMPDIR = tmp .. "/temp"
  assert(Fs.mkdirs(env.TMPDIR))
  local output = tmp .. "/counts.out"
  for _, spelled in ipairs({ root, tmp .. "/link" }) do
    env.COUNTER = spelled .. "/counter-" .. Fs.basename(spelled)
    local tallies: {string} = {}
    for run = 1, 2 do
      local result = invoke(root, output, { "suite/counts_test.tl" }, env)
      local text = assert(Fs.read(output))
      assert(result.ok, text)
      tallies[run] = text:match("1 tests, 1 modules; (%d+ ran, %d+ stood)") or text
    end
    assert(tallies[1] == "1 ran, 0 stood" and tallies[2] == "0 ran, 1 stood",
      spelled .. ": " .. tallies[1] .. " then " .. tallies[2])
  end
end

--- Runs `source`, the tests of a module of a project with a/f "good"
--- and b/f "other", twice, then once more after a/f changes to "bad",
--- with PROJ and OUTSIDE naming the project and a directory beside it;
--- answers what each run printed.
local function three_runs(tmp: string, source: string): {string}
  local root = tmp .. "/proj"
  local outside = tmp .. "/outside"
  assert(Fs.mkdirs(root .. "/suite"))
  assert(Fs.mkdirs(root .. "/a"))
  assert(Fs.mkdirs(root .. "/b"))
  assert(Fs.mkdirs(outside))
  assert(Fs.write(root .. "/a/f", "good\n"))
  assert(Fs.write(root .. "/b/f", "other\n"))
  assert(Fs.write(root .. "/suite/link_test.tl", source))
  local env = Env.all()
  env.TMPDIR = tmp .. "/temp"
  env.PROJ = root
  env.OUTSIDE = outside
  assert(Fs.mkdirs(env.TMPDIR))
  local output = tmp .. "/link.out"
  local texts: {string} = {}
  for run = 1, 3 do
    if run == 3 then assert(Fs.write(root .. "/a/f", "bad\n")) end
    local _ = invoke(root, output, { "suite/link_test.tl" }, env)
    texts[run] = assert(Fs.read(output))
  end
  return texts
end

--- A verdict over a file read through a link outside the tree is over
--- the file the link led to when the test read it: a test that reads
--- through the link and then points it elsewhere does not stand, and
--- fails once the file it read changes.
local function test_a_link_retargeted_by_the_test_does_not_stand(tmp: string)
  local texts = three_runs(tmp, [[
local Env = require("cosmic.env")
local Fs = require("cosmic.fs")
local function test_link()
  local proj, link = assert(Env.get("PROJ")), assert(Env.get("OUTSIDE")) .. "/L"
  assert(Fs.remove(link))
  assert(Fs.symlink(proj .. "/a", link))
  assert(Fs.read(link .. "/f") == "good\n")
  assert(Fs.remove(link))
  assert(Fs.symlink(proj .. "/b", link))
end
]])
  assert(texts[1]:find("1 ran, 0 stood", 1, true), texts[1])
  assert(texts[2]:find("1 ran, 0 stood", 1, true), texts[2])
  assert(texts[3]:find("suite.link_test test_link:", 1, true), texts[3])
end

--- A link in the test's own directory into the tree -- to a directory
--- or to a file -- reads the tree: its verdict stands, and falls when
--- the file it read changes.
local function test_a_link_in_the_tests_directory_reads_the_tree(tmp: string)
  local texts = three_runs(tmp, [[
local Env = require("cosmic.env")
local Fs = require("cosmic.fs")
local function test_directory(tmp: string)
  assert(Fs.symlink(assert(Env.get("PROJ")) .. "/a", tmp .. "/D"))
  assert(Fs.read(tmp .. "/D/f") == "good\n")
end
local function test_file(tmp: string)
  assert(Fs.symlink(assert(Env.get("PROJ")) .. "/a/f", tmp .. "/L"))
  assert(Fs.read(tmp .. "/L") == "good\n")
end
]])
  assert(texts[1]:find("2 ran, 0 stood", 1, true), texts[1])
  assert(texts[2]:find("0 ran, 2 stood", 1, true), texts[2])
  assert(texts[3]:find("2 of 2 failed", 1, true), texts[3])
end

--- A path that climbs with ".." is not taken as the tree's by its
--- spelling: "<root>/../outside/A" and "../outside/R" through a link
--- the test retargets fail once the file they read changes. The two run
--- at once, so each retargets a link of its own.
local function test_a_path_that_climbs_is_outside(tmp: string)
  local texts = three_runs(tmp, [[
local Env = require("cosmic.env")
local Fs = require("cosmic.fs")
local function read_through(name: string, spelled: string)
  local proj, link = assert(Env.get("PROJ")), assert(Env.get("OUTSIDE")) .. "/" .. name
  assert(Fs.remove(link))
  assert(Fs.symlink(proj .. "/a/f", link))
  assert(Fs.read(spelled) == "good\n")
  assert(Fs.remove(link))
  assert(Fs.symlink(proj .. "/b", link))
end
local function test_absolute()
  read_through("A", assert(Env.get("PROJ")) .. "/../outside/A")
end
local function test_relative()
  read_through("R", "../outside/R")
end
]])
  assert(texts[1]:find("2 ran, 0 stood", 1, true), texts[1])
  assert(texts[3]:find("2 of 2 failed", 1, true), texts[3])
end

--- A fixture runtime's startup hooks pause one startup for a handshake;
--- a worker inheriting them would pause too, with nobody to release it.
local function test_workers_start_without_the_startup_hooks(tmp: string)
  local root = tmp .. "/project"
  assert(Fs.mkdirs(root .. "/suite"))
  assert(Fs.write(root .. "/suite/hooks_test.tl", [[
local Env = require("cosmic.env")
local function test_no_hooks()
  assert(Env.get("COSMIC_PORTABLE_STARTUP_TEST_READY") == nil)
  assert(Env.get("KEPT_BY_THE_WORKER") == "yes")
end
]]))
  local env = Env.all()
  env.COSMIC_PORTABLE_STARTUP_TEST_READY = tmp .. "/never"
  env.KEPT_BY_THE_WORKER = "yes"
  local output = tmp .. "/hooks.out"
  local result = invoke(root, output, { "suite/hooks_test.tl" }, env)
  assert(result.ok, assert(Fs.read(output)))
  local kept = test.worker_environment({ COSMIC_PORTABLE_STARTUP_TEST_GO = "x",
    COSMIC_PORTABLE_CACHE = "c", PATH = "p", COSMIC_REBOOTED = "1", OLDPWD = "/elsewhere" })
  assert(kept.COSMIC_PORTABLE_STARTUP_TEST_GO == nil)
  -- How this run was started -- after a tool rebuilt itself, from a
  -- shell that was elsewhere before -- is no worker's to see.
  assert(kept.COSMIC_REBOOTED == nil and kept.OLDPWD == nil)
  assert(kept.COSMIC_PORTABLE_CACHE == "c" and kept.PATH == "p")
end

local function test_a_report_reads_back_whole_or_not_at_all()
  local report: worker.Report = {
    loaded = true, passed = false, message = "line one\nline two", elapsed_ns = 42,
    load_reads = { { kind = "o", path = "a b\n", answer = "" } },
    test_reads = { { kind = "e", path = "HOME", answer = "ok /root" } },
    load_hits = { ["x.y"] = { [3] = true, [1] = true } },
    test_hits = {},
  }
  local text = worker.encode(report)
  local back = assert(worker.decode(text))
  assert(back.loaded and not back.passed and back.elapsed_ns == 42)
  assert(back.message == "line one\nline two")
  assert(back.load_reads[1].path == "a b\n" and back.load_reads[1].kind == "o")
  assert(back.test_reads[1].answer == "ok /root")
  assert(back.load_hits["x.y"][1] and back.load_hits["x.y"][3])
  local cut, trouble = worker.decode(text:sub(1, #text - 5))
  assert(cut == nil and trouble == "the report was cut short")
  assert(worker.decode("") == nil)
  assert(worker.decode("something else\nend\n") == nil)
  assert(worker.decode(text .. "extra\n") == nil)
end
