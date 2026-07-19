--- Current process management.
--- Identity, session/group control, exec, and resource usage.
---
--- The global `arg` table layout when running a script:
---   arg[-1]  — path to the cosmic interpreter binary (use this to re-invoke
---              cosmic, e.g. to spawn a child running another script)
---   arg[0]   — script path as the runtime sees it (/zip/main.lua when the
---              script is dispatched by the embedded entry point — NOT the
---              interpreter path)
---   arg[1..] — user arguments
--- `arg` is typed {string}, so negative indices need
--- `rawget(arg, -1) as string` to pass the strict type checker.
local unix = require("cosmo.unix")
local cosmo = require("cosmo")

local errstr = require("cosmic.errno").str

--- Process resource usage statistics (the generated unix.Rusage record):
--- CPU time, memory usage, I/O, and context switch counters.
local type Rusage = unix.Rusage

-- Identity --

--- Returns process id of current process; does not fail.
--- @return integer The current process id
local getpid: function(): integer = unix.getpid

--- Returns process id of parent process; does not fail.
--- @return integer The parent process id
local getppid: function(): integer = unix.getppid

-- Session & Group --

--- Gets session id for a process.
--- @param pid integer The process id to query
--- @return integer | nil The session id, or nil on failure
--- @return string? Error message on failure
local function getsid(pid: integer): integer | nil, string
  local sid, err = unix.getsid(pid)
  if sid == nil then
    return nil, errstr(err, "getsid")
  end
  return sid
end

--- Gets process group id of calling process; does not fail.
--- @return integer The process group id
local function getpgrp(): integer
  return (unix.getpgrp())
end

--- Gets process group id for a specific process.
--- @param pid integer The process id to query
--- @return integer | nil The process group id, or nil on failure
--- @return string? Error message on failure
local function getpgid(pid: integer): integer | nil, string
  local pgid, err = unix.getpgid(pid)
  if pgid == nil then
    return nil, errstr(err, "getpgid")
  end
  return pgid
end

--- Sets process group id (same as setpgid(0, 0)).
--- @return integer | nil The new process group id, or nil on failure
--- @return string? Error message on failure
local function setpgrp(): integer | nil, string
  local pgid, err = unix.setpgrp()
  if pgid == nil then
    return nil, errstr(err, "setpgrp")
  end
  return pgid
end

--- Sets process group id.
--- @param pid integer Process id (0 means calling process)
--- @param pgid integer Process group id (0 means use pid as pgid)
--- @return boolean True on success
--- @return string? Error message on failure
local function setpgid(pid: integer, pgid: integer): boolean, string
  local ok, err = unix.setpgid(pid, pgid)
  if not ok then
    return false, errstr(err, "setpgid")
  end
  return true
end

--- Creates a new session.
--- The calling process becomes the session leader and process group leader.
--- Used for creating daemons.
--- Fails with ENOSYS on Windows NT.
--- @return integer | nil The new session id, or nil on failure
--- @return string? Error message on failure
local function setsid(): integer | nil, string
  local sid, err = unix.setsid()
  if sid == nil then
    return nil, errstr(err, "setsid")
  end
  return sid
end

--- Daemonizes the current process.
--- Performs standard Unix daemonization: fork, setsid, redirect I/O.
--- @param nochdir boolean? If true, don't change to root directory (default: false)
--- @param noclose boolean? If true, don't redirect stdin/stdout/stderr (default: false)
--- @return boolean True on success
--- @return string? Error message on failure
local function daemon(nochdir?: boolean, noclose?: boolean): boolean, string
  local ok, err = unix.daemon(nochdir, noclose)
  if not ok then
    return false, errstr(err, "daemon")
  end
  return true
end

-- Termination --

--- Terminates the current process immediately.
--- Memory is freed, file descriptors are closed, connections are reset.
--- This function never returns.
--- @param exitcode integer? Exit code (defaults to 0)
local exit: function(exitcode?: integer) = unix.exit

