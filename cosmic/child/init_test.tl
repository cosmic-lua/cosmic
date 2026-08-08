#!/usr/bin/env cosmic
local check = require("cosmic.check")
local child = require("cosmic.child")
local cfd = require("cosmic.fd")
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

-- === Issue TDD cases (a)-(e) ===

-- (a) kill a long-running child; wait() reports the terminating signal.
local function test_kill_reports_signal()
  local h = check.must(child.start({"sleep", "10"}))
  assert(h:stop(), "stop (default SIGTERM) should succeed")
  local r = check.must(h:wait())
  assert(r.signal == signal.SIGTERM,
    "expected SIGTERM, got signal=" .. tostring(r.signal) .. " code=" .. tostring(r.code))
  assert(r.signal == 15, "SIGTERM should be 15, got " .. tostring(r.signal))
  assert(r.code == nil, "a signaled child has no exit code")
  assert(r.ok == false, "a signaled child is not ok")
end
test_kill_reports_signal()

-- (b) wait() is idempotent: the reaped Result is cached and returned again.
local function test_wait_idempotent()
  local h = check.must(child.start({lua_bin, "-e", "os.exit(3)"}))
  local r1 = check.must(h:wait())
  local r2 = check.must(h:wait())
  assert(r1 == r2, "second wait() must return the same cached Result")
  assert(r1.code == 3, "expected code 3, got " .. tostring(r1.code))
end
test_wait_idempotent()

-- (c) wait(timeout_ms) returns nil, "timeout" for a child that has not exited;
-- the handle stays usable so we can then kill and reap it.
local function test_wait_timeout()
  local h = check.must(child.start({"sleep", "10"}))
  local r, err = h:wait(100)
  assert(r == nil, "expected nil Result on timeout")
  assert(err == "timeout", "expected 'timeout', got " .. tostring(err))
  assert(h:stop(signal.SIGKILL))
  local r2 = check.must(h:wait())
  assert(r2.signal == signal.SIGKILL, "expected SIGKILL after timeout+kill")
end
test_wait_timeout()

-- (d) a missing executable makes spawn() itself fail with a visible ENOENT,
-- not a bogus exit code from a later wait().
local function test_exec_failure_visible()
  local h, err = child.start({"/no/such/bin"})
  assert(h == nil, "spawn should fail for a missing executable")
  assert(err ~= nil and err:match("ENOENT"),
    "expected ENOENT in error, got " .. tostring(err))
end
test_exec_failure_visible()

-- (e) run() captures stdout and stderr independently along with the exit code.
local function test_run_captures_streams_and_code()
  local r = check.must(child.run({"sh", "-c", "echo o; echo e >&2; exit 3"}))
  assert(r.stdout == "o\n", "expected stdout 'o\\n', got '" .. tostring(r.stdout) .. "'")
  assert(r.stderr == "e\n", "expected stderr 'e\\n', got '" .. tostring(r.stderr) .. "'")
  assert(r.code == 3, "expected code 3, got " .. tostring(r.code))
  assert(r.ok == false, "exit 3 is not ok")
end
test_run_captures_streams_and_code()

-- === High-level run/spawn behavior ===

local function test_run_simple()
  local r = check.must(child.run({lua_bin, "-e", "print('hello')"}))
  assert(r.ok, "command should succeed")
  assert(r.stdout == "hello\n", "expected 'hello\\n', got '" .. tostring(r.stdout) .. "'")
end
test_run_simple()

local function test_command_not_found()
  local h, err = child.start({"nonexistent_command_12345"})
  assert(h == nil, "handle should be nil for nonexistent command")
  assert(err:find("command not found", 1, true), "expected 'command not found' in error: " .. tostring(err))
end
test_command_not_found()

local function test_run_exit_code()
  local r = check.must(child.run({lua_bin, "-e", "os.exit(0)"}))
  assert(r.code == 0, "expected exit code 0, got " .. tostring(r.code))
  assert(r.ok, "exit 0 should be ok")

  r = check.must(child.run({lua_bin, "-e", "os.exit(1)"}))
  assert(r.code == 1, "expected exit code 1, got " .. tostring(r.code))
  assert(not r.ok, "exit 1 should not be ok")
end
test_run_exit_code()

