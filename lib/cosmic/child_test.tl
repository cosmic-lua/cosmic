#!/usr/bin/env cosmic
local child = require("cosmic.child")
local fs = require("cosmic.fs")
local proc = require("cosmic.proc")
local env = require("cosmic.env")
local time = require("cosmic.time")
-- cosmo.unix is required directly only for raw fd ops (unix.close) and to
-- monkey-patch unix.fork for fault injection (test_spawn_fork_failure), which
-- must share the exact module table that child.tl uses.
local unix = require("cosmo.unix")

local lua_bin = fs.join(os.getenv("TEST_BIN"), "cosmic")
local TEST_TMPDIR = os.getenv("TEST_TMPDIR")

-- High-level spawn tests --

local function test_simple_command()
  local handle = child.spawn({lua_bin, "-e", "print('hello')"})
  assert(handle ~= nil, "handle should not be nil")
  local ok, out = handle:read()
  assert(ok, "command should succeed")
  assert(out == "hello\n", "expected 'hello\\n', got '" .. tostring(out) .. "'")
end
test_simple_command()

local function test_command_not_found()
  local handle, err = child.spawn({"nonexistent_command_12345"})
  assert(handle == nil, "handle should be nil for nonexistent command")
  assert(err:find("command not found", 1, true), "expected 'command not found' in error: " .. tostring(err))
end
test_command_not_found()

local function test_wait_returns_exit_code()
  local handle = child.spawn({lua_bin, "-e", "os.exit(0)"})
  assert(handle ~= nil, "handle should not be nil")
  local exit_code = handle:wait()
  assert(exit_code == 0, "expected exit code 0, got " .. tostring(exit_code))

  handle = child.spawn({lua_bin, "-e", "os.exit(1)"})
  assert(handle ~= nil, "handle should not be nil")
  exit_code = handle:wait()
  assert(exit_code == 1, "expected exit code 1, got " .. tostring(exit_code))
end
test_wait_returns_exit_code()

local function test_stdin_string()
  local handle = child.spawn({lua_bin, "-e", "io.write(io.read('*a'))"}, {stdin = "hello from stdin"})
  assert(handle ~= nil, "handle should not be nil")
  local ok, out = handle:read()
  assert(ok, "command should succeed")
  assert(out == "hello from stdin", "expected 'hello from stdin', got '" .. tostring(out) .. "'")
end
test_stdin_string()

local function test_read_captures_output()
  local handle = child.spawn({lua_bin, "-e", [[io.write("line1\nline2\n")]]})
  assert(handle ~= nil, "handle should not be nil")
  local ok, out = handle:read()
  assert(ok, "command should succeed")
  assert(out == "line1\nline2\n", "expected 'line1\\nline2\\n', got '" .. tostring(out) .. "'")
end
test_read_captures_output()

local function test_cwd_option()
  local handle = child.spawn({"pwd"}, {cwd = TEST_TMPDIR})
  assert(handle ~= nil, "handle should not be nil")
  local ok, out, exit_code = handle:read()
  assert(ok, "command should succeed, exit code: " .. tostring(exit_code) .. ", output: '" .. tostring(out) .. "'")
  local pwd_output = out:gsub("\n$", "")
  assert(pwd_output == TEST_TMPDIR, "expected pwd to be '" .. TEST_TMPDIR .. "', got '" .. tostring(pwd_output) .. "'")
end
test_cwd_option()

-- fork and wait tests --

local function test_fork_and_wait()
  local pid = child.fork()
  if pid == 0 then
    proc.exit(42)
  else
    assert(pid > 0, "expected positive child pid in parent, got " .. tostring(pid))
    local waited_pid, status = child.wait(pid)
    assert(waited_pid == pid, "expected to wait for child " .. tostring(pid) .. ", got " .. tostring(waited_pid))
    assert(child.WIFEXITED(status), "expected child to exit normally")
    local exit_code = child.WEXITSTATUS(status)
    assert(exit_code == 42, "expected exit code 42, got " .. tostring(exit_code))
  end
