#!/usr/bin/env cosmic
local cosmo = require("cosmo")
local path = require("cosmo.path")
local process = require("cosmic.process")

local lua_bin = path.join(os.getenv("TEST_BIN"), "cosmic")
local TEST_TMPDIR = os.getenv("TEST_TMPDIR")

-- getpid tests

local function test_getpid_returns_number()
  local pid = process.getpid()
  assert(type(pid) == "number", "expected number, got " .. type(pid))
  assert(pid > 0, "expected positive pid, got " .. tostring(pid))
end
test_getpid_returns_number()

local function test_getpid_is_consistent()
  local pid1 = process.getpid()
  local pid2 = process.getpid()
  assert(pid1 == pid2, "expected consistent pid, got " .. tostring(pid1) .. " and " .. tostring(pid2))
end
test_getpid_is_consistent()

-- getppid tests

local function test_getppid_returns_number()
  local ppid = process.getppid()
  assert(type(ppid) == "number", "expected number, got " .. type(ppid))
  assert(ppid > 0, "expected positive ppid, got " .. tostring(ppid))
end
test_getppid_returns_number()

local function test_getppid_different_from_pid()
  local pid = process.getpid()
  local ppid = process.getppid()
  assert(pid ~= ppid, "expected pid and ppid to be different")
end
test_getppid_different_from_pid()

-- commandv tests

local function test_commandv_finds_ls()
  local path_to_ls = process.commandv("ls")
  assert(path_to_ls ~= nil, "expected to find 'ls' command")
  assert(path_to_ls:find("/", 1, true), "expected absolute path, got " .. tostring(path_to_ls))
end
test_commandv_finds_ls()

local function test_commandv_returns_nil_for_nonexistent()
  local result = process.commandv("nonexistent_command_xyz_12345")
  assert(result == nil, "expected nil for nonexistent command, got " .. tostring(result))
end
test_commandv_returns_nil_for_nonexistent()

-- fork and wait tests

local function test_fork_and_wait()
  local pid = process.fork()
  if pid == 0 then
    -- Child process: exit immediately with code 42
    process.exit(42)
  else
    -- Parent process: wait for child
    assert(pid > 0, "expected positive child pid in parent, got " .. tostring(pid))
    local waited_pid, status = process.wait(pid)
    assert(waited_pid == pid, "expected to wait for child " .. tostring(pid) .. ", got " .. tostring(waited_pid))
    assert(process.WIFEXITED(status), "expected child to exit normally")
    local exit_code = process.WEXITSTATUS(status)
    assert(exit_code == 42, "expected exit code 42, got " .. tostring(exit_code))
  end
end
test_fork_and_wait()

local function test_fork_child_has_different_pid()
  local parent_pid = process.getpid()
  local marker_file = path.join(TEST_TMPDIR, "fork_test_" .. tostring(parent_pid))

  local pid = process.fork()
  if pid == 0 then
    -- Child: write its pid to a file
    local child_pid = process.getpid()
    local f = io.open(marker_file, "w")
    if f then
      f:write(tostring(child_pid))
      f:close()
    end
    process.exit(0)
  else
    -- Parent: wait for child, then read the file
    process.wait(pid)
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

-- WIFEXITED / WEXITSTATUS tests

local function test_wifexited_normal_exit()
  local pid = process.fork()
  if pid == 0 then
    process.exit(0)
  else
    local _, status = process.wait(pid)
    assert(process.WIFEXITED(status), "expected WIFEXITED to be true")
  end
end
test_wifexited_normal_exit()

local function test_wexitstatus_values()
  for _, expected_code in ipairs({0, 1, 42, 127, 255}) do
    local pid = process.fork()
    if pid == 0 then
      process.exit(expected_code)
    else
      local _, status = process.wait(pid)
      assert(process.WIFEXITED(status), "expected WIFEXITED to be true for code " .. tostring(expected_code))
      local actual_code = process.WEXITSTATUS(status)
      assert(actual_code == expected_code, "expected exit code " .. tostring(expected_code) .. ", got " .. tostring(actual_code))
    end
  end
