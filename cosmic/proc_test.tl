#!/usr/bin/env cosmic
local fs = require("cosmic.fs")
local proc = require("cosmic.proc")

local lua_bin = fs.join(os.getenv("TEST_BIN"), "cosmic")
local TEST_TMPDIR = os.getenv("TEST_TMPDIR")

-- getpid tests --

local function test_getpid_returns_number()
  local pid = proc.getpid()
  assert(type(pid) == "number", "expected number, got " .. type(pid))
  assert(pid > 0, "expected positive pid, got " .. tostring(pid))
end
test_getpid_returns_number()

local function test_getpid_is_consistent()
  local pid1 = proc.getpid()
  local pid2 = proc.getpid()
  assert(pid1 == pid2, "expected consistent pid, got " .. tostring(pid1) .. " and " .. tostring(pid2))
end
test_getpid_is_consistent()

-- getppid tests --

local function test_getppid_returns_number()
  local ppid = proc.getppid()
  assert(type(ppid) == "number", "expected number, got " .. type(ppid))
  assert(ppid > 0, "expected positive ppid, got " .. tostring(ppid))
end
test_getppid_returns_number()

local function test_getppid_different_from_pid()
  local pid = proc.getpid()
  local ppid = proc.getppid()
  assert(pid ~= ppid, "expected pid and ppid to be different")
end
test_getppid_different_from_pid()

-- commandv tests --

local function test_commandv_finds_ls()
  local path_to_ls = proc.commandv("ls")
  assert(path_to_ls ~= nil, "expected to find 'ls' command")
  assert(path_to_ls:find("/", 1, true), "expected absolute path, got " .. tostring(path_to_ls))
end
test_commandv_finds_ls()

local function test_commandv_returns_nil_for_nonexistent()
  local result = proc.commandv("nonexistent_command_xyz_12345")
  assert(result == nil, "expected nil for nonexistent command, got " .. tostring(result))
end
test_commandv_returns_nil_for_nonexistent()

-- getpgrp / getpgid tests --

local function test_getpgrp_returns_number()
  local pgrp = proc.getpgrp()
  assert(type(pgrp) == "number", "expected number, got " .. type(pgrp))
  assert(pgrp > 0, "expected positive pgrp, got " .. tostring(pgrp))
end
test_getpgrp_returns_number()

local function test_getpgid_for_self()
  local pgid = proc.getpgid(proc.getpid())
  local pgrp = proc.getpgrp()
  assert(pgid == pgrp, "expected getpgid(getpid()) == getpgrp(), got " .. tostring(pgid) .. " vs " .. tostring(pgrp))
end
test_getpgid_for_self()

-- getsid test --

local function test_getsid_returns_number()
  local sid = proc.getsid(proc.getpid())
  assert(type(sid) == "number", "expected number, got " .. type(sid))
  assert(sid > 0, "expected positive sid, got " .. tostring(sid))
end
test_getsid_returns_number()

-- getrusage tests --

local function test_getrusage_returns_rusage()
  local rusage = proc.getrusage(proc.RUSAGE_SELF)
  assert(rusage ~= nil, "expected rusage object")
  local utime_sec, utime_nsec = rusage:utime()
  assert(type(utime_sec) == "number", "expected utime seconds to be number")
  assert(type(utime_nsec) == "number", "expected utime nanos to be number")
end
test_getrusage_returns_rusage()

local function test_getrusage_maxrss()
  local rusage = proc.getrusage(proc.RUSAGE_SELF)
  local maxrss = rusage:maxrss()
  assert(type(maxrss) == "number", "expected maxrss to be number")
  assert(maxrss >= 0, "expected non-negative maxrss")
end
test_getrusage_maxrss()

-- is_main tests --

local function test_is_main_returns_boolean()
  local result = proc.is_main()
  assert(type(result) == "boolean", "expected boolean, got " .. type(result))
end
test_is_main_returns_boolean()

