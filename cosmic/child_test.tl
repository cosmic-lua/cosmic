local Child = require("cosmic.child")
local Env = require("cosmic.env")
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

local function nested_cosmic_environment(): {string:string}
  local environment = Env.all()
  -- These hooks belong to the portable test's outer Cosmic startups. A
  -- nested fixture has no matching FIFO handshake and must not inherit them.
  environment.COSMIC_PORTABLE_STARTUP_TEST_READY = nil
  environment.COSMIC_PORTABLE_STARTUP_TEST_GO = nil
  return environment
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
  assert(assert(Fs.read(path)) == "a b||value" .. assert(Fs.absolute(dir)) .. "\n")
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

local function test_non_group_timeout_returns_graceful_term_status()
  local dir = temporary()
  local ready = dir .. "/ready"
  local h = assert(Child.start({ "/bin/sh", "-c",
    "trap 'exit 19' TERM; printf ready >\"$1\"; while :; do :; done",
    "sh", ready }, { process_group = false }))
  local deadline = assert(Time.monotonic_ns()) + 1000 * 1000 * 1000
  while not Fs.exists(ready) and assert(Time.monotonic_ns()) < deadline do
    Time.sleep_ns(10 * 1000 * 1000)
  end
  assert(Fs.exists(ready), "child did not report readiness")
  local r = assert(h:wait(0))
  assert(r.code == 19 and r.signal == nil and r.timed_out)
end

local function test_spawn_validates_fds_and_preserves_cloexec_stdio()
  local dir = temporary()
  local fixture = dir .. "/driver.tl"
  assert(Fs.write(fixture, [[
local Child = require("cosmic.child")
local Fs = require("cosmic.fs")
return function(): integer
  Fs.close(11)
  local invalid = Child.start({ "/bin/true" }, { stdout = 11 })
  if invalid then invalid:close(); return 20 end
  assert(Fs.close(0))
  local fd = assert(Fs.open_read("/dev/null"))
  assert(fd == 0)
  local result = assert(Child.run({ "/bin/sh", "-c", "test -e /dev/fd/0" },
    { stdin = fd, process_group = false }))
  return result.ok and 0 or 21
end
]]))
  local executable = assert(Proc.executable())
  local result = assert(Child.run({ executable, fixture },
    { env = nested_cosmic_environment() }))
  assert(result.ok, "descriptor fixture exited " .. tostring(result.code))
end

local function test_run_forwards_parent_cancellation_after_group_cleanup()
  local dir = temporary()
  local ready = dir .. "/ready"
  local descendant_path = dir .. "/descendant"
  local fixture = dir .. "/driver.tl"
  assert(Fs.write(fixture, [[
local Child = require("cosmic.child")
return function(argv: {string}): integer
  local result, trouble = Child.run({ "/bin/sh", "-c",
    "sleep 30 & printf %s $! >\"$1\"; printf ready >\"$2\"; wait",
    "sh", argv[1], argv[2] })
  if not result then error(trouble) end
  local finished = assert(result)
  return finished.code or 1
end
]]))
  local fd, diagnostic = output(dir, "driver.log")
  local executable = assert(Proc.executable())
  local driver = assert(Child.start({ executable, fixture,
    descendant_path, ready },
    { env = nested_cosmic_environment(), stdout = fd, stderr = fd,
      process_group = false }))
  local deadline = assert(Time.monotonic_ns()) + 3000 * 1000 * 1000
  while (not Fs.exists(ready) or Fs.read(ready) ~= "ready") and
      assert(Time.monotonic_ns()) < deadline do
    Time.sleep_ns(10 * 1000 * 1000)
  end
  assert(Fs.exists(ready) and Fs.read(ready) == "ready",
    "driver did not report readiness; log=" .. (Fs.read(diagnostic) or "<none>"))
  assert(driver:stop(sys.SIGTERM))
  local stopped = assert(driver:wait(2000))
  assert(Fs.close(fd))
  assert(stopped.signal == sys.SIGTERM,
    "driver cancellation result code=" .. tostring(stopped.code) ..
    " signal=" .. tostring(stopped.signal) .. " log=" ..
    (Fs.read(diagnostic) or "<none>"))
  local descendant = assert(math.tointeger(assert(tonumber(
    assert(Fs.read(descendant_path)):match("%d+")))))
  local gone_by = assert(Time.monotonic_ns()) + 1000 * 1000 * 1000
  while sys.kill(descendant, 0) and assert(Time.monotonic_ns()) < gone_by do
    Time.sleep_ns(10 * 1000 * 1000)
  end
  assert(not sys.kill(descendant, 0))
end

local function test_invalid_inputs_do_not_poison_signal_guard()
  assert(not pcall(Child.run, { "/bin/sh" }, { stdout = "bad" } as Child.Options))
  assert(not pcall(Child.run, { "/bin/sh\0bad" }))
  assert(not pcall(Child.run, { "/bin/sh" }, { cwd = "/tmp\0bad" } as Child.Options))
  assert(not pcall(Child.run, { "/bin/sh" },
    { env = { ["BAD=NAME"] = "value" } } as Child.Options))
  assert(not pcall(Child.run, { "/bin/sh" },
    { env = { NAME = "value\0tail" } } as Child.Options))
  assert(not pcall(Child.run, { "/bin/sh" },
    { stdout = 2147483648 } as Child.Options))
  assert(not pcall(sys.kill, 2147483648, 0))
  assert(not pcall(sys.waitpid, 2147483648, true))
  local result = assert(Child.run({ "/bin/sh", "-c", "exit 0" }))
  assert(result.ok)
end