-- Exec (replace current process) --

--- Performs $PATH lookup of executable.
--- Returns the absolute path to the executable if found, nil otherwise.
--- On Windows, programs should be installed without .exe/.com suffix for discovery.
--- @param prog string The program name to search for
--- @return string? The absolute path to the executable, or nil if not found
local function commandv(prog: string): string
  return (unix.commandv(prog))
end

--- Replaces current process with new program; never returns on success.
--- prog must be an absolute path (use commandv for PATH search).
--- @param prog string Absolute path to the executable
--- @param args {string} Argument vector passed to the program
--- @param env {string} Environment variables (KEY=value format)
--- @return nil, string Only returns on error
local function execve(prog: string, args: {string}, env: {string}): nil, string
  local _, err = unix.execve(prog, args, env)
  return nil, errstr(err, "execve: " .. prog)
end

--- Executes program with PATH search; never returns on success.
--- Unlike execve(), this searches for prog in $PATH.
--- @param prog string The program name to execute
--- @param argv {string}? Argument vector. Defaults to {prog}
--- @return nil, string Only returns on error
local function execvp(prog: string, argv?: {string}): nil, string
  local _, err = unix.execvp(prog, argv)
  return nil, errstr(err, "execvp: " .. prog)
end

--- Executes program with PATH search and custom environment; never
--- returns on success. Like execvp() with a custom environment.
--- @param prog string The program name to execute
--- @param argv {string} Argument vector passed to the program
--- @param envp {string}? Environment variables. Inherits if not specified
--- @return nil, string Only returns on error
local function execvpe(prog: string, argv: {string}, envp?: {string}): nil, string
  local _, err = unix.execvpe(prog, argv, envp)
  return nil, errstr(err, "execvpe: " .. prog)
end

--- Executes program from an already-opened file descriptor; never
--- returns on success.
--- @param fd integer Open file descriptor pointing to an executable
--- @param argv {string} Argument vector passed to the program
--- @param envp {string}? Environment variables. Inherits if not specified
--- @return nil, string Only returns on error
local function fexecve(fd: integer, argv: {string}, envp?: {string}): nil, string
  local _, err = unix.fexecve(fd, argv, envp)
  return nil, errstr(err, "fexecve")
end

-- Process Control (children) --

--- Creates a new process (fork).
--- @return integer The child pid in the parent, 0 in the child
local function fork(): integer
  return (unix.fork())
end

--- Spawns a program via posix_spawn (no PATH search).
--- @param prog string Absolute path to the executable
--- @param argv {string} Argument vector passed to the program
--- @param envp {string}? Environment (KEY=value); inherits if omitted
--- @return integer The child pid on success
local function posix_spawn(prog: string, argv: {string}, envp?: {string}): integer
  return (unix.spawn(prog, argv, envp))
end

--- Spawns a program via posix_spawnp (PATH search).
--- @param prog string Program name to execute
--- @param argv {string} Argument vector passed to the program
--- @param envp {string}? Environment (KEY=value); inherits if omitted
--- @return integer The child pid on success
local function posix_spawnp(prog: string, argv: {string}, envp?: {string}): integer
  return (unix.spawnp(prog, argv, envp))
end

--- Waits for a child process to change state.
--- @param pid integer? Child pid to wait for (-1 or nil for any child)
--- @param options integer? Wait options (e.g. WNOHANG)
--- @return integer | nil The pid that changed state (0 with WNOHANG if none), or nil on failure
--- @return integer Status word (interpret with WIFEXITED/WEXITSTATUS/...)
--- @return Rusage Resource usage for the reaped child
--- @return string? Error message on failure
local function wait(pid?: integer, options?: integer): integer | nil, integer, Rusage, string
  local wpid, status, rusage = unix.wait(pid, options)
  if wpid == nil then
    -- On failure the binding returns (nil, err, errno): the error string
    -- arrives in the second slot, where the status word would have been.
    return nil, nil, nil, errstr(status, "wait")
  end
  return wpid, status, rusage
