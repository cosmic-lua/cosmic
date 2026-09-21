local Child = require("cosmic.child")
local Fs = require("cosmic.fs")
local sys = require("cosmic.sys")
local Proc = require("cosmic.proc")
local Time = require("cosmic.time")

local function temporary(): string
  return assert(Fs.mkdtemp("cosmic-child-"))
end

local function output(dir: string, name: string): integer, string
  local path = dir .. "/" .. name
  return assert(Fs.open_write(path)), path
end

local function test_start_failure_is_not_exit_127()
  local h, trouble = Child.start({ "/definitely/not/a/cosmic-command" })
  assert(h == nil)
  assert(trouble:find("start:", 1, true))
  local r = assert(Child.run({ "/bin/sh", "-c", "exit 127" }))
  assert(r.code == 127 and not r.ok)
end

local function test_argv_environment_directory_and_file_output()
  local dir = temporary()
  local fd, path = output(dir, "answer")
  local r = assert(Child.run({ "/bin/sh", "-c",
    "printf '%s|%s|%s' \"$1\" \"$2\" \"$WORD\"; pwd", "sh", "a b", "" },
    { cwd = dir, env = { WORD = "value" }, stdout = fd }))
  assert(Fs.close(fd))
  assert(r.ok)
  assert(assert(Fs.read(path)) == "a b||value" .. dir .. "\n")
end

local function test_large_redirect_does_not_depend_on_pipe_capacity()
  local dir = temporary()
  local fd, path = output(dir, "large")
  local r = assert(Child.run({ "/bin/sh", "-c",
    "i=0; while [ $i -lt 10000 ]; do printf 0123456789; i=$((i+1)); done" },
    { stdout = fd }))
  assert(Fs.close(fd))
  assert(r.ok and #assert(Fs.read(path)) == 100000)
end

local function test_redirect_source_descriptor_does_not_leak()
  local dir = temporary()
  local fd = assert(Fs.open_write(dir .. "/out"))
  local r = assert(Child.run({ "/bin/sh", "-c",
    "test ! -e /dev/fd/$SOURCE" },
    { env = { SOURCE = tostring(fd) }, stdout = fd }))
  assert(Fs.close(fd))
  assert(r.ok)
end

local function test_nonzero_and_signal_status()
  local exited = assert(Child.run({ "/bin/sh", "-c", "exit 23" }))
  assert(exited.code == 23 and exited.signal == nil and not exited.ok)
  local signaled = assert(Child.run({ "/bin/sh", "-c", "kill -TERM $$" }))
  assert(signaled.code == nil and signaled.signal == sys.SIGTERM)
end

local function test_timeout_kills_the_process_group_and_reaps_child()
  local dir = temporary()
  local fd, path = output(dir, "descendant")
  local h = assert(Child.start({ "/bin/sh", "-c",
    "sleep 30 & printf %s $!; wait" },
    { stdout = fd, stderr = fd }))
  local deadline = assert(Time.monotonic_ns()) + 1000 * 1000 * 1000
  while assert(Fs.stat(path)).size == 0 and assert(Time.monotonic_ns()) < deadline do
    Time.sleep_ns(10 * 1000 * 1000)
  end
  assert(assert(Fs.stat(path)).size > 0, "child did not report readiness")
  local r = assert(h:wait(40))
  assert(Fs.close(fd))
  assert(r.timed_out and not r.ok)
  -- A process-group timeout includes descendants. Signal zero would succeed
  -- for a surviving process (or fail with EPERM, not ESRCH).
  local pid = math.tointeger(assert(tonumber(assert(Fs.read(path)))))
  assert(pid)
  local alive = sys.kill(pid, 0)
  assert(not alive)
end

local function test_run_forwards_parent_cancellation_after_group_cleanup()
  local dir = temporary()
  local fd, path = output(dir, "descendant")
  local executable = assert(Proc.executable())
  local driver = assert(Child.start({ executable,
    "_tool/child_cancel_fixture.tl" },
    { stdout = fd, stderr = fd, process_group = false }))
  local deadline = assert(Time.monotonic_ns()) + 3000 * 1000 * 1000
  while assert(Fs.stat(path)).size == 0 and assert(Time.monotonic_ns()) < deadline do
    Time.sleep_ns(10 * 1000 * 1000)
  end
  assert(assert(Fs.stat(path)).size > 0, "driver did not report readiness")
  assert(driver:stop(sys.SIGTERM))
  local stopped = assert(driver:wait(2000))
  -- The test harness may itself have installed a SIGTERM disposition, which
  -- the nested driver correctly restores. Either signal death or its fixture
  -- surfacing cancellation as nonzero proves it did not resume normally.
  assert(not stopped.ok)
  assert(Fs.close(fd))
  local descendant = assert(math.tointeger(assert(tonumber(
    assert(Fs.read(path)):match("%d+")))))
  local gone_by = assert(Time.monotonic_ns()) + 1000 * 1000 * 1000
  while sys.kill(descendant, 0) and assert(Time.monotonic_ns()) < gone_by do
    Time.sleep_ns(10 * 1000 * 1000)
  end
  assert(not sys.kill(descendant, 0))
end
