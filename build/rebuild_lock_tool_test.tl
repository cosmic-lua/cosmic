--- The rebuild lock between runs of this program in one checkout:
--- `cosmic test`, and a write of the projection, hold it, one run per
--- checkout at a time, and let it go however they end. Another process
--- holding or asking for it, or handed it, by a chunk is
--- build/rebuild_lock_lua_test.tl's; the rest is in
--- `rebuild_lock_test.tl`.

local Child = require("cosmic.child")
local Clock = require("cosmic.clock")
local Fs = require("cosmic.fs")
local Sqlite = require("cosmic.sqlite")
local Store = require("cosmic.store")
local importer = require("build.importer")
local teal = require("build.teal")
local work = require("build.work")
local writer = require("build.writer")
local sys = require("cosmic.sys")
local Test = require("cosmic.test")
local rebuild_lock = require("build.rebuild_lock")
local this_program = require("build.this_program")
local build_paths = require("build.paths")

--- The program itself, whose runs of a verb or a file hold the lock
--- against this process.
Test.policy{ profiles = { "cosmic" }, grants = { { path = "o/bin", letters = "rx" } } }

--- `root`'s build directory ([`build.paths`]), made, with `root` made
--- first where it is not there yet.
local function build_dir(root: string): string
  assert(Fs.mkdirs(root))
  return (assert(build_paths.prepare(root)))
end

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
  local deadline = Clock.monotonic_ns() + Clock.seconds(20)
  while not holds() do
    assert(Clock.monotonic_ns() < deadline, "gave up waiting for " .. what)
    assert(sys.nanosleep(Clock.ms(20)))
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
  local result = assert(h:wait(Clock.seconds(20)))
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
  project(root, Clock.seconds(60))
  local h = start_test(root, tmp .. "/interrupted.out")
  local _ = await("the run to take the lock", function(): boolean
    return Fs.read(build_dir(root) .. "/rebuild.lock.pid") ~= nil and
      rebuild_lock.take(root, 0, "write") == "busy"
  end)
  assert(h:stop(sys.SIGINT))
  local interrupted = assert(h:wait(Clock.seconds(20)))
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
  local failed = assert(start_test(root, tmp .. "/failed.out"):wait(Clock.seconds(20)))
  assert(not failed.ok, tostring((Fs.read(tmp .. "/failed.out"))))
  assert(rebuild_lock.take(root, 0, "write") == "held", "a failed run left the lock held")
  rebuild_lock.release()
end

--- A write of a checkout's projection, cosmic.db, waits while another
--- run holds the checkout's lock, saying so, and lands once it lets go:
--- here a file run, which builds its tree and writes the projection
--- (build/dispatch.tl), while this test holds the lock as `cosmic test`
--- does.
local function test_a_write_of_the_projection_waits_for_the_lock(tmp: string)
  local root = tmp .. "/project"
  assert(build_dir(root))
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
  local projection, _ = sys.stat(build_dir(root) .. "/cosmic.db")
  local unwritten = projection == nil
  rebuild_lock.release()
  local result = assert(h:wait(Clock.seconds(20)))
  local text = assert(Fs.read(output))
  assert(ok, tostring(failure) .. "\n" .. text)
  assert(running ~= nil and not running.finished, "the write did not wait:\n" .. text)
  assert(unwritten, "the projection was written under the lock")
  assert(result.ok, text)
  assert(text:find(build_dir(root) .. "/cosmic.db: another cosmic run (pid " .. tostring(sys.getpid()) ..
      ") in this checkout is running its tests; waiting for it", 1, true), text)
  assert(text:find("hello\n", 1, true), text)
end

--- A result waiting to publish keeps the rows and signature it compiled,
--- even when another run commits a failed or a different successful plan.
local function test_a_waiting_projection_keeps_its_compiled_snapshot(tmp: string)
  local built = assert(teal.load())
  for _, succeeds in ipairs({ false, true }) do
    local root = tmp .. (succeeds and "/valid" or "/failed")
    assert(build_dir(root))
    local original = 'print("original")\n'
    assert(Fs.write(root .. "/main.tl", original))
    assert(rebuild_lock.take(root, 0, "test") == "held")
    local output = root .. "/a.out"
    local fd = assert(Fs.open_write(output))
    local started = this_program.program({ "main.tl" }, {
      cwd = root, env = this_program.environment(), stdout = fd, stderr = fd,
      process_group = true,
    })
    local a = assert(Child.start(started.argv, started.options))
    assert(Fs.close(fd))
    local ok, failure = pcall(function()
      assert(await("the compiled result to wait for publication", function(): boolean
        return (Fs.read(output) or ""):find("waiting for it", 1, true) ~= nil
      end))
      local staged = assert(work.open(root))
      local first: importer.Result = {
        main = nil, tool = "", modules = {}, refused = {},
        compiled = 0, cached = 0, shared = 0, parses = { parsed = 0, shared = 0 },
      }
      local first_signature = assert(writer.signature(staged, first, Store.meta("writer") or ""))
      assert(work.close(staged))
      if succeeds then
        assert(Fs.write(root .. "/main.tl", 'print("replacement")\n'))
        local b = assert(work.open(root))
        assert(work.stage(b, false))
        local result = assert(importer.compile(b, built, "snapshot-test"))
        local alternate = root .. "/b.db"
        assert(writer.write_result(b, alternate, result))
        assert(work.close(b))
        local db = assert(Sqlite.open(alternate))
        local rows = assert(Sqlite.text_rows(db,
          "SELECT inflate(source) FROM modules WHERE path = 'main'"))
        assert(rows[1][1] == 'print("replacement")\n')
        assert(db:close())
      else
        assert(Fs.write(root .. "/main.tl", 'local broken: string = 42\nprint(broken)\n'))
        local command = this_program.program({ "main.tl" }, {
          cwd = root, env = this_program.environment(), stdout = "capture", stderr = "capture",
        })
        local failed = assert(Child.run(command.argv, command.options))
        assert(not failed.ok, failed.stdout .. failed.stderr)
      end
      rebuild_lock.release()
      local result = assert(a:wait(Clock.seconds(20)))
      local text = assert(Fs.read(output))
      assert(result.ok, text)
      assert(text:find("original\n", 1, true), text)
      local db = assert(Sqlite.open(build_dir(root) .. "/cosmic.db"))
      local rows = assert(Sqlite.text_rows(db,
        "SELECT inflate(source) FROM modules WHERE path = 'main'"))
      assert(rows[1][1] == original, "published another run's source")
      local signed = assert(Sqlite.text_rows(db,
        "SELECT value FROM meta WHERE key = 'projected'"))
      assert(signed[1][1] == first_signature, "published another run's signature")
      assert(db:close())
    end)
    rebuild_lock.release()
    if not ok then
      local _ = a:stop(sys.SIGKILL)
      local _ = a:wait(Clock.seconds(20))
      error(failure)
    end
  end
end