end
test_wexitstatus_values()

-- WIFSIGNALED / WTERMSIG tests

local function test_wifsignaled_on_kill()
  local pid = process.fork()
  if pid == 0 then
    -- Child: sleep forever (will be killed by parent)
    while true do
      -- Busy wait - will be terminated by SIGKILL
    end
  else
    -- Parent: kill the child with SIGKILL
    local killed = process.kill(pid, process.SIGKILL)
    assert(killed, "expected kill to succeed")
    local _, status = process.wait(pid)
    assert(process.WIFSIGNALED(status), "expected WIFSIGNALED to be true")
    local sig = process.WTERMSIG(status)
    assert(sig == process.SIGKILL, "expected SIGKILL (" .. tostring(process.SIGKILL) .. "), got " .. tostring(sig))
  end
end
test_wifsignaled_on_kill()

-- WNOHANG test

local function test_wnohang_returns_zero_for_running_process()
  local pid = process.fork()
  if pid == 0 then
    -- Child: sleep briefly then exit
    local unix = require("cosmo.unix")
    unix.nanosleep(0, 100000000) -- 100ms
    process.exit(0)
  else
    -- Parent: check immediately with WNOHANG
    local waited_pid = process.wait(pid, process.WNOHANG)
    -- WNOHANG returns 0 if child hasn't exited yet
    assert(waited_pid == 0 or waited_pid == pid, "expected 0 or pid, got " .. tostring(waited_pid))
    -- Now wait properly for cleanup
    if waited_pid == 0 then
      process.wait(pid)
    end
  end
end
test_wnohang_returns_zero_for_running_process()

-- spawn tests

local function test_spawn_returns_pid()
  local ls_path = process.commandv("ls")
  if ls_path then
    local pid = process.spawn(ls_path, {"ls"})
    assert(pid > 0, "expected positive pid, got " .. tostring(pid))
    process.wait(pid)
  end
end
test_spawn_returns_pid()

local function test_spawnp_with_path_search()
  local pid = process.spawnp("ls", {"ls"})
  assert(pid > 0, "expected positive pid, got " .. tostring(pid))
  local waited_pid, status = process.wait(pid)
  assert(waited_pid == pid, "expected to wait for spawned process")
  assert(process.WIFEXITED(status), "expected normal exit")
  assert(process.WEXITSTATUS(status) == 0, "expected exit code 0")
end
test_spawnp_with_path_search()

-- getpgrp / getpgid tests

local function test_getpgrp_returns_number()
  local pgrp = process.getpgrp()
  assert(type(pgrp) == "number", "expected number, got " .. type(pgrp))
  assert(pgrp > 0, "expected positive pgrp, got " .. tostring(pgrp))
end
test_getpgrp_returns_number()

local function test_getpgid_for_self()
  local pgid = process.getpgid(process.getpid())
  local pgrp = process.getpgrp()
  -- getpgid(getpid()) should equal getpgrp()
  assert(pgid == pgrp, "expected getpgid(getpid()) == getpgrp(), got " .. tostring(pgid) .. " vs " .. tostring(pgrp))
end
test_getpgid_for_self()

-- getsid test

local function test_getsid_returns_number()
  local sid = process.getsid(process.getpid())
  assert(type(sid) == "number", "expected number, got " .. type(sid))
  assert(sid > 0, "expected positive sid, got " .. tostring(sid))
end
test_getsid_returns_number()

-- getrusage tests

local function test_getrusage_returns_rusage()
  local rusage = process.getrusage(process.RUSAGE_SELF)
  assert(rusage ~= nil, "expected rusage object")
  -- Check that we can call methods on it
  local utime_sec, utime_nsec = rusage:utime()
  assert(type(utime_sec) == "number", "expected utime seconds to be number")
  assert(type(utime_nsec) == "number", "expected utime nanos to be number")
end
test_getrusage_returns_rusage()