end

--- Sends a signal to a process.
--- @param pid integer Process id to signal
--- @param sig integer Signal number (e.g. SIGTERM, SIGKILL)
--- @return boolean True on success
local function kill(pid: integer, sig: integer): boolean
  return (unix.kill(pid, sig))
end

--- True if the child exited normally.
local WIFEXITED: function(status: integer): boolean = unix.WIFEXITED

--- The exit code (valid when WIFEXITED is true).
local WEXITSTATUS: function(status: integer): integer = unix.WEXITSTATUS

--- True if the child was terminated by a signal.
local WIFSIGNALED: function(status: integer): boolean = unix.WIFSIGNALED

--- The terminating signal number (valid when WIFSIGNALED is true).
local WTERMSIG: function(status: integer): integer = unix.WTERMSIG

-- Resource Usage --

--- Gets resource usage statistics.
--- @param who integer? Who to query: RUSAGE_SELF (default), RUSAGE_CHILDREN, RUSAGE_THREAD, RUSAGE_BOTH
--- @return Rusage Resource usage statistics
local function getrusage(who?: integer): Rusage
  return (unix.getrusage(who))
end

-- Resource Limits --

--- Gets resource limits for the current process.
--- Returns the soft and hard limits for the specified resource.
--- @param resource integer The RLIMIT_* constant identifying the resource
--- @return integer | nil Soft limit (can be exceeded, may generate signal), or nil on failure
--- @return integer Hard limit (cannot be exceeded by unprivileged processes)
--- @return string? Error message on failure
local function getrlimit(resource: integer): integer | nil, integer, string
  local soft, hard = unix.getrlimit(resource)
  if soft == nil then
    -- On failure the binding returns (nil, err, errno): the error string
    -- arrives in the second slot, where the hard limit would have been.
    return nil, nil, errstr(hard, "getrlimit")
  end
  return soft, hard
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

-- Scheduling --

--- Relinquishes the CPU, allowing other processes to run.
--- Causes the calling thread to yield its scheduled time quantum.
local sched_yield: function() = unix.sched_yield

-- Script Detection --

--- Returns true if current script is being run as the main program.
--- Returns false if the script is being loaded as a module via require().
--- Use this to guard code that should only run when executed directly.
--- @return boolean True if running as main script
-- Assigned directly to avoid adding a stack frame, since cosmo.is_main()
-- inspects the call stack to determine if the caller is the main script.
local is_main: function(): boolean = cosmo.is_main