end
test_fork_and_wait()

local function test_fork_child_has_different_pid()
  local parent_pid = proc.getpid()
  local marker_file = fs.join(TEST_TMPDIR, "fork_test_" .. tostring(parent_pid))

  local pid = child.fork()
  if pid == 0 then
    local child_pid = proc.getpid()
    local f = io.open(marker_file, "w")
    if f then
      f:write(tostring(child_pid))
      f:close()
    end
    proc.exit(0)
  else
    child.wait(pid)
    local f = io.open(marker_file, "r")
    assert(f ~= nil, "expected marker file to exist")
    local child_pid_str = f:read("*a")
    f:close()
    os.remove(marker_file)
    local child_pid = tonumber(child_pid_str)
    assert(child_pid ~= parent_pid, "expected child to have different pid")
    assert(child_pid == pid, "expected child pid " .. tostring(pid) .. ", got " .. tostring(child_pid))
  end
end
test_fork_child_has_different_pid()

-- WIFEXITED / WEXITSTATUS tests --

local function test_wifexited_normal_exit()
  local pid = child.fork()
  if pid == 0 then
    proc.exit(0)
  else
    local _, status = child.wait(pid)
    assert(child.WIFEXITED(status), "expected WIFEXITED to be true")
  end
end
test_wifexited_normal_exit()

local function test_wexitstatus_values()
  for _, expected_code in ipairs({0, 1, 42, 127, 255}) do
    local pid = child.fork()
    if pid == 0 then
      proc.exit(expected_code)
    else
      local _, status = child.wait(pid)
      assert(child.WIFEXITED(status), "expected WIFEXITED to be true for code " .. tostring(expected_code))
      local actual_code = child.WEXITSTATUS(status)
      assert(actual_code == expected_code, "expected exit code " .. tostring(expected_code) .. ", got " .. tostring(actual_code))
    end
  end
end
test_wexitstatus_values()

-- WIFSIGNALED / WTERMSIG tests --

local function test_wifsignaled_on_kill()
  local pid = child.fork()
  if pid == 0 then
    while true do end
  else
    local killed = child.kill(pid, child.SIGKILL)
    assert(killed, "expected kill to succeed")
    local _, status = child.wait(pid)
    assert(child.WIFSIGNALED(status), "expected WIFSIGNALED to be true")
    local sig = child.WTERMSIG(status)
    assert(sig == child.SIGKILL, "expected SIGKILL (" .. tostring(child.SIGKILL) .. "), got " .. tostring(sig))
  end
end
test_wifsignaled_on_kill()

-- WNOHANG test --

local function test_wnohang_returns_zero_for_running_process()
  local pid = child.fork()
  if pid == 0 then
    time.sleep(0, 100000000) -- 100ms
    proc.exit(0)
  else
    local waited_pid = child.wait(pid, child.WNOHANG)
    assert(waited_pid == 0 or waited_pid == pid, "expected 0 or pid, got " .. tostring(waited_pid))
    if waited_pid == 0 then
      child.wait(pid)
    end
  end
end
test_wnohang_returns_zero_for_running_process()

-- posix_spawn tests --

local function test_posix_spawn_returns_pid()
  local ls_path = proc.commandv("ls")
  if ls_path then
    local pid = child.posix_spawn(ls_path, {"ls"})
    assert(pid > 0, "expected positive pid, got " .. tostring(pid))
    child.wait(pid)
  end
end
test_posix_spawn_returns_pid()

local function test_posix_spawnp_with_path_search()
  local pid = child.posix_spawnp("ls", {"ls"})
  assert(pid > 0, "expected positive pid, got " .. tostring(pid))
  local waited_pid, status = child.wait(pid)
  assert(waited_pid == pid, "expected to wait for spawned process")
  assert(child.WIFEXITED(status), "expected normal exit")
  assert(child.WEXITSTATUS(status) == 0, "expected exit code 0")
end
test_posix_spawnp_with_path_search()

-- Environment inheritance test --

