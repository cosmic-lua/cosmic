--- The rebuild lock between runs of this program in one checkout:
--- `cosmic test`, and a write of the projection, hold it, one run per
--- checkout at a time, and let it go however they end. Another process
--- holding or asking for it, or handed it, by a chunk is
--- build/rebuild_lock_lua_test.tl's; the rest is in
--- `rebuild_lock_test.tl`.

local Child = require("cosmic.child")
local Fs = require("cosmic.fs")
local sys = require("cosmic.sys")
local Test = require("cosmic.test")
local Time = require("cosmic.time")
local rebuild_lock = require("build.rebuild_lock")
local this_program = require("build.this_program")

--- The program itself, whose runs of a verb or a file hold the lock
--- against this process.
Test.needs{ tool = true }

--- A project whose one test passes, and sleeps `sleep_ns` first.
local function project(root: string, sleep_ns: integer)
  assert(Fs.mkdirs(root .. "/suite"))
  assert(Fs.write(root .. "/suite/slow_test.tl", table.concat({
    'local sys = require("cosmic.sys")',
    "local function test_slow()",
    "  assert(sys.nanosleep(" .. tostring(sleep_ns) .. "))",
    "end",
  }, "\n") .. "\n"))
end

--- Starts `cosmic test` on `root`, its stdout and stderr to `output`.
--- Its workers run unsandboxed (`COSMIC_TEST_SANDBOX=0`): the lock is
--- the run's, not its workers', and a sandbox nested in this test's own
--- is one a host may refuse, so the run means the same everywhere.
local function start_test(root: string, output: string): Child.Handle
  local fd = assert(Fs.open_write(output))
  local env = this_program.environment()
  env.COSMIC_TEST_SANDBOX = "0"
  env.COSMIC_VERDICT_CACHE = "0"
  local started = this_program.program({ "test" }, {
    cwd = root, env = env, stdout = fd, stderr = fd, process_group = true,
  })
  local h = assert(Child.start(started.argv, started.options))
  assert(Fs.close(fd))
  return h
end

--- Waits up to 20 s for `holds` to answer true, checking every 20 ms,
--- and answers true once it has.
local function await(what: string, holds: function(): boolean): boolean
  local deadline = Time.monotonic_ns() + Time.seconds(20)
  while not holds() do
    assert(Time.monotonic_ns() < deadline, "gave up waiting for " .. what)
    assert(sys.nanosleep(Time.ms(20)))
  end
  return true
end

--- A second run in a checkout waits for the run holding its lock, saying
--- so and naming what that run is doing, and passes once it lets go.
--- The first run is this test, holding the lock as `cosmic test` does.
local function test_a_second_run_waits_for_the_first_then_passes(tmp: string)
  local root = tmp .. "/project"
  project(root, 0)
  assert(rebuild_lock.hold(root, "test", "test"))
  local output = tmp .. "/second.out"
  local h = start_test(root, output)
  local ok, failure = pcall(await, "the second run to wait", function(): boolean
    local text = Fs.read(output) or ""
    return text:find("waiting for it", 1, true) ~= nil
  end)
  local running, _ = h:try_wait()
  rebuild_lock.release()
  local result = assert(h:wait(Time.seconds(20)))
  local text = assert(Fs.read(output))
  assert(ok, tostring(failure) .. "\n" .. text)
  assert(running ~= nil and not running.finished, "the second run did not wait:\n" .. text)
  assert(result.ok, text)
  assert(text:find("test: another cosmic run (pid " .. tostring(sys.getpid()) ..
    ") in this checkout is running its tests; waiting for it", 1, true), text)
  assert(text:find("test: PASS", 1, true), text)
end

--- A run lets its checkout's lock go however it ends: once it has
--- failed, and once it is interrupted mid-run, a run after it takes the
--- lock at once.
local function test_a_run_lets_the_lock_go_on_failure_and_interrupt(tmp: string)
  local root = tmp .. "/project"
  project(root, Time.seconds(60))
  local h = start_test(root, tmp .. "/interrupted.out")
  local _ = await("the run to take the lock", function(): boolean
    return Fs.read(root .. "/o/rebuild.lock.pid") ~= nil and
      rebuild_lock.take(root, 0, "write") == "busy"
  end)
  assert(h:stop(sys.SIGINT))
  local interrupted = assert(h:wait(Time.seconds(20)))
  assert(not interrupted.ok, "an interrupted run passed")
  -- Each half is let go with its descriptor, which the run opens
  -- close-on-exec: these fail should a process the run starts inherit
  -- it, and keep the flock, which outlives the run in any process
  -- holding the same open file.
  assert(rebuild_lock.take(root, 0, "write") == "held",
    "an interrupted run left the lock held:\n" .. tostring((Fs.read(tmp .. "/interrupted.out"))))
  rebuild_lock.release()

  assert(Fs.write(root .. "/suite/slow_test.tl",
    "local function test_fails()\n  error(\"no\")\nend\n"))
  local failed = assert(start_test(root, tmp .. "/failed.out"):wait(Time.seconds(20)))
  assert(not failed.ok, tostring((Fs.read(tmp .. "/failed.out"))))
  assert(rebuild_lock.take(root, 0, "write") == "held", "a failed run left the lock held")
  rebuild_lock.release()
end

--- A write of a checkout's projection, o/cosmic.db, waits while another
--- run holds the checkout's lock, saying so, and lands once it lets go:
--- here a file run, which builds its tree and writes the projection
--- (build/dispatch.tl), while this test holds the lock as `cosmic test`
--- does.
local function test_a_write_of_the_projection_waits_for_the_lock(tmp: string)
  local root = tmp .. "/project"
  assert(Fs.mkdirs(root .. "/o"))
  assert(Fs.write(root .. "/hello.tl", 'print("hello")\n'))
  assert(rebuild_lock.take(root, 0, "test") == "held")
  local output = tmp .. "/run.out"
  local fd = assert(Fs.open_write(output))
  local started = this_program.program({ "hello.tl" }, {
    cwd = root, env = this_program.environment(), stdout = fd, stderr = fd,
    process_group = true,
  })
  local h = assert(Child.start(started.argv, started.options))
  assert(Fs.close(fd))
  local ok, failure = pcall(await, "the write to wait", function(): boolean
    local text = Fs.read(output) or ""
    return text:find("waiting for it", 1, true) ~= nil
  end)
  local running, _ = h:try_wait()
  local projection, _ = sys.stat(root .. "/o/cosmic.db")
  local unwritten = projection == nil
  rebuild_lock.release()
  local result = assert(h:wait(Time.seconds(20)))
  local text = assert(Fs.read(output))
  assert(ok, tostring(failure) .. "\n" .. text)
  assert(running ~= nil and not running.finished, "the write did not wait:\n" .. text)
  assert(unwritten, "the projection was written under the lock")
  assert(result.ok, text)
  assert(text:find("o/cosmic.db: another cosmic run (pid " .. tostring(sys.getpid()) ..
    ") in this checkout is running its tests; waiting for it", 1, true), text)
  assert(text:find("hello\n", 1, true), text)
end