local record ProcModule
  -- Identity
  getpid: function(): integer
  getppid: function(): integer

  -- Session & Group
  getsid: function(pid: integer): integer | nil, string
  getpgrp: function(): integer
  getpgid: function(pid: integer): integer | nil, string
  setpgrp: function(): integer | nil, string
  setpgid: function(pid: integer, pgid: integer): boolean, string
  setsid: function(): integer | nil, string
  daemon: function(nochdir?: boolean, noclose?: boolean): boolean, string

  -- Termination
  exit: function(exitcode?: integer)

  -- Exec
  commandv: function(prog: string): string
  execve: function(prog: string, args: {string}, env: {string}): nil, string
  execvp: function(prog: string, argv?: {string}): nil, string
  execvpe: function(prog: string, argv: {string}, envp?: {string}): nil, string
  fexecve: function(fd: integer, argv: {string}, envp?: {string}): nil, string

  -- Process control (children)
  fork: function(): integer
  posix_spawn: function(prog: string, argv: {string}, envp?: {string}): integer
  posix_spawnp: function(prog: string, argv: {string}, envp?: {string}): integer
  wait: function(pid?: integer, options?: integer): integer | nil, integer, Rusage, string
  kill: function(pid: integer, sig: integer): boolean
  WIFEXITED: function(status: integer): boolean
  WEXITSTATUS: function(status: integer): integer
  WIFSIGNALED: function(status: integer): boolean
  WTERMSIG: function(status: integer): integer

  -- Resource usage
  getrusage: function(who?: integer): Rusage

  -- Resource limits
  getrlimit: function(resource: integer): integer | nil, integer, string
  setrlimit: function(resource: integer, soft: integer, hard?: integer): boolean, string

  -- Priority
  nice: function(inc: integer): integer | nil, string
  getpriority: function(which: integer, who: integer): integer | nil, string
  setpriority: function(which: integer, who: integer, prio: integer): boolean, string

  -- Scheduling
  sched_yield: function()

  -- Script detection
  is_main: function(): boolean

  -- Rusage constants
  RUSAGE_SELF: integer
  RUSAGE_CHILDREN: integer
  RUSAGE_THREAD: integer
  RUSAGE_BOTH: integer

  -- Resource limit constants
  RLIMIT_AS: integer
  RLIMIT_CPU: integer
  RLIMIT_FSIZE: integer
  RLIMIT_NOFILE: integer
  RLIMIT_NPROC: integer
  RLIMIT_RSS: integer

  -- Priority scope constants
  PRIO_PROCESS: integer
  PRIO_PGRP: integer
  PRIO_USER: integer

  -- Wait options
  WNOHANG: integer
  WUNTRACED: integer
  WCONTINUED: integer
end

local M: ProcModule = {
  -- Identity
  getpid = getpid,
  getppid = getppid,

  -- Session & Group
  getsid = getsid,
  getpgrp = getpgrp,
  getpgid = getpgid,
  setpgrp = setpgrp,
  setpgid = setpgid,
  setsid = setsid,
  daemon = daemon,

  -- Termination
  exit = exit,

  -- Exec
  commandv = commandv,
  execve = execve,
  execvp = execvp,
  execvpe = execvpe,
  fexecve = fexecve,

  -- Process control (children)
  fork = fork,
  posix_spawn = posix_spawn,
  posix_spawnp = posix_spawnp,
  wait = wait,
  kill = kill,
  WIFEXITED = WIFEXITED,
  WEXITSTATUS = WEXITSTATUS,
  WIFSIGNALED = WIFSIGNALED,
  WTERMSIG = WTERMSIG,

  -- Resource usage
  getrusage = getrusage,

  -- Resource limits
  getrlimit = getrlimit,
  setrlimit = setrlimit,

  -- Priority
  nice = nice,
  getpriority = getpriority,
  setpriority = setpriority,

  -- Scheduling
  sched_yield = sched_yield,

  -- Script detection
  is_main = is_main,

  -- Rusage constants
  RUSAGE_SELF = unix.RUSAGE_SELF,
  RUSAGE_CHILDREN = unix.RUSAGE_CHILDREN,
  RUSAGE_THREAD = unix.RUSAGE_THREAD,
  RUSAGE_BOTH = unix.RUSAGE_BOTH,

  -- Resource limit constants
  RLIMIT_AS = unix.RLIMIT_AS,
  RLIMIT_CPU = unix.RLIMIT_CPU,
  RLIMIT_FSIZE = unix.RLIMIT_FSIZE,
  RLIMIT_NOFILE = unix.RLIMIT_NOFILE,
  RLIMIT_NPROC = unix.RLIMIT_NPROC,
  RLIMIT_RSS = unix.RLIMIT_RSS,

  -- Priority scope constants
  PRIO_PROCESS = unix.PRIO_PROCESS,
  PRIO_PGRP = unix.PRIO_PGRP,
  PRIO_USER = unix.PRIO_USER,

  -- Wait options
  WNOHANG = unix.WNOHANG,
  WUNTRACED = unix.WUNTRACED,
  WCONTINUED = unix.WCONTINUED,
}

return M
