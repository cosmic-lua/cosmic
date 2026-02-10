#!/usr/bin/env cosmic
local cosmo = require("cosmo")
local path = require("cosmo.path")
local proc = require("cosmic.proc")
local child = require("cosmic.child")

local lua_bin = path.join(os.getenv("TEST_BIN"), "cosmic")
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
  local script_path = path.join(TEST_TMPDIR, "is_main_direct.lua")
  cosmo.Barf(script_path, [[
local cosmo = require("cosmo")
if cosmo.is_main() then
  os.exit(0)
else
  os.exit(1)
end
]])

  local pid = child.posix_spawnp(lua_bin, {lua_bin, script_path})
  local _, status = child.wait(pid)
  assert(child.WIFEXITED(status), "expected normal exit")
  local exit_code = child.WEXITSTATUS(status)
  assert(exit_code == 0, "expected is_main to return true when script is run directly, got exit code " .. tostring(exit_code))
end
test_is_main_true_when_run_directly()

local function test_proc_is_main_true_when_run_directly()
  local script_path = path.join(TEST_TMPDIR, "proc_is_main_direct.lua")
  cosmo.Barf(script_path, [[
local proc = require("cosmic.proc")
if proc.is_main() then
  os.exit(0)
else
  os.exit(1)
end
]])

  local pid = child.posix_spawnp(lua_bin, {lua_bin, script_path})
  local _, status = child.wait(pid)
  assert(child.WIFEXITED(status), "expected normal exit")
  local exit_code = child.WEXITSTATUS(status)
  assert(exit_code == 0, "expected proc.is_main to return true when script is run directly, got exit code " .. tostring(exit_code))
end
test_proc_is_main_true_when_run_directly()

local function test_is_main_false_when_required()
  local mod_path = path.join(TEST_TMPDIR, "is_main_module.lua")
  cosmo.Barf(mod_path, [[
local cosmo = require("cosmo")
return cosmo.is_main()
]])

  local script_path = path.join(TEST_TMPDIR, "is_main_requirer.lua")
  cosmo.Barf(script_path, string.format([[
package.path = %q .. "/?.lua;" .. package.path
local result = require("is_main_module")
if result == false then
  os.exit(0)
else
  os.exit(1)
end
]], TEST_TMPDIR))

  local pid = child.posix_spawnp(lua_bin, {lua_bin, script_path})
  local _, status = child.wait(pid)
  assert(child.WIFEXITED(status), "expected normal exit")
  local exit_code = child.WEXITSTATUS(status)
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