local function test_run_stdin_string()
  local r = check.must(child.run({lua_bin, "-e", "io.write(io.read('*a'))"}, {stdin = "hello from stdin"}))
  assert(r.ok, "command should succeed")
  assert(r.stdout == "hello from stdin", "expected 'hello from stdin', got '" .. tostring(r.stdout) .. "'")
end
test_run_stdin_string()

local function test_run_cwd_option()
  local r = check.must(child.run({"pwd"}, {cwd = TEST_TMPDIR}))
  assert(r.ok, "pwd should succeed, code: " .. tostring(r.code) .. " stderr: " .. tostring(r.stderr))
  local pwd_output = r.stdout:gsub("\n$", "")
  assert(pwd_output == TEST_TMPDIR, "expected pwd '" .. TEST_TMPDIR .. "', got '" .. tostring(pwd_output) .. "'")
end
test_run_cwd_option()

-- === Handle-level methods: try_wait, read, stop-after-reap ===

local function test_try_wait()
  local h = check.must(child.start({"sleep", "10"}))
  local tw = check.must(h:try_wait())
  assert(tw.finished == false, "a running child reports finished=false")
  assert(tw.result == nil, "result is set exactly when finished")
  assert(h:stop(signal.SIGKILL))
  local res: child.Result = nil
  for _ = 1, 200 do
    local t = check.must(h:try_wait())
    if t.finished then
      res = t.result
      break
    end
    assert(time.sleep_ms(10)) -- 10ms
  end
  assert(res ~= nil, "try_wait should eventually reap the stopped child")
  assert(res.signal == signal.SIGKILL, "expected SIGKILL, got signal=" .. tostring(res.signal))
end
test_try_wait()