local function test_spawn_inherits_env()
  -- child.spawn should pass the parent's environment to the child unchanged.
  -- regression: environ() returns {string} ("KEY=VALUE" entries) but spawn()
  -- iterated it as {string:string} producing "1=KEY=VALUE" garbage.
  local sentinel = "cosmic_test_inherit_" .. tostring(proc.getpid())
  env.set("COSMIC_TEST_SENTINEL", sentinel)
  local handle = child.spawn({lua_bin, "-e", [[
    io.write(os.getenv("COSMIC_TEST_SENTINEL") or "")
  ]]})
  assert(handle ~= nil, "handle should not be nil")
  local ok, out, code = handle:read()
  assert(ok, "child should exit 0, got code " .. tostring(code))
  assert(out == sentinel, "expected '" .. sentinel .. "', got '" .. tostring(out) .. "'")
end
test_spawn_inherits_env()

local function test_spawn_with_env_map()
  -- child.spawn should accept {string:string} map from env.all()
  local env = require("cosmic.env")
  local sentinel = "cosmic_test_map_" .. tostring(proc.getpid())
  env.set("COSMIC_TEST_MAP", sentinel)
  local vars = env.all()
  local handle = child.spawn({lua_bin, "-e", [[
    io.write(os.getenv("COSMIC_TEST_MAP") or "")
  ]]}, {env = vars as {string}})
  assert(handle ~= nil, "handle should not be nil")
  local ok, out, code = handle:read()
  assert(ok, "child should exit 0, got code " .. tostring(code))
  assert(out == sentinel, "expected '" .. sentinel .. "', got '" .. tostring(out) .. "'")
end
test_spawn_with_env_map()

local function test_spawn_with_env_list()
  -- child.spawn should still accept {string} list format
  local env_mod = require("cosmic.env")
  local sentinel = "cosmic_test_list_" .. tostring(proc.getpid())
  env.set("COSMIC_TEST_LIST", sentinel)
  local vars = env_mod.list()
  local handle = child.spawn({lua_bin, "-e", [[
    io.write(os.getenv("COSMIC_TEST_LIST") or "")
  ]]}, {env = vars})
  assert(handle ~= nil, "handle should not be nil")
  local ok, out, code = handle:read()
  assert(ok, "child should exit 0, got code " .. tostring(code))
  assert(out == sentinel, "expected '" .. sentinel .. "', got '" .. tostring(out) .. "'")
end
test_spawn_with_env_list()

-- Constants tests --

local function test_signal_constants_defined()
  assert(type(child.SIGTERM) == "number", "SIGTERM should be a number")
  assert(type(child.SIGKILL) == "number", "SIGKILL should be a number")
  assert(type(child.SIGINT) == "number", "SIGINT should be a number")
  assert(type(child.SIGCHLD) == "number", "SIGCHLD should be a number")
  assert(type(child.SIGSTOP) == "number", "SIGSTOP should be a number")
  assert(type(child.SIGCONT) == "number", "SIGCONT should be a number")
end
test_signal_constants_defined()

local function test_wait_option_constants_defined()
  assert(type(child.WNOHANG) == "number", "WNOHANG should be a number")
  assert(type(child.WUNTRACED) == "number", "WUNTRACED should be a number")
  assert(child.WCONTINUED == nil or type(child.WCONTINUED) == "number",
    "WCONTINUED should be a number or nil")
end
test_wait_option_constants_defined()

-- fork-failure fd-cleanup test --

local function test_spawn_fork_failure()
  -- Monkey-patch unix.fork to simulate a fork failure.
  -- child.tl requires "cosmo.unix" and calls unix.fork() via the shared
  -- module table, so replacing it here affects child.spawn() as well.
  -- Use rawget/rawset to bypass Teal's type checker.
  local real_fork = rawget(unix, "fork")
  rawset(unix, "fork", function(): number return nil end)
  local handle, err = child.spawn({lua_bin, "-e", "print('x')"})
  rawset(unix, "fork", real_fork)
  assert(handle == nil, "expected nil handle on fork failure, got: " .. tostring(handle))
  assert(type(err) == "string", "expected error string on fork failure, got: " .. type(err))
  assert(err:find("fork", 1, true), "expected 'fork' in error message: " .. tostring(err))
