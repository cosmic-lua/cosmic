#!/usr/bin/env cosmic
local child = require("cosmic.child")
local fs = require("cosmic.fs")
local proc = require("cosmic.proc")
local env = require("cosmic.env")
local time = require("cosmic.time")
local signal = require("cosmic.signal")
-- cosmo.unix is required directly only for raw fd ops (unix.close) and to
-- monkey-patch unix.fork for fault injection (test_spawn_fork_failure), which
-- must share the exact module table that child.tl uses.
local unix = require("cosmo.unix")

local lua_bin = fs.join(os.getenv("TEST_BIN"), "cosmic")
local TEST_TMPDIR = os.getenv("TEST_TMPDIR")

-- === Issue #527 TDD cases (a)-(e) ===

-- (a) kill a long-running child; wait() reports the terminating signal.
local function test_kill_reports_signal()
  local h = child.spawn({"sleep", "10"}) as child.Handle
  assert(h ~= nil, "spawn should succeed")
  assert(h:kill(), "kill (default SIGTERM) should succeed")
  local r = h:wait() as child.Result
  assert(r ~= nil, "wait should return a Result")
  assert(r.signal == signal.SIGTERM,
    "expected SIGTERM, got signal=" .. tostring(r.signal) .. " code=" .. tostring(r.code))
  assert(r.signal == 15, "SIGTERM should be 15, got " .. tostring(r.signal))
  assert(r.code == nil, "a signaled child has no exit code")
  assert(r.ok == false, "a signaled child is not ok")
end
test_kill_reports_signal()

-- (b) wait() is idempotent: the reaped Result is cached and returned again.
local function test_wait_idempotent()
  local h = child.spawn({lua_bin, "-e", "os.exit(3)"}) as child.Handle
  assert(h ~= nil, "spawn should succeed")
  local r1 = h:wait() as child.Result
  local r2 = h:wait() as child.Result
  assert(r1 == r2, "second wait() must return the same cached Result")
  assert(r1.code == 3, "expected code 3, got " .. tostring(r1.code))
end
test_wait_idempotent()

-- (c) wait(timeout_ms) returns nil, "timeout" for a child that has not exited;
-- the handle stays usable so we can then kill and reap it.
local function test_wait_timeout()
  local h = child.spawn({"sleep", "10"}) as child.Handle
  assert(h ~= nil, "spawn should succeed")
  local r, err = h:wait(100)
  assert(r == nil, "expected nil Result on timeout")
  assert(err == "timeout", "expected 'timeout', got " .. tostring(err))
  h:kill(signal.SIGKILL)
  local r2 = h:wait() as child.Result
  assert(r2.signal == signal.SIGKILL, "expected SIGKILL after timeout+kill")
end
test_wait_timeout()

-- (d) a missing executable makes spawn() itself fail with a visible ENOENT,
-- not a bogus exit code from a later wait().
local function test_exec_failure_visible()
  local h, err = child.spawn({"/no/such/bin"})
  assert(h == nil, "spawn should fail for a missing executable")
  assert(err ~= nil and err:match("ENOENT"),
    "expected ENOENT in error, got " .. tostring(err))
end
test_exec_failure_visible()

-- (e) run() captures stdout and stderr independently along with the exit code.
local function test_run_captures_streams_and_code()
  local r = child.run({"sh", "-c", "echo o; echo e >&2; exit 3"}) as child.Result
  assert(r ~= nil, "run should succeed")
  assert(r.stdout == "o\n", "expected stdout 'o\\n', got '" .. tostring(r.stdout) .. "'")
  assert(r.stderr == "e\n", "expected stderr 'e\\n', got '" .. tostring(r.stderr) .. "'")
  assert(r.code == 3, "expected code 3, got " .. tostring(r.code))
  assert(r.ok == false, "exit 3 is not ok")
end
test_run_captures_streams_and_code()

-- === High-level run/spawn behavior ===

local function test_run_simple()
  local r = child.run({lua_bin, "-e", "print('hello')"}) as child.Result
  assert(r ~= nil, "run should succeed")
  assert(r.ok, "command should succeed")
  assert(r.stdout == "hello\n", "expected 'hello\\n', got '" .. tostring(r.stdout) .. "'")
end
test_run_simple()

local function test_command_not_found()
  local h, err = child.spawn({"nonexistent_command_12345"})
  assert(h == nil, "handle should be nil for nonexistent command")
  assert(err:find("command not found", 1, true), "expected 'command not found' in error: " .. tostring(err))
end
test_command_not_found()