local function test_is_main_true_when_run_directly()
  local script_path = fs.join(TEST_TMPDIR, "is_main_direct.lua")
  fs.write(script_path, [[
local proc = require("cosmic.proc")
if proc.is_main() then
  os.exit(0)
else
  os.exit(1)
end
]])

  local pid = proc.posix_spawnp(lua_bin, {lua_bin, script_path})
  local _, status = proc.wait(pid)
  assert(proc.WIFEXITED(status), "expected normal exit")
  local exit_code = proc.WEXITSTATUS(status)
  assert(exit_code == 0, "expected is_main to return true when script is run directly, got exit code " .. tostring(exit_code))
end
test_is_main_true_when_run_directly()

local function test_proc_is_main_true_when_run_directly()
  local script_path = fs.join(TEST_TMPDIR, "proc_is_main_direct.lua")
  fs.write(script_path, [[
local proc = require("cosmic.proc")
if proc.is_main() then
  os.exit(0)
else
  os.exit(1)
end
]])

  local pid = proc.posix_spawnp(lua_bin, {lua_bin, script_path})
  local _, status = proc.wait(pid)
  assert(proc.WIFEXITED(status), "expected normal exit")
  local exit_code = proc.WEXITSTATUS(status)
  assert(exit_code == 0, "expected proc.is_main to return true when script is run directly, got exit code " .. tostring(exit_code))
end
test_proc_is_main_true_when_run_directly()

local function test_is_main_false_when_required()
  local mod_path = fs.join(TEST_TMPDIR, "is_main_module.lua")
  fs.write(mod_path, [[
local proc = require("cosmic.proc")
return proc.is_main()
]])

  local script_path = fs.join(TEST_TMPDIR, "is_main_requirer.lua")
  fs.write(script_path, string.format([[
package.path = %q .. "/?.lua;" .. package.path
local result = require("is_main_module")
if result == false then
  os.exit(0)
else
  os.exit(1)
end
]], TEST_TMPDIR))

  local pid = proc.posix_spawnp(lua_bin, {lua_bin, script_path})
  local _, status = proc.wait(pid)
  assert(proc.WIFEXITED(status), "expected normal exit")
  local exit_code = proc.WEXITSTATUS(status)
  assert(exit_code == 0, "expected is_main to return false when script is required, got exit code " .. tostring(exit_code))
end
test_is_main_false_when_required()

-- Constants tests --

local function test_rusage_constants_defined()
  assert(type(proc.RUSAGE_SELF) == "number", "RUSAGE_SELF should be a number")
  assert(type(proc.RUSAGE_CHILDREN) == "number", "RUSAGE_CHILDREN should be a number")
  assert(type(proc.RUSAGE_THREAD) == "number", "RUSAGE_THREAD should be a number")
  assert(type(proc.RUSAGE_BOTH) == "number", "RUSAGE_BOTH should be a number")
end
test_rusage_constants_defined()

-- Resource limit tests --

local function test_rlimit_constants_defined()
  assert(type(proc.RLIMIT_AS) == "number", "RLIMIT_AS should be a number")
  assert(type(proc.RLIMIT_CPU) == "number", "RLIMIT_CPU should be a number")
  assert(type(proc.RLIMIT_FSIZE) == "number", "RLIMIT_FSIZE should be a number")
  assert(type(proc.RLIMIT_NOFILE) == "number", "RLIMIT_NOFILE should be a number")
  assert(type(proc.RLIMIT_NPROC) == "number", "RLIMIT_NPROC should be a number")
  assert(type(proc.RLIMIT_RSS) == "number", "RLIMIT_RSS should be a number")
end
test_rlimit_constants_defined()

local function test_getrlimit_returns_numbers()
  local soft, hard = proc.getrlimit(proc.RLIMIT_NOFILE)
  assert(type(soft) == "number", "getrlimit soft should return number, got " .. type(soft))
  assert(type(hard) == "number", "getrlimit hard should return number, got " .. type(hard))
end
test_getrlimit_returns_numbers()

local function test_getrlimit_soft_le_hard()
  local soft, hard = proc.getrlimit(proc.RLIMIT_NOFILE)
  assert(soft > 0, "soft limit should be positive")
  assert(hard > 0, "hard limit should be positive")
  assert(soft <= hard, "soft limit should not exceed hard limit")
end
test_getrlimit_soft_le_hard()