end
test_spawn_fork_failure()

-- deadlock regression: large stderr output --

local function test_wait_no_deadlock_large_stderr()
  -- Write 128KB to stderr and a small amount to stdout.
  -- Before the fix, wait() would block reading stdout while the child
  -- blocked writing stderr (pipe buffer full) -- deadlock.
  local handle = child.spawn({lua_bin, "-e", [[
    io.write("stdout ok\n")
    io.flush()
    local big = string.rep("x", 131072)
    io.stderr:write(big)
    io.stderr:flush()
    os.exit(0)
  ]]})
  assert(handle ~= nil, "handle should not be nil")
  local exit_code = handle:wait()
  assert(exit_code == 0, "expected exit code 0, got " .. tostring(exit_code))
end
test_wait_no_deadlock_large_stderr()

local function test_read_no_deadlock_large_stderr()
  -- Same scenario but using handle:read() instead of handle:wait().
  local handle = child.spawn({lua_bin, "-e", [[
    io.write("stdout ok\n")
    io.flush()
    local big = string.rep("y", 131072)
    io.stderr:write(big)
    io.stderr:flush()
    os.exit(0)
  ]]})
  assert(handle ~= nil, "handle should not be nil")
  local ok, out, code = handle:read()
  assert(ok, "expected success, got code " .. tostring(code))
  assert(out == "stdout ok\n", "expected 'stdout ok\\n', got '" .. tostring(out) .. "'")
end
test_read_no_deadlock_large_stderr()

-- /zip/ binary execution via fexecve --

local function test_prepare_zip_exec()
  local prepare_zip_exec = child.prepare_zip_exec
  assert(prepare_zip_exec, "prepare_zip_exec should be exported")

  -- open a known /zip/ path (main.lua exists in every cosmic binary)
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
  -- /zip/main.lua exists but is not an ELF binary, so fexecve fails
  local handle, err = child.spawn({"/zip/main.lua"})
  assert(handle ~= nil, "spawn should succeed (fork works): " .. tostring(err))
  local exit_code = handle:wait()
  assert(exit_code == 127,
    "expected exit 127 for non-executable, got " .. tostring(exit_code))
end
test_spawn_zip_non_executable()

local function test_spawn_zip_embedded_binary()
  -- embed /bin/echo into a copy of cosmic, then spawn it from /zip/
  local fs = require("cosmic.fs")
  local io_mod = require("cosmic.io")
  local tmpdir = os.getenv("TEST_TMPDIR") as string

  -- set up embed directory with .bin/echo
  local bin_dir = fs.join(tmpdir, "embed", ".bin")
  fs.makedirs(bin_dir)
  local echo_data = io_mod.slurp("/bin/echo")
  assert(echo_data, "should read /bin/echo")
  io_mod.barf(fs.join(bin_dir, "echo"), echo_data)
  fs.chmod(fs.join(bin_dir, "echo"), 493) -- 0755

  -- create embedded cosmic binary
  local out_bin = fs.join(tmpdir, "cosmic-with-echo")
  local build = child.spawn(
    {lua_bin, "--embed", fs.join(tmpdir, "embed"), "--output", out_bin})
  assert(build, "embed spawn should succeed")
  assert(build:wait() == 0, "embed should exit 0")

  -- run the embedded binary: spawn /zip/.bin/echo via fexecve
  local handle = child.spawn({out_bin, "-e", [[
    local child = require("cosmic.child")
    local h = child.spawn({"/zip/.bin/echo", "hello-from-zip"})
    assert(h, "spawn /zip/.bin/echo failed")
    local ok, out = h:read()
    io.write(out)
  ]]})
  assert(handle, "should spawn embedded binary")
  local ok, out = handle:read()
  assert(ok, "embedded binary should succeed")
  assert(out == "hello-from-zip\n",
    "expected 'hello-from-zip\\n', got '" .. tostring(out) .. "'")