local function test_run_exit_code()
  local r = child.run({lua_bin, "-e", "os.exit(0)"}) as child.Result
  assert(r.code == 0, "expected exit code 0, got " .. tostring(r.code))
  assert(r.ok, "exit 0 should be ok")

  r = child.run({lua_bin, "-e", "os.exit(1)"}) as child.Result
  assert(r.code == 1, "expected exit code 1, got " .. tostring(r.code))
  assert(not r.ok, "exit 1 should not be ok")
end
test_run_exit_code()

local function test_run_stdin_string()
  local r = child.run({lua_bin, "-e", "io.write(io.read('*a'))"}, {stdin = "hello from stdin"}) as child.Result
  assert(r.ok, "command should succeed")
  assert(r.stdout == "hello from stdin", "expected 'hello from stdin', got '" .. tostring(r.stdout) .. "'")
end
test_run_stdin_string()

local function test_run_cwd_option()
  local r = child.run({"pwd"}, {cwd = TEST_TMPDIR}) as child.Result
  assert(r.ok, "pwd should succeed, code: " .. tostring(r.code) .. " stderr: " .. tostring(r.stderr))
  local pwd_output = r.stdout:gsub("\n$", "")
  assert(pwd_output == TEST_TMPDIR, "expected pwd '" .. TEST_TMPDIR .. "', got '" .. tostring(pwd_output) .. "'")
end
test_run_cwd_option()

-- === Handle-level methods: try_wait, read, kill-after-reap ===

local function test_try_wait()
  local h = child.spawn({"sleep", "10"}) as child.Handle
  assert(h:try_wait() == nil, "try_wait on a running child returns nil")
  h:kill(signal.SIGKILL)
  local res: child.Result = nil
  for _ = 1, 200 do
    res = h:try_wait() as child.Result
    if res ~= nil then break end
    time.sleep(0, 10000000) -- 10ms
  end
  assert(res ~= nil, "try_wait should eventually reap the killed child")
  assert(res.signal == signal.SIGKILL, "expected SIGKILL, got signal=" .. tostring(res.signal))
end
test_try_wait()