local function test_setrlimit()
  local soft, hard = proc.getrlimit(proc.RLIMIT_NOFILE)
  if soft > 64 then
    local ok, err = proc.setrlimit(proc.RLIMIT_NOFILE, 64, hard)
    assert(ok == true, "setrlimit should succeed when lowering soft limit: " .. tostring(err))
    local new_soft, new_hard = proc.getrlimit(proc.RLIMIT_NOFILE)
    assert(new_soft == 64, "soft limit should be updated to 64")
    assert(new_hard == hard, "hard limit should remain unchanged")
    proc.setrlimit(proc.RLIMIT_NOFILE, soft, hard)
  end
end
test_setrlimit()

-- Priority tests --

local function test_priority_constants_defined()
  assert(type(proc.PRIO_PROCESS) == "number", "PRIO_PROCESS should be a number")
  assert(type(proc.PRIO_PGRP) == "number", "PRIO_PGRP should be a number")
  assert(type(proc.PRIO_USER) == "number", "PRIO_USER should be a number")
end
test_priority_constants_defined()

local function test_getpriority_returns_number()
  local prio = proc.getpriority(proc.PRIO_PROCESS, 0)
  assert(type(prio) == "number", "getpriority should return number, got " .. type(prio))
end
test_getpriority_returns_number()

local function test_getpriority_range()
  local prio = proc.getpriority(proc.PRIO_PROCESS, 0)
  assert(prio >= -20, "priority should be >= -20, got " .. tostring(prio))
  assert(prio <= 19, "priority should be <= 19, got " .. tostring(prio))
end
test_getpriority_range()

local function test_nice()
  local before = proc.getpriority(proc.PRIO_PROCESS, 0)
  local after = proc.nice(0)
  assert(type(after) == "number", "nice should return number")
  assert(after == before, "nice(0) should not change priority")
end
test_nice()

local function test_setpriority()
  local current = proc.getpriority(proc.PRIO_PROCESS, 0)
  local ok, err = proc.setpriority(proc.PRIO_PROCESS, 0, current)
  assert(type(ok) == "boolean", "setpriority should return boolean")
  assert(ok == true, "setpriority to current value should succeed: " .. tostring(err))
end
test_setpriority()

-- Scheduling tests --

local function test_sched_yield()
  -- sched_yield should complete without error; if it throws, the test fails
  proc.sched_yield()
end
test_sched_yield()

-- Process control (children) --
-- These low-level fork/wait/kill/W* passthroughs moved here from cosmic.child,
-- which now hosts only the high-level spawn API.
local time = require("cosmic.time")
local signal = require("cosmic.signal")

local function test_fork_and_wait()
  local pid = proc.fork()
  if pid == 0 then
    proc.exit(42)
  else
    assert(pid > 0, "expected positive child pid in parent, got " .. tostring(pid))
    local waited_pid, status = proc.wait(pid)
    assert(waited_pid == pid, "expected to wait for child " .. tostring(pid) .. ", got " .. tostring(waited_pid))
    assert(proc.WIFEXITED(status), "expected child to exit normally")
    assert(proc.WEXITSTATUS(status) == 42, "expected exit code 42, got " .. tostring(proc.WEXITSTATUS(status)))
  end
end
test_fork_and_wait()

local function test_fork_child_has_different_pid()
  local parent_pid = proc.getpid()
  local marker_file = fs.join(TEST_TMPDIR, "fork_test_" .. tostring(parent_pid))
  local pid = proc.fork()
  if pid == 0 then
    local f = io.open(marker_file, "w")
    if f then
      f:write(tostring(proc.getpid()))
      f:close()
    end
    proc.exit(0)
  else
    proc.wait(pid)
    local f = io.open(marker_file, "r")
    assert(f ~= nil, "expected marker file to exist")
    local child_pid = tonumber(f:read("*a"))
    f:close()
    os.remove(marker_file)
    assert(child_pid ~= parent_pid, "expected child to have different pid")
    assert(child_pid == pid, "expected child pid " .. tostring(pid) .. ", got " .. tostring(child_pid))
  end
end
test_fork_child_has_different_pid()

