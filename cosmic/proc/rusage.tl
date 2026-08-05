--- Internal shard of cosmic.proc: resource usage, resource limits,
--- and scheduling priority. Split out to keep cosmic/proc/init.tl
--- under the 500-line cap; the public surface is unchanged —
--- require("cosmic.proc") exposes these as before.
local unix = require("cosmo.unix")
local errstr = require("cosmic.errno").str

local type Rusage = unix.Rusage

--- A resource limit pair. A record rather than (soft, hard, err)
--- returns: the old shape put the error in slot 3, where
--- `local soft, hard = ...` silently lost it.
local record Rlimit
  --- Soft limit (can be exceeded, may generate a signal).
  soft: integer
  --- Hard limit (ceiling for unprivileged processes).
  hard: integer
end

-- Resource Usage --

--- Gets resource usage statistics.
--- @param who integer? Who to query: RUSAGE_SELF (default), RUSAGE_CHILDREN, RUSAGE_THREAD, RUSAGE_BOTH
--- @return Rusage | nil Resource usage statistics
--- @return string | nil Error message on failure (the binding can fail;
--- the previous bare Rusage type hid it)
local function getrusage(who?: integer): Rusage | nil, string
  local ru, err = unix.getrusage(who)
  if not ru then
    return nil, errstr(err, "getrusage")
  end
  return ru
end

-- Resource Limits --

--- Gets resource limits for the current process.
--- @param resource integer The RLIMIT_* constant identifying the resource
--- @return Rlimit | nil The soft and hard limits
--- @return string? Error message on failure
local function getrlimit(resource: integer): Rlimit | nil, string
  local soft, hard = unix.getrlimit(resource)
  if soft == nil then
    -- On failure the binding returns (nil, err, errno): the error string
    -- arrives in the second slot, where the hard limit would have been.
    return nil, errstr(hard, "getrlimit")
  end
  return {soft = soft, hard = hard}
end

--- Sets resource limits for the current process.
--- The soft limit can be raised up to the hard limit.
--- Only privileged processes can raise the hard limit.
--- @param resource integer The RLIMIT_* constant identifying the resource
--- @param soft integer New soft limit
--- @param hard integer? New hard limit (defaults to soft if not provided)
--- @return boolean True on success
--- @return string? Error message on failure
local function setrlimit(resource: integer, soft: integer, hard?: integer): boolean, string
  local ok, err = unix.setrlimit(resource, soft, hard)
  if not ok then
    return false, errstr(err, "setrlimit")
  end
  return true
end

-- Process Priority --

--- Adjusts the nice value (scheduling priority) of the calling process.
--- The nice value ranges from -20 (highest priority) to 19 (lowest priority).
--- Only privileged processes can lower the nice value (increase priority).
--- @param inc integer Value to add to current nice value
--- @return integer | nil The new nice value, or nil on failure
--- @return string? Error message on failure
local function nice(inc: integer): integer | nil, string
  local val, err = unix.nice(inc)
  if val == nil then
    return nil, errstr(err, "nice")
  end
  return val
end

--- Gets the scheduling priority of a process, process group, or user.
--- @param which integer What `who` refers to: PRIO_PROCESS, PRIO_PGRP, or PRIO_USER
--- @param who integer The id to query (0 = calling process/group/user)
--- @return integer | nil The priority value (-20 to 19), or nil on failure
--- @return string? Error message on failure
local function getpriority(which: integer, who: integer): integer | nil, string
  local prio, err = unix.getpriority(which, who)
  if prio == nil then
    return nil, errstr(err, "getpriority")
  end
  return prio
end

--- Sets the scheduling priority of a process, process group, or user.
--- @param which integer What `who` refers to: PRIO_PROCESS, PRIO_PGRP, or PRIO_USER
--- @param who integer The id to modify (0 = calling process/group/user)
--- @param prio integer New priority value (-20 to 19, lower = higher priority)
--- @return boolean True on success
--- @return string? Error message on failure
local function setpriority(which: integer, who: integer, prio: integer): boolean, string
  local ok, err = unix.setpriority(which, who, prio)
  if not ok then
    return false, errstr(err, "setpriority")
  end
  return true
end

local record RusageModule
  type Rlimit = Rlimit
  getrusage: function(who?: integer): Rusage | nil, string
  getrlimit: function(resource: integer): Rlimit | nil, string
  setrlimit: function(resource: integer, soft: integer, hard?: integer): boolean, string
  nice: function(inc: integer): integer | nil, string
  getpriority: function(which: integer, who: integer): integer | nil, string
  setpriority: function(which: integer, who: integer, prio: integer): boolean, string
end

local M: RusageModule = {
  getrusage = getrusage,
  getrlimit = getrlimit,
  setrlimit = setrlimit,
  nice = nice,
  getpriority = getpriority,
  setpriority = setpriority,
}

return M