local function test_read_streaming()
  local h = child.spawn({lua_bin, "-e", "io.write('abcdef'); io.flush()"}) as child.Handle
  local chunk = h:read(3) as string
  assert(chunk ~= nil and #chunk >= 1, "streaming read should return bytes, got " .. tostring(chunk))
  local r = h:wait() as child.Result
  assert(chunk .. r.stdout == "abcdef",
    "streamed + pumped output should reassemble, got '" .. chunk .. "' + '" .. r.stdout .. "'")
end
test_read_streaming()

local function test_abandoned_handle_reaped()
  -- Dropping an un-waited handle must not leak a zombie: the __gc finalizer
  -- SIGKILLs and reaps the child. Lua 5.4 runs finalizers synchronously in
  -- collectgarbage(), and the reap is a blocking wait, so by the time gc
  -- returns the pid is gone (kill(pid, 0) fails with ESRCH).
  local pid: integer = 0
  do
    local h = child.spawn({"sleep", "30"}) as child.Handle
    pid = h.pid
  end
  collectgarbage("collect")
  collectgarbage("collect")
  time.sleep(0, 100000000) -- 100ms for the kernel to finish teardown
  assert(not proc.kill(pid, 0), "abandoned child should be killed and reaped, not left alive/zombie")
end
test_abandoned_handle_reaped()

local function test_kill_after_reap_fails()
  local h = child.spawn({lua_bin, "-e", "os.exit(0)"}) as child.Handle
  h:wait()
  local ok, err = h:kill()
  assert(not ok, "kill after reap should fail")
  assert(err ~= nil, "kill after reap should report an error")
end
test_kill_after_reap_fails()

-- === Environment ===

local function test_spawn_inherits_env()
  local sentinel = "cosmic_test_inherit_" .. tostring(proc.getpid())
  env.set("COSMIC_TEST_SENTINEL", sentinel)
  local r = child.run({lua_bin, "-e", [[
    io.write(os.getenv("COSMIC_TEST_SENTINEL") or "")
  ]]}) as child.Result
  assert(r.ok, "child should exit 0, got code " .. tostring(r.code))
  assert(r.stdout == sentinel, "expected '" .. sentinel .. "', got '" .. tostring(r.stdout) .. "'")
end
test_spawn_inherits_env()

local function test_spawn_with_env_map()
  local sentinel = "cosmic_test_map_" .. tostring(proc.getpid())
  env.set("COSMIC_TEST_MAP", sentinel)
  local vars = env.all()
  local r = child.run({lua_bin, "-e", [[
    io.write(os.getenv("COSMIC_TEST_MAP") or "")
  ]]}, {env = vars as {string}}) as child.Result
  assert(r.ok, "child should exit 0, got code " .. tostring(r.code))
  assert(r.stdout == sentinel, "expected '" .. sentinel .. "', got '" .. tostring(r.stdout) .. "'")
end
test_spawn_with_env_map()

local function test_spawn_with_env_list()
  local sentinel = "cosmic_test_list_" .. tostring(proc.getpid())
  env.set("COSMIC_TEST_LIST", sentinel)
  local vars = env.list()
  local r = child.run({lua_bin, "-e", [[
    io.write(os.getenv("COSMIC_TEST_LIST") or "")
  ]]}, {env = vars}) as child.Result
  assert(r.ok, "child should exit 0, got code " .. tostring(r.code))
  assert(r.stdout == sentinel, "expected '" .. sentinel .. "', got '" .. tostring(r.stdout) .. "'")
end
test_spawn_with_env_list()

-- === fork-failure fd-cleanup ===

local function test_spawn_fork_failure()
  -- Monkey-patch unix.fork to simulate a fork failure; child.tl calls
  -- unix.fork() via the shared module table, so this affects child.spawn.
  -- cwd forces the fork path (the posix_spawn fast path cannot chdir).
  local real_fork = rawget(unix, "fork")
  rawset(unix, "fork", function(): number return nil end)
  local handle, err = child.spawn({lua_bin, "-e", "print('x')"}, {cwd = "."})
  rawset(unix, "fork", real_fork)
  assert(handle == nil, "expected nil handle on fork failure, got: " .. tostring(handle))
  assert(type(err) == "string", "expected error string on fork failure, got: " .. type(err))
  assert(err:find("fork", 1, true), "expected 'fork' in error message: " .. tostring(err))
end
test_spawn_fork_failure()

local function test_spawn_fast_failure()
  -- Same cleanup contract for the posix_spawn fast path: a spawn failure
  -- must surface from spawn() itself, with the handle nil.
  local real_spawn = rawget(unix, "spawn")
  rawset(unix, "spawn", function(): number, string, number
      return nil, "spawn: EAGAIN: Resource temporarily unavailable", 11
    end)
  local handle, err = child.spawn({lua_bin, "-e", "print('x')"})
  rawset(unix, "spawn", real_spawn)
  assert(handle == nil, "expected nil handle on spawn failure, got: " .. tostring(handle))
  assert(err ~= nil and err:find("exec failed", 1, true),
    "expected 'exec failed' in error message: " .. tostring(err))
end
test_spawn_fast_failure()

-- === deadlock regression: large stderr output ===

local function test_run_no_deadlock_large_stderr()
  local r = child.run({lua_bin, "-e", [[
    io.write("stdout ok\n")
    io.flush()
    local big = string.rep("x", 131072)
    io.stderr:write(big)
    io.stderr:flush()
    os.exit(0)
  ]]}) as child.Result
  assert(r.code == 0, "expected exit code 0, got " .. tostring(r.code))
  assert(r.stdout == "stdout ok\n", "expected 'stdout ok\\n', got '" .. tostring(r.stdout) .. "'")
  assert(#r.stderr == 131072, "expected 128KB stderr, got " .. #r.stderr)
end
test_run_no_deadlock_large_stderr()

-- === /zip/ binary execution via fexecve ===

local function test_prepare_zip_exec()
  local prepare_zip_exec = child.prepare_zip_exec
  assert(prepare_zip_exec, "prepare_zip_exec should be exported")
  local fd, err = prepare_zip_exec("/zip/main.lua")
  assert(fd, "should open zip fd: " .. tostring(err))
  assert(fd > 0, "fd should be positive: " .. tostring(fd))
  unix.close(fd)
end
test_prepare_zip_exec()

local function test_prepare_zip_exec_nonexistent()
  local fd, err = child.prepare_zip_exec("/zip/nonexistent_12345")
  assert(fd == nil, "should fail for nonexistent zip path")
  assert(err, "should have error message")
  assert(err:find("zip", 1, true), "expected zip-related error: " .. err)
end
test_prepare_zip_exec_nonexistent()

local function test_spawn_zip_nonexistent_path()
  local handle, err = child.spawn({"/zip/nonexistent_binary_12345"})
  assert(handle == nil, "handle should be nil for nonexistent /zip/ path")
  assert(err, "should have error message")
  assert(err:find("zip", 1, true) or err:find("not found", 1, true),
    "expected zip-related error, got: " .. tostring(err))
end
test_spawn_zip_nonexistent_path()

local function test_spawn_zip_non_executable()
  -- /zip/main.lua exists but is not an ELF binary, so fexecve fails. With the
  -- exec-status pipe, that failure surfaces from spawn itself, not a fake 127.
  local handle, err = child.spawn({"/zip/main.lua"})
  assert(handle == nil, "spawn should fail: fexecve of a non-binary is an exec error")
  assert(err ~= nil and err:find("exec failed", 1, true),
    "expected an 'exec failed' error, got: " .. tostring(err))
end
test_spawn_zip_non_executable()

local function test_spawn_zip_embedded_binary()
  -- embed /bin/echo into a copy of cosmic, then spawn it from /zip/
  local tmpdir = os.getenv("TEST_TMPDIR") as string

  local bin_dir = fs.join(tmpdir, "embed", ".bin")
  fs.makedirs(bin_dir)
  local echo_data = fs.read("/bin/echo")
  assert(echo_data, "should read /bin/echo")
  fs.write(fs.join(bin_dir, "echo"), echo_data)
  fs.chmod(fs.join(bin_dir, "echo"), 493) -- 0755

  local out_bin = fs.join(tmpdir, "cosmic-with-echo")
  local build = child.run(
    {lua_bin, "--embed", fs.join(tmpdir, "embed"), "--output", out_bin}) as child.Result
  assert(build ~= nil, "embed run should succeed")
  assert(build.ok, "embed should exit 0, got " .. tostring(build.code) .. ": " .. build.stderr)

  -- run the embedded binary: spawn /zip/.bin/echo via fexecve
  local r = child.run({out_bin, "-e", [[
    local child = require("cosmic.child")
    local r = child.run({"/zip/.bin/echo", "hello-from-zip"})
    assert(r, "spawn /zip/.bin/echo failed")
    io.write(r.stdout)
  ]]}) as child.Result
  assert(r ~= nil, "should run embedded binary")
  assert(r.ok, "embedded binary should succeed: " .. tostring(r.stderr))
  assert(r.stdout == "hello-from-zip\n",
    "expected 'hello-from-zip\\n', got '" .. tostring(r.stdout) .. "'")
end
test_spawn_zip_embedded_binary()

-- === fd redirection correctness ===

local function test_spawn_stdout_stderr_separate()
  local r = child.run({lua_bin, "-e", [[
    io.stdout:write("to-stdout\n")
    io.stdout:flush()
    io.stderr:write("to-stderr\n")
    io.stderr:flush()
  ]]}) as child.Result
  assert(r.ok, "command should succeed, exit=" .. tostring(r.code))
  assert(r.stdout == "to-stdout\n",
    "expected 'to-stdout\\n' on stdout, got '" .. tostring(r.stdout) .. "'")
  assert(r.stderr == "to-stderr\n",
    "expected 'to-stderr\\n' on stderr, got '" .. tostring(r.stderr) .. "'")
end
test_spawn_stdout_stderr_separate()

local function test_spawn_many_captures_correct()
  for i = 1, 5 do
    local r = child.run({lua_bin, "-e",
        "io.write('iter" .. tostring(i) .. "\\n')"}) as child.Result
    assert(r.ok, "iteration " .. i .. " should succeed")
    assert(r.stdout == "iter" .. tostring(i) .. "\n",
      "expected 'iter" .. i .. "\\n', got '" .. tostring(r.stdout) .. "'")
  end
end
test_spawn_many_captures_correct()

-- === spawn hygiene (#526 item 5 / #539) ===

local function test_spawn_does_not_mutate_argv()
  local argv = {"echo", "x"}
  local h = child.spawn(argv) as child.Handle
  assert(h ~= nil, "spawn should succeed")
  h:wait()
  assert(argv[1] == "echo",
    "spawn must not mutate caller's argv[1], got '" .. tostring(argv[1]) .. "'")
end
test_spawn_does_not_mutate_argv()

local function test_spawn_overlap_no_stdin_leak()
  -- CLOEXEC pipes stop a later child from inheriting an earlier child's stdin
  -- write end. Spawn A (reads stdin to EOF), then a long-lived B; A must see
  -- EOF once the parent closes its write end and finish without waiting on B.
  local a = child.spawn({lua_bin, "-e", "io.write(io.read('*a') or '')"},
    {stdin = "hello"}) as child.Handle
  assert(a ~= nil, "spawn A should succeed")
  local b = child.spawn({lua_bin, "-e", "require('cosmic.time').sleep(10)"}) as child.Handle
  assert(b ~= nil, "spawn B should succeed")

  local s0, n0 = time.monotonic()
  local r = a:wait() as child.Result
  local s1, n1 = time.monotonic()
  local elapsed = (s1 - s0) + (n1 - n0) / 1e9

  assert(r.code == 0, "A should exit 0, got " .. tostring(r.code))
  assert(r.stdout == "hello", "A should echo its stdin, got '" .. tostring(r.stdout) .. "'")
  assert(elapsed < 3,
    "A must finish promptly, not block on B's lifetime (took " .. tostring(elapsed) .. "s)")

  b:kill(signal.SIGKILL)
  b:wait()
end
test_spawn_overlap_no_stdin_leak()