local function test_wexitstatus_values()
  for _, expected_code in ipairs({0, 1, 42, 127, 255}) do
    local pid = proc.fork()
    if pid == 0 then
      proc.exit(expected_code)
    else
      local _, status = proc.wait(pid)
      assert(proc.WIFEXITED(status), "expected WIFEXITED for code " .. tostring(expected_code))
      assert(proc.WEXITSTATUS(status) == expected_code,
        "expected exit code " .. tostring(expected_code) .. ", got " .. tostring(proc.WEXITSTATUS(status)))
    end
  end
end
test_wexitstatus_values()

local function test_wifsignaled_on_kill()
  local pid = proc.fork()
  if pid == 0 then
    time.sleep(10)
    proc.exit(0)
  else
    assert(proc.kill(pid, signal.SIGKILL), "expected kill to succeed")
    local _, status = proc.wait(pid)
    assert(proc.WIFSIGNALED(status), "expected WIFSIGNALED to be true")
    assert(proc.WTERMSIG(status) == signal.SIGKILL,
      "expected SIGKILL (" .. tostring(signal.SIGKILL) .. "), got " .. tostring(proc.WTERMSIG(status)))
  end
end
test_wifsignaled_on_kill()

local function test_wnohang_returns_zero_for_running_process()
  local pid = proc.fork()
  if pid == 0 then
    time.sleep(0, 100000000) -- 100ms
    proc.exit(0)
  else
    local waited_pid = proc.wait(pid, proc.WNOHANG)
    assert(waited_pid == 0 or waited_pid == pid, "expected 0 or pid, got " .. tostring(waited_pid))
    if waited_pid == 0 then
      proc.wait(pid)
    end
  end
end
test_wnohang_returns_zero_for_running_process()

local function test_posix_spawn_returns_pid()
  local ls_path = proc.commandv("ls")
  if ls_path then
    local pid = proc.posix_spawn(ls_path, {"ls"})
    assert(pid > 0, "expected positive pid, got " .. tostring(pid))
    proc.wait(pid)
  end
end
test_posix_spawn_returns_pid()

local function test_wait_option_constants_defined()
  assert(type(proc.WNOHANG) == "number", "WNOHANG should be a number")
  assert(type(proc.WUNTRACED) == "number", "WUNTRACED should be a number")
  assert(proc.WCONTINUED == nil or type(proc.WCONTINUED) == "number",
    "WCONTINUED should be a number or nil")
end
test_wait_option_constants_defined()

-- Error fidelity: failed session/group/priority/rlimit/exec
-- calls must surface the binding's errno string, not truncate it.

local function test_setpgid_error_names_errno()
  -- pid 1 is in a different session, so setpgid(1, 1) always fails.
  local ok, err = proc.setpgid(1, 1)
  assert(ok == false, "setpgid(1, 1) should fail")
  assert(type(err) == "string" and err:match("E%u+"),
    "setpgid error should name the errno, got: " .. tostring(err))
end
test_setpgid_error_names_errno()

local function test_getsid_error_names_errno()
  local sid, err = proc.getsid(999999999)
  assert(sid == nil, "getsid of absent pid should return nil")
  assert(type(err) == "string" and err:match("ESRCH"),
    "getsid error should name ESRCH, got: " .. tostring(err))
end
test_getsid_error_names_errno()

local function test_getpriority_error_names_errno()
  local prio, err = proc.getpriority(999999, 0)
  assert(prio == nil, "getpriority with bad which should return nil")
  assert(type(err) == "string" and err:match("EINVAL"),
    "getpriority error should name EINVAL, got: " .. tostring(err))
end
test_getpriority_error_names_errno()

local function test_getrlimit_error_names_errno()
  local soft, hard, err = proc.getrlimit(999999)
  assert(soft == nil and hard == nil, "getrlimit with bad resource should return nils")
  assert(type(err) == "string" and err:match("EINVAL"),
    "getrlimit error should name EINVAL, got: " .. tostring(err))
end
test_getrlimit_error_names_errno()

local function test_execve_error_names_errno()
  local _, err = proc.execve("/nonexistent/binary/xyz", {"/nonexistent/binary/xyz"}, {})
  assert(type(err) == "string" and err:match("ENOENT"),
    "execve error should name ENOENT, got: " .. tostring(err))
  assert(err:match("/nonexistent/binary/xyz"),
    "execve error should name the program, got: " .. tostring(err))
end
test_execve_error_names_errno()