local function test_getrusage_maxrss()
  local rusage = process.getrusage(process.RUSAGE_SELF)
  local maxrss = rusage:maxrss()
  assert(type(maxrss) == "number", "expected maxrss to be number")
  assert(maxrss >= 0, "expected non-negative maxrss")
end
test_getrusage_maxrss()

-- is_main tests

local function test_is_main_returns_boolean()
  -- When loaded by test harness, is_main returns false (we're being required)
  local result = process.is_main()
  assert(type(result) == "boolean", "expected boolean, got " .. type(result))
end
test_is_main_returns_boolean()

local function test_is_main_true_when_run_directly()
  -- Create a test script that checks cosmo.is_main when run directly
  local script_path = path.join(TEST_TMPDIR, "is_main_direct.lua")
  cosmo.Barf(script_path, [[
local cosmo = require("cosmo")
if cosmo.is_main() then
  os.exit(0)  -- success: is_main returned true
else
  os.exit(1)  -- failure: is_main returned false
end
]])

  -- Run the script directly
  local pid = process.spawnp(lua_bin, {lua_bin, script_path})
  local _, status = process.wait(pid)
  assert(process.WIFEXITED(status), "expected normal exit")
  local exit_code = process.WEXITSTATUS(status)
  assert(exit_code == 0, "expected is_main to return true when script is run directly, got exit code " .. tostring(exit_code))
end
test_is_main_true_when_run_directly()

local function test_is_main_false_when_required()
  -- Create a module that checks cosmo.is_main
  local mod_path = path.join(TEST_TMPDIR, "is_main_module.lua")
  cosmo.Barf(mod_path, [[
local cosmo = require("cosmo")
return cosmo.is_main()
]])

  -- Create a script that requires the module
  local script_path = path.join(TEST_TMPDIR, "is_main_requirer.lua")
  cosmo.Barf(script_path, string.format([[
package.path = %q .. "/?.lua;" .. package.path
local result = require("is_main_module")
if result == false then
  os.exit(0)  -- success: is_main returned false for required module
else
  os.exit(1)  -- failure: is_main returned true for required module
end
]], TEST_TMPDIR))

  -- Run the script
  local pid = process.spawnp(lua_bin, {lua_bin, script_path})
  local _, status = process.wait(pid)
  assert(process.WIFEXITED(status), "expected normal exit")
  local exit_code = process.WEXITSTATUS(status)
  assert(exit_code == 0, "expected is_main to return false when script is required, got exit code " .. tostring(exit_code))
end
test_is_main_false_when_required()

-- Constants tests

local function test_signal_constants_defined()
  assert(type(process.SIGTERM) == "number", "SIGTERM should be a number")
  assert(type(process.SIGKILL) == "number", "SIGKILL should be a number")
  assert(type(process.SIGINT) == "number", "SIGINT should be a number")
  assert(type(process.SIGQUIT) == "number", "SIGQUIT should be a number")
  assert(type(process.SIGHUP) == "number", "SIGHUP should be a number")
  assert(type(process.SIGCHLD) == "number", "SIGCHLD should be a number")
end
test_signal_constants_defined()

local function test_wait_option_constants_defined()
  assert(type(process.WNOHANG) == "number", "WNOHANG should be a number")
  assert(type(process.WUNTRACED) == "number", "WUNTRACED should be a number")
  -- WCONTINUED may be nil on some platforms (e.g., Linux without job control)
  assert(process.WCONTINUED == nil or type(process.WCONTINUED) == "number",
    "WCONTINUED should be a number or nil")
end
test_wait_option_constants_defined()

local function test_rusage_constants_defined()
  assert(type(process.RUSAGE_SELF) == "number", "RUSAGE_SELF should be a number")
  assert(type(process.RUSAGE_CHILDREN) == "number", "RUSAGE_CHILDREN should be a number")
  assert(type(process.RUSAGE_THREAD) == "number", "RUSAGE_THREAD should be a number")
  assert(type(process.RUSAGE_BOTH) == "number", "RUSAGE_BOTH should be a number")
end
test_rusage_constants_defined()
