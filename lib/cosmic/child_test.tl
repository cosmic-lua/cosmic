#!/usr/bin/env cosmic
local cosmo = require("cosmo")
local path = require("cosmo.path")
local child = require("cosmic.child")
local unix = require("cosmo.unix")

local lua_bin = path.join(os.getenv("TEST_BIN"), "cosmic")
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
    unix.exit(42)
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
  local parent_pid = unix.getpid()
  local marker_file = path.join(TEST_TMPDIR, "fork_test_" .. tostring(parent_pid))

  local pid = child.fork()
  if pid == 0 then
    local child_pid = unix.getpid()
    local f = io.open(marker_file, "w")
    if f then
      f:write(tostring(child_pid))
      f:close()
    end
    unix.exit(0)
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
    unix.exit(0)
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
      unix.exit(expected_code)
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
    unix.nanosleep(0, 100000000) -- 100ms
    unix.exit(0)
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
  local ls_path = unix.commandv("ls")
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
  local sentinel = "cosmic_test_inherit_" .. tostring(unix.getpid())
  unix.setenv("COSMIC_TEST_SENTINEL", sentinel)
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
  local sentinel = "cosmic_test_map_" .. tostring(unix.getpid())
  unix.setenv("COSMIC_TEST_MAP", sentinel)
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
  local sentinel = "cosmic_test_list_" .. tostring(unix.getpid())
  unix.setenv("COSMIC_TEST_LIST", sentinel)
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
