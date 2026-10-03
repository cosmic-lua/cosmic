--- The descriptor a portable start retains on its artifact is no
--- program's but this core's, as core/artifact_fd_test.tl shows for
--- its Lua: here, for a host program a test starts, which reaches past
--- `open`'s refusal to /proc/<the worker's pid>/fd/<it>. A sandboxed
--- worker whose module does not declare `tool`, as this one does not,
--- is made undumpable when it is held from running its core
--- (core/syscalls.c's `landlock_restrict_execute`), so no process
--- without CAP_SYS_PTRACE over it -- none it starts has any -- follows
--- a link of its /proc/<pid>/fd.
---
--- Unsandboxed, or from no portable artifact, a host program reads the
--- program by its name anyway, and each test returns unchecked.

local Child = require("cosmic.child")
local Proc = require("cosmic.proc")
local sys = require("cosmic.sys")
local Test = require("cosmic.test")

--- A shell, and `cat`, to read the worker's descriptors with.
Test.needs{
  system = true,
}

--- The descriptor this process retains on its artifact, or nil for a
--- start from none, or where this worker is not held from running its
--- core: one run unsandboxed, whose working directory is not /tree.
local function held_artifact_fd(): integer | nil
  if sys.getcwd() ~= "/tree" then return nil end
  local relaunch, _ = Proc.relaunch()
  if relaunch == nil then return nil end
  local slot = math.tointeger(tonumber(relaunch.env.COSMIC_PORTABLE_ARTIFACT_FD))
  return slot ~= nil and relaunch.fds[slot] or nil
end

--- `script` run by the host's shell, with `...` its arguments.
local function shell(script: string, ...: string): Child.Result
  return (assert(Child.run({ "/bin/sh", "-c", script, "sh", ... },
    { env = {}, stdout = "capture", stderr = "capture" })))
end

--- A host program the worker starts cannot read the artifact through
--- the worker's /proc/<pid>/fd, nor learn where it is there: while one
--- it starts still reads its own /proc/self, and the worker its own.
local function test_a_host_program_cannot_reach_the_artifact_through_the_worker_s_proc()
  local fd = held_artifact_fd()
  if fd == nil then return end
  local pid, own = tostring(Proc.pid()), tostring(fd)
  local control = shell('cat /proc/self/stat >/dev/null && cat "/proc/$1/stat" >/dev/null', pid)
  assert(control.code == 0, "the shell could not read /proc: " .. tostring(control.stderr))
  for _, script in ipairs({
      'exec cat "/proc/$1/fd/$2"',
      'exec cat "/proc/$1/task/$1/fd/$2"',
      'exec cat "/proc/$PPID/fd/$2"',
      'exec readlink "/proc/$1/fd/$2"',
      'exec cat "/proc/$1/map_files/"*',
  }) do
    local result = shell(script, pid, own)
    assert(result.code ~= 0 and result.stdout == "",
      script .. " reached the artifact: " .. result.code .. " " .. #result.stdout .. " bytes")
  end
  -- The worker itself still reads its own.
  assert(sys.readlink("/proc/self/fd/0") ~= nil)
  assert(sys.stat("/proc/self/status") ~= nil)
end