end
test_spawn_zip_embedded_binary()

-- FIX 4: fd redirection correctness using dup2-style unix.dup(src, dst).
-- Verify that stdout and stderr are independently redirected so that output
-- written to each stream appears on the correct pipe.
local function test_spawn_stdout_stderr_separate()
  -- Child writes distinct text to stdout and stderr.
  local handle = child.spawn({lua_bin, "-e", [[
    io.stdout:write("to-stdout\n")
    io.stdout:flush()
    io.stderr:write("to-stderr\n")
    io.stderr:flush()
  ]]})
  assert(handle ~= nil, "handle should not be nil")
  local ok, out, code = handle:read()
  assert(ok, "command should succeed, exit=" .. tostring(code))
  assert(out == "to-stdout\n",
    "expected 'to-stdout\\n' on stdout, got '" .. tostring(out) .. "'")
end
test_spawn_stdout_stderr_separate()

-- FIX 4: when stdin pipe fd happens to already be fd 0 in child, we must not
-- double-close it.  A pathological but valid scenario where spawning many
-- children leaves fd slots at low numbers.  The existing simple redirection
-- test covers the common case; this test exercises correct behavior when a
-- pipe end lands on the target fd.
local function test_spawn_many_captures_correct()
  -- Spawn several children in quick succession to exercise fd reuse.
  for i = 1, 5 do
    local handle = child.spawn({lua_bin, "-e",
        "io.write('iter" .. tostring(i) .. "\\n')"})
    assert(handle ~= nil, "handle should not be nil on iteration " .. i)
    local ok, out = handle:read()
    assert(ok, "iteration " .. i .. " should succeed")
    assert(out == "iter" .. tostring(i) .. "\n",
      "expected 'iter" .. i .. "\\n', got '" .. tostring(out) .. "'")
  end
end
test_spawn_many_captures_correct()

-- FIX (#526 item 5): spawn must not mutate the caller's argv, and its pipes
-- must be CLOEXEC so overlapping children don't inherit each other's ends.

local function test_spawn_does_not_mutate_argv()
  -- A PATH search wrote the resolved path back into argv[1], corrupting the
  -- caller's own table. The resolution must go into a local instead.
  local argv = {"echo", "x"}
  local handle = child.spawn(argv)
  assert(handle ~= nil, "spawn should succeed")
  handle:wait()
  assert(argv[1] == "echo",
    "spawn must not mutate caller's argv[1], got '" .. tostring(argv[1]) .. "'")
end
test_spawn_does_not_mutate_argv()

local function test_spawn_overlap_no_stdin_leak()
  -- Non-CLOEXEC pipes let a later child inherit an earlier child's stdin
  -- write end, so the earlier child never saw EOF until the later one exited
  -- and communicate() hung on overlap. Spawn A (reads stdin to EOF), then a
  -- long-lived B; with CLOEXEC pipes A gets EOF immediately once the parent
  -- closes its write end, so it finishes without waiting on B.
  local a = child.spawn({lua_bin, "-e", "io.write(io.read('*a') or '')"},
    {stdin = "hello"})
  assert(a ~= nil, "spawn A should succeed")
  local b = child.spawn({lua_bin, "-e", "require('cosmic.time').sleep(10)"})
  assert(b ~= nil, "spawn B should succeed")

  local s0, n0 = time.monotonic()
  local out, _, code = a:communicate()
  local s1, n1 = time.monotonic()
  local elapsed = (s1 - s0) + (n1 - n0) / 1e9

  assert(code == 0, "A should exit 0, got " .. tostring(code))
  assert(out == "hello", "A should echo its stdin, got '" .. tostring(out) .. "'")
  assert(elapsed < 3,
    "A must finish promptly, not block on B's lifetime (took "
    .. tostring(elapsed) .. "s)")

  child.kill(b.pid, child.SIGKILL)
  b:wait()
end
test_spawn_overlap_no_stdin_leak()