local function test_read_streaming()
  local h = check.must(child.start({lua_bin, "-e", "io.write('abcdef'); io.flush()"}))
  local chunk = check.must(h:read(3))
  assert(#chunk >= 1, "streaming read should return bytes, got " .. tostring(chunk))
  local r = check.must(h:wait())
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
    local h = check.must(child.start({"sleep", "30"}))
    pid = h.pid
  end
  collectgarbage("collect")
  collectgarbage("collect")
  assert(time.sleep_ms(100)) -- 100ms for the kernel to finish teardown
  assert(not signal.kill(pid, 0), "abandoned child should be killed and reaped, not left alive/zombie")
end
test_abandoned_handle_reaped()

local function test_stop_after_reap_fails()
  local h = check.must(child.start({lua_bin, "-e", "os.exit(0)"}))
  assert(h:wait())
  local ok, err = h:stop()
  assert(not ok, "stop after reap should fail")
  assert(err ~= nil, "stop after reap should report an error")
  -- DEPRECATED alias (D20 transition, #976): kill must stay the same
  -- function until the pinned build engine moves off it.
  local h2 = check.must(child.start({"sleep", "10"}))
  assert(h2:kill(signal.SIGKILL), "the kill alias still stops a child")
  assert(h2:wait())
end
test_stop_after_reap_fails()

-- === Environment ===

local function test_spawn_inherits_env()
  local sentinel = "cosmic_test_inherit_" .. tostring(proc.getpid())
  assert(env.set("COSMIC_TEST_SENTINEL", sentinel))
  local r = check.must(child.run({lua_bin, "-e", [[
    io.write(os.getenv("COSMIC_TEST_SENTINEL") or "")
  ]]}))
  assert(r.ok, "child should exit 0, got code " .. tostring(r.code))
  assert(r.stdout == sentinel, "expected '" .. sentinel .. "', got '" .. tostring(r.stdout) .. "'")
end
test_spawn_inherits_env()

local function test_spawn_with_env_edits()
  -- env.list({set = ...}) builds the edited copy; the parent's own
  -- environment is never touched (the old dual-shape map env is gone).
  local sentinel = "cosmic_test_set_" .. tostring(proc.getpid())
  local vars = env.list({set = {COSMIC_TEST_SET = sentinel}})
  local r = check.must(child.run({lua_bin, "-e", [[
    io.write(os.getenv("COSMIC_TEST_SET") or "")
  ]]}, {env = vars}))
  assert(r.ok, "child should exit 0, got code " .. tostring(r.code))
  assert(r.stdout == sentinel, "expected '" .. sentinel .. "', got '" .. tostring(r.stdout) .. "'")
  assert(env.get("COSMIC_TEST_SET") == nil, "set edits the copy, not the parent")
end
test_spawn_with_env_edits()

local function test_spawn_with_env_list()
  local sentinel = "cosmic_test_list_" .. tostring(proc.getpid())
  assert(env.set("COSMIC_TEST_LIST", sentinel))
  local vars = env.list()
  local r = check.must(child.run({lua_bin, "-e", [[
    io.write(os.getenv("COSMIC_TEST_LIST") or "")
  ]]}, {env = vars}))
  assert(r.ok, "child should exit 0, got code " .. tostring(r.code))
  assert(r.stdout == sentinel, "expected '" .. sentinel .. "', got '" .. tostring(r.stdout) .. "'")
end
test_spawn_with_env_list()

-- === fork-failure fd-cleanup ===

local function test_spawn_fork_failure()
  -- Monkey-patch unix.fork to simulate a fork failure; child.tl calls
  -- unix.fork() via the shared module table, so this affects child.spawn.
  -- cwd forces the fork path (the posix_spawn fast path cannot chdir).
  -- The fake failure carries a real errno string so the test also proves
  -- spawn() propagates it instead of a bare "fork failed".
  local real_fork = rawget(unix, "fork")
  rawset(unix, "fork", function(): number, string
      return nil, "fork: EAGAIN: Resource temporarily unavailable"
    end)
  local handle, err = child.start({lua_bin, "-e", "print('x')"}, {cwd = "."})
  rawset(unix, "fork", real_fork)
  assert(handle == nil, "expected nil handle on fork failure, got: " .. tostring(handle))
  assert(type(err) == "string", "expected error string on fork failure, got: " .. type(err))
  assert(err:find("EAGAIN", 1, true),
    "expected the real errno to surface, got: " .. tostring(err))
end
test_spawn_fork_failure()

local function test_spawn_fast_failure()
  -- Same cleanup contract for the posix_spawn fast path: a spawn failure
  -- must surface from spawn() itself, with the handle nil.
  local real_spawn = rawget(unix, "spawn")
  rawset(unix, "spawn", function(): number, string, number
      return nil, "spawn: EAGAIN: Resource temporarily unavailable", 11
    end)
  local handle, err = child.start({lua_bin, "-e", "print('x')"})
  rawset(unix, "spawn", real_spawn)
  assert(handle == nil, "expected nil handle on spawn failure, got: " .. tostring(handle))
  assert(err ~= nil and err:find("exec failed", 1, true),
    "expected 'exec failed' in error message: " .. tostring(err))
end
test_spawn_fast_failure()

-- === deadlock regression: large stderr output ===

local function test_run_no_deadlock_large_stderr()
  local r = check.must(child.run({lua_bin, "-e", [[
    io.write("stdout ok\n")
    io.flush()
    local big = string.rep("x", 131072)
    io.stderr:write(big)
    io.stderr:flush()
    os.exit(0)
  ]]}))
  assert(r.code == 0, "expected exit code 0, got " .. tostring(r.code))
  assert(r.stdout == "stdout ok\n", "expected 'stdout ok\\n', got '" .. tostring(r.stdout) .. "'")
  assert(#r.stderr == 131072, "expected 128KB stderr, got " .. #r.stderr)
end
test_run_no_deadlock_large_stderr()

-- === /zip/ binary execution via fexecve ===

local function test_spawn_zip_nonexistent_path()
  local handle, err = child.start({"/zip/nonexistent_binary_12345"})
  assert(handle == nil, "handle should be nil for nonexistent /zip/ path")
  assert(err, "should have error message")
  assert(err:find("zip", 1, true) or err:find("not found", 1, true),
    "expected zip-related error, got: " .. tostring(err))
end
test_spawn_zip_nonexistent_path()

local function test_spawn_zip_non_executable()
  -- /zip/main.lua exists but is not an ELF binary, so fexecve fails. With the
  -- exec-status pipe, that failure surfaces from spawn itself, not a fake 127.
  local handle, err = child.start({"/zip/main.lua"})
  assert(handle == nil, "spawn should fail: fexecve of a non-binary is an exec error")
  assert(err ~= nil and err:find("exec failed", 1, true),
    "expected an 'exec failed' error, got: " .. tostring(err))
end
test_spawn_zip_non_executable()

local function test_spawn_zip_embedded_binary()
  -- embed /bin/echo into a copy of cosmic, then spawn it from /zip/
  local tmpdir = check.must(os.getenv("TEST_TMPDIR"))

  local bin_dir = fs.join(tmpdir, "embed", ".bin")
  assert(fs.make_dirs(bin_dir))
  local echo_data = fs.read("/bin/echo")
  assert(echo_data, "should read /bin/echo")
  assert(fs.write(fs.join(bin_dir, "echo"), echo_data))
  assert(fs.set_mode(fs.join(bin_dir, "echo"), 493)) -- 0755

  local out_bin = fs.join(tmpdir, "cosmic-with-echo")
  local build = check.must(child.run(
      {lua_bin, "--embed", fs.join(tmpdir, "embed"), "--output", out_bin}))
  assert(build.ok, "embed should exit 0, got " .. tostring(build.code) .. ": " .. build.stderr)

  -- run the embedded binary: spawn /zip/.bin/echo via fexecve
  local r = check.must(child.run({out_bin, "-e", [[
    local child = require("cosmic.child")
    local r = child.run({"/zip/.bin/echo", "hello-from-zip"})
    assert(r, "spawn /zip/.bin/echo failed")
    io.write(r.stdout)
  ]]}))
  -- Spawning a /zip member needs memfd_create (cosmo's fd_to_mem_fd),
  -- which pledge's base filter forces to ENOSYS with no fallback — so
  -- the sandboxed test lane cannot exercise it; skip on that
  -- specific failure. The enforce lane runs it for real.
  if not r.ok and tostring(r.stderr):find("spawn /zip/.bin/echo failed") then
    check.enforce_skip("zip spawn needs memfd_create; pledge forces ENOSYS")
    return
  end
  assert(r.ok, "embedded binary should succeed: " .. tostring(r.stderr))
  assert(r.stdout == "hello-from-zip\n",
    "expected 'hello-from-zip\\n', got '" .. tostring(r.stdout) .. "'")
end
test_spawn_zip_embedded_binary()

-- === fd redirection correctness ===

local function test_spawn_stdout_stderr_separate()
  local r = check.must(child.run({lua_bin, "-e", [[
    io.stdout:write("to-stdout\n")
    io.stdout:flush()
    io.stderr:write("to-stderr\n")
    io.stderr:flush()
  ]]}))
  assert(r.ok, "command should succeed, exit=" .. tostring(r.code))
  assert(r.stdout == "to-stdout\n",
    "expected 'to-stdout\\n' on stdout, got '" .. tostring(r.stdout) .. "'")
  assert(r.stderr == "to-stderr\n",
    "expected 'to-stderr\\n' on stderr, got '" .. tostring(r.stderr) .. "'")
end
test_spawn_stdout_stderr_separate()

local function test_spawn_many_captures_correct()
  for i = 1, 5 do
    local r = check.must(child.run({lua_bin, "-e",
          "io.write('iter" .. tostring(i) .. "\\n')"}))
    assert(r.ok, "iteration " .. i .. " should succeed")
    assert(r.stdout == "iter" .. tostring(i) .. "\n",
      "expected 'iter" .. i .. "\\n', got '" .. tostring(r.stdout) .. "'")
  end
end
test_spawn_many_captures_correct()

-- === spawn hygiene ===

local function test_spawn_does_not_mutate_argv()
  local argv = {"echo", "x"}
  local h = check.must(child.start(argv))
  assert(h:wait())
  assert(argv[1] == "echo",
    "spawn must not mutate caller's argv[1], got '" .. tostring(argv[1]) .. "'")
end
test_spawn_does_not_mutate_argv()

local function test_spawn_overlap_no_stdin_leak()
  -- CLOEXEC pipes stop a later child from inheriting an earlier child's stdin
  -- write end. Spawn A (reads stdin to EOF), then a long-lived B; A must see
  -- EOF once the parent closes its write end and finish without waiting on B.
  local a = check.must(child.start({lua_bin, "-e", "io.write(io.read('*a') or '')"},
      {stdin = "hello"}))
  local b = check.must(child.start({lua_bin, "-e", "require('cosmic.time').sleep(10)"}))

  local s0, n0 = time.monotonic()
  local r = check.must(a:wait())
  local s1, n1 = time.monotonic()
  local elapsed = (s1 - s0) + (n1 - n0) / 1e9

  assert(r.code == 0, "A should exit 0, got " .. tostring(r.code))
  assert(r.stdout == "hello", "A should echo its stdin, got '" .. tostring(r.stdout) .. "'")
  assert(elapsed < 3,
    "A must finish promptly, not block on B's lifetime (took " .. tostring(elapsed) .. "s)")

  assert(b:stop(signal.SIGKILL))
  assert(b:wait())
end
test_spawn_overlap_no_stdin_leak()

-- === honest option types: fd.Handle in Options ===

-- stdout as a Handle: the child writes into a pipe we own; run()'s own
-- capture is then empty for that stream.
local function test_spawn_stdout_handle()
  local p = check.must(cfd.pipe())
  local h = check.must(child.start({"echo", "via-handle"}, {stdout = p.writer}))
  assert(p.writer:close())
  local out = check.must(p.reader:read())
  assert(p.reader:close())
  local r = check.must(h:wait())
  assert(out == "via-handle\n", "expected 'via-handle\\n' through the pipe, got '" .. tostring(out) .. "'")
  assert(r.stdout == "", "redirected stdout should leave Result.stdout empty")
end
test_spawn_stdout_handle()

-- stderr as a Handle.
local function test_spawn_stderr_handle()
  local p = check.must(cfd.pipe())
  local h = check.must(child.start({"sh", "-c", "echo err-via-handle >&2"}, {stderr = p.writer}))
  assert(p.writer:close())
  local out = check.must(p.reader:read())
  assert(p.reader:close())
  local r = check.must(h:wait())
  assert(out == "err-via-handle\n", "expected stderr through the pipe, got '" .. tostring(out) .. "'")
  assert(r.stderr == "", "redirected stderr should leave Result.stderr empty")
end
test_spawn_stderr_handle()

-- stdin as a Handle (the read end of a pipe we filled), alongside the
-- string form which stays supported.
local function test_spawn_stdin_handle()
  local p = check.must(cfd.pipe())
  assert(p.writer:write("handle stdin data"))
  assert(p.writer:close())
  local r = check.must(child.run({lua_bin, "-e", "io.write(io.read('*a'))"}, {stdin = p.reader}))
  assert(p.reader:close())
  assert(r.ok, "run with Handle stdin should succeed")
  assert(r.stdout == "handle stdin data",
    "expected 'handle stdin data', got '" .. tostring(r.stdout) .. "'")
end
test_spawn_stdin_handle()

-- A file Handle from fd.open works the same way as a pipe end.
local function test_spawn_stdout_file_handle()
  local path = fs.join(TEST_TMPDIR, "stdout-handle.txt")
  local h = check.must(cfd.open(path, cfd.O_WRONLY | cfd.O_CREAT | cfd.O_TRUNC, 420)) -- 0644
  local r = check.must(child.run({"echo", "to-file"}, {stdout = h}))
  assert(h:close())
  assert(r.ok, "run with file Handle stdout should succeed")
  assert(fs.read(path) == "to-file\n", "child output should land in the file")
end
test_spawn_stdout_file_handle()

-- A closed Handle is a caller bug surfaced from spawn itself, not a
-- confusing EBADF from the plumbing.
local function test_spawn_closed_handle_fails()
  local p = check.must(cfd.pipe())
  assert(p:close())
  local h, err = child.start({"echo", "x"}, {stdout = p.writer})
  assert(h == nil, "spawn with a closed Handle should fail")
  assert(err ~= nil and err:find("closed", 1, true),
    "expected a 'closed' error, got: " .. tostring(err))
end
test_spawn_closed_handle_fails()

-- Type-level contract: Options mentions no bare integer fds. A raw int
-- for stdout must be rejected by the type checker.
local function test_options_reject_raw_int_fd()
  local script = fs.join(TEST_TMPDIR, "raw_fd_options.tl")
  assert(fs.write(script, [[
local child = require("cosmic.child")
child.run({"echo", "x"}, {stdout = 5})
]]))
  local r = check.must(child.run({lua_bin, "--check", "types", script}))
  assert(not r.ok, "a raw integer fd in Options must fail the type check")
  local diag = r.stdout .. r.stderr
  assert(diag:find("stdout", 1, true),
    "diagnostic should name the offending field, got: " .. diag)
end
test_options_reject_raw_int_fd()
