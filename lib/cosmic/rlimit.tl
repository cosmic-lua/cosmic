--- Resource limits and process scheduling priority.
--- Wraps cosmo.unix for resource limit and process priority operations.
local unix = require("cosmo.unix")

-- Resource Limits --

--- Gets resource limits for the current process.
--- Returns the soft and hard limits for the specified resource.
--- @param resource number The RLIMIT_* constant identifying the resource
--- @return number Soft limit (can be exceeded, may generate signal)
--- @return number Hard limit (cannot be exceeded by unprivileged processes)
local function getlimit(resource: number): number, number
  return unix.getrlimit(resource)
end

--- Sets resource limits for the current process.
--- The soft limit can be raised up to the hard limit.
--- Only privileged processes can raise the hard limit.
--- @param resource number The RLIMIT_* constant identifying the resource
--- @param soft number New soft limit
--- @param hard number? New hard limit (defaults to soft if not provided)
--- @return boolean True on success
local function setlimit(resource: number, soft: number, hard?: number): boolean
  return unix.setrlimit(resource, soft, hard)
end

-- Process Priority --

--- Adjusts the nice value (scheduling priority) of the calling process.
--- The nice value ranges from -20 (highest priority) to 19 (lowest priority).
--- Only privileged processes can lower the nice value (increase priority).
--- `inc` is added to the current nice value. Positive values decrease
--- priority, negative values increase it.
--- @param inc number Value to add to current nice value
--- @return number The new nice value
local function nice(inc: number): number
  return unix.nice(inc)
end

--- Gets the scheduling priority of a process, process group, or user.
--- @param which number What `who` refers to: PRIO_PROCESS, PRIO_PGRP, or PRIO_USER
--- @param who number The id to query (0 = calling process/group/user)
--- @return number The priority value (nice value), ranging from -20 to 19
local function getpriority(which: number, who: number): number
  return unix.getpriority(which, who)
end

--- Sets the scheduling priority of a process, process group, or user.
--- @param which number What `who` refers to: PRIO_PROCESS, PRIO_PGRP, or PRIO_USER
--- @param who number The id to modify (0 = calling process/group/user)
--- @param prio number New priority value (-20 to 19, lower = higher priority)
--- @return boolean True on success
local function setpriority(which: number, who: number, prio: number): boolean
  return unix.setpriority(which, who, prio)
end

-- Scheduling --

--- Relinquishes the CPU, allowing other processes to run.
--- Causes the calling thread to yield its scheduled time quantum.
--- Useful for cooperative multitasking or reducing CPU usage in busy loops.
local function yield()
  unix.sched_yield()
end

local record RlimitModule
  -- Resource limit functions
  getlimit: function(resource: number): number, number
  setlimit: function(resource: number, soft: number, hard?: number): boolean

  -- Priority functions
  nice: function(inc: number): number
  getpriority: function(which: number, who: number): number
  setpriority: function(which: number, who: number, prio: number): boolean

  -- Scheduling
  yield: function()

  -- Resource limit constants
  RLIMIT_AS: number
  RLIMIT_CPU: number
  RLIMIT_FSIZE: number
  RLIMIT_NPROC: number
  RLIMIT_NOFILE: number
  RLIMIT_RSS: number

  -- Priority scope constants
  PRIO_PROCESS: number
  PRIO_PGRP: number
  PRIO_USER: number
end

local M: RlimitModule = {
  -- Resource limit functions
  getlimit = getlimit,
  setlimit = setlimit,

  -- Priority functions
  nice = nice,
  getpriority = getpriority,
  setpriority = setpriority,

  -- Scheduling
  yield = yield,

  -- Resource limit constants
  RLIMIT_AS = unix.RLIMIT_AS,
  RLIMIT_CPU = unix.RLIMIT_CPU,
  RLIMIT_FSIZE = unix.RLIMIT_FSIZE,
  RLIMIT_NPROC = unix.RLIMIT_NPROC,
  RLIMIT_NOFILE = unix.RLIMIT_NOFILE,
  RLIMIT_RSS = unix.RLIMIT_RSS,

  -- Priority scope constants
  PRIO_PROCESS = unix.PRIO_PROCESS,
  PRIO_PGRP = unix.PRIO_PGRP,
  PRIO_USER = unix.PRIO_USER,
}

return M
