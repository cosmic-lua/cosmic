--- Current process management.
--- Identity, session/group control, exec, signals, and resource usage.
local unix = require("cosmo.unix")
local cosmo = require("cosmo")

--- Process resource usage statistics.
--- Contains CPU time, memory usage, I/O, and context switch counters.
local record Rusage
  utime: function(self: Rusage): number, number
  stime: function(self: Rusage): number, number
  maxrss: function(self: Rusage): number
  idrss: function(self: Rusage): number
  ixrss: function(self: Rusage): number
  isrss: function(self: Rusage): number
  minflt: function(self: Rusage): number
  majflt: function(self: Rusage): number
  nswap: function(self: Rusage): number
  inblock: function(self: Rusage): number
  oublock: function(self: Rusage): number
  msgsnd: function(self: Rusage): number
  msgrcv: function(self: Rusage): number
  nsignals: function(self: Rusage): number
  nvcsw: function(self: Rusage): number
  nivcsw: function(self: Rusage): number
end

--- Error information from system calls.
--- Provides detailed error codes and human-readable descriptions.
local record Errno
  errno: function(self: Errno): number
  winerr: function(self: Errno): number
  name: function(self: Errno): string
  call: function(self: Errno): string
  doc: function(self: Errno): string
end

-- Identity --

--- Returns process id of current process.
--- This function does not fail.
--- @return number The current process id
local function getpid(): number
  return unix.getpid()
end

--- Returns process id of parent process.
--- This function does not fail.
--- @return number The parent process id
local function getppid(): number
  return unix.getppid()
end

-- Session & Group --

--- Gets session id for a process.
--- @param pid number The process id to query
--- @return number The session id
local function getsid(pid: number): number
  return unix.getsid(pid)
end

--- Gets process group id of calling process.
--- @return number The process group id
local function getpgrp(): number
  return unix.getpgrp()
end

--- Gets process group id for a specific process.
--- @param pid number The process id to query
--- @return number The process group id
local function getpgid(pid: number): number
  return unix.getpgid(pid)
end

--- Sets process group id (same as setpgid(0, 0)).
--- @return number The new process group id
local function setpgrp(): number
  return unix.setpgrp()
end

--- Sets process group id.
--- @param pid number Process id (0 means calling process)
--- @param pgid number Process group id (0 means use pid as pgid)
--- @return boolean True on success
local function setpgid(pid: number, pgid: number): boolean
  return unix.setpgid(pid, pgid)
end

--- Creates a new session.
--- The calling process becomes the session leader and process group leader.
--- Used for creating daemons.
--- Fails with ENOSYS on Windows NT.
--- @return number The new session id
local function setsid(): number
  return unix.setsid()
end

--- Daemonizes the current process.
--- Performs standard Unix daemonization: fork, setsid, redirect I/O.
--- @param nochdir boolean? If true, don't change to root directory (default: false)
--- @param noclose boolean? If true, don't redirect stdin/stdout/stderr (default: false)
--- @return boolean True on success
local function daemon(nochdir?: boolean, noclose?: boolean): boolean
  return unix.daemon(nochdir, noclose)
end

-- Signals --

--- Sends signal to process(es).
--- @param pid number Process id to signal. Negative values target process groups
--- @param sig number Signal number (e.g., SIGTERM, SIGKILL)
--- @return boolean True on success
local function kill(pid: number, sig: number): boolean
  return unix.kill(pid, sig)
end

--- Sends signal to process group.
--- @param pgrp number Process group id. If 0, sends to calling process's group
--- @param sig number Signal number
--- @return boolean True on success
local function killpg(pgrp: number, sig: number): boolean
  return unix.killpg(pgrp, sig)
end

--- Sends signal to current process.
--- Equivalent to kill(getpid(), sig).
--- @param sig number Signal number to raise
--- @return number 0 on success
local function raise(sig: number): number
  return unix.raise(sig)
end

-- Termination --

--- Terminates the current process immediately.
--- Memory is freed, file descriptors are closed, connections are reset.
--- This function never returns.
--- @param exitcode number? Exit code (defaults to 0)
local function exit(exitcode?: number)
  unix.exit(exitcode)
end

-- Exec (replace current process) --

--- Performs $PATH lookup of executable.
--- Returns the absolute path to the executable if found, nil otherwise.
--- On Windows, programs should be installed without .exe/.com suffix for discovery.
--- @param prog string The program name to search for
--- @return string? The absolute path to the executable, or nil if not found
local function commandv(prog: string): string
  return unix.commandv(prog)
end

--- Replaces current process with new program.
--- prog must be an absolute path (use commandv for PATH search).
--- This function never returns on success.
--- @param prog string Absolute path to the executable
--- @param args {string} Argument vector passed to the program
--- @param env {string} Environment variables (KEY=value format)
--- @return nil, Errno Only returns on error
local function execve(prog: string, args: {string}, env: {string}): nil, Errno
  local _, err = unix.execve(prog, args, env)
  return nil, err as Errno
end

--- Executes program with PATH search.
--- Unlike execve(), this searches for prog in $PATH.
--- This function never returns on success.
--- @param prog string The program name to execute
--- @param argv {string}? Argument vector. Defaults to {prog}
--- @return nil, Errno Only returns on error
local function execvp(prog: string, argv?: {string}): nil, Errno
  local _, err = unix.execvp(prog, argv)
  return nil, err as Errno
end

--- Executes program with PATH search and custom environment.
--- Like execvp() but also allows specifying a custom environment.
--- This function never returns on success.
--- @param prog string The program name to execute
--- @param argv {string} Argument vector passed to the program
--- @param envp {string}? Environment variables. Inherits if not specified
--- @return nil, Errno Only returns on error
local function execvpe(prog: string, argv: {string}, envp?: {string}): nil, Errno
  local _, err = unix.execvpe(prog, argv, envp)
  return nil, err as Errno
end

--- Executes program from file descriptor.
--- Allows executing a program that has already been opened.
--- This function never returns on success.
--- @param fd number Open file descriptor pointing to an executable
--- @param argv {string} Argument vector passed to the program
--- @param envp {string}? Environment variables. Inherits if not specified
--- @return nil, Errno Only returns on error
local function fexecve(fd: number, argv: {string}, envp?: {string}): nil, Errno
  local _, err = unix.fexecve(fd, argv, envp)
  return nil, err as Errno
end

-- Resource Usage --

--- Gets resource usage statistics.
--- @param who number? Who to query: RUSAGE_SELF (default), RUSAGE_CHILDREN, RUSAGE_THREAD, RUSAGE_BOTH
--- @return Rusage Resource usage statistics
local function getrusage(who?: number): Rusage
  return unix.getrusage(who) as Rusage
end

-- Resource Limits --

--- Gets resource limits for the current process.
--- Returns the soft and hard limits for the specified resource.
--- @param resource number The RLIMIT_* constant identifying the resource
--- @return number Soft limit (can be exceeded, may generate signal)
--- @return number Hard limit (cannot be exceeded by unprivileged processes)
local function getrlimit(resource: number): number, number
  return unix.getrlimit(resource)
end

--- Sets resource limits for the current process.
--- The soft limit can be raised up to the hard limit.
--- Only privileged processes can raise the hard limit.
--- @param resource number The RLIMIT_* constant identifying the resource
--- @param soft number New soft limit
--- @param hard number? New hard limit (defaults to soft if not provided)
--- @return boolean True on success
--- @return string? Error message on failure
local function setrlimit(resource: number, soft: number, hard?: number): boolean, string
  local ok, err = unix.setrlimit(resource, soft, hard) as (boolean, any)
  if not ok then
    if err then
      local errno = err as Errno
      if errno.doc then
        return false, errno:doc()
      end
      return false, tostring(err)
    end
    return false, "setrlimit failed"
  end
  return true
end

-- Process Priority --

--- Adjusts the nice value (scheduling priority) of the calling process.
--- The nice value ranges from -20 (highest priority) to 19 (lowest priority).
--- Only privileged processes can lower the nice value (increase priority).
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
--- @return string? Error message on failure
local function setpriority(which: number, who: number, prio: number): boolean, string
  local ok, err = unix.setpriority(which, who, prio) as (boolean, any)
  if not ok then
    if err then
      local errno = err as Errno
      if errno.doc then
        return false, errno:doc()
      end
      return false, tostring(err)
    end
    return false, "setpriority failed"
  end
  return true
end

-- Scheduling --

--- Relinquishes the CPU, allowing other processes to run.
--- Causes the calling thread to yield its scheduled time quantum.
local function sched_yield()
  unix.sched_yield()
end

-- Script Detection --

--- Returns true if current script is being run as the main program.
--- Returns false if the script is being loaded as a module via require().
--- Use this to guard code that should only run when executed directly.
--- @return boolean True if running as main script
local function is_main(): boolean
  return cosmo.is_main()
end

local record ProcModule
  -- Identity
  getpid: function(): number
  getppid: function(): number

  -- Session & Group
  getsid: function(pid: number): number
  getpgrp: function(): number
  getpgid: function(pid: number): number
  setpgrp: function(): number
  setpgid: function(pid: number, pgid: number): boolean
  setsid: function(): number
  daemon: function(nochdir?: boolean, noclose?: boolean): boolean

  -- Signals
  kill: function(pid: number, sig: number): boolean
  killpg: function(pgrp: number, sig: number): boolean
  raise: function(sig: number): number

  -- Termination
  exit: function(exitcode?: number)

  -- Exec
  commandv: function(prog: string): string
  execve: function(prog: string, args: {string}, env: {string}): nil, Errno
  execvp: function(prog: string, argv?: {string}): nil, Errno
  execvpe: function(prog: string, argv: {string}, envp?: {string}): nil, Errno
  fexecve: function(fd: number, argv: {string}, envp?: {string}): nil, Errno

  -- Resource usage
  getrusage: function(who?: number): Rusage

  -- Resource limits
  getrlimit: function(resource: number): number, number
  setrlimit: function(resource: number, soft: number, hard?: number): boolean, string

  -- Priority
  nice: function(inc: number): number
  getpriority: function(which: number, who: number): number
  setpriority: function(which: number, who: number, prio: number): boolean, string

  -- Scheduling
  sched_yield: function()

  -- Script detection
  is_main: function(): boolean

  -- Rusage constants
  RUSAGE_SELF: number
  RUSAGE_CHILDREN: number
  RUSAGE_THREAD: number
  RUSAGE_BOTH: number

  -- Signal constants
  SIGTERM: number
  SIGKILL: number
  SIGINT: number
  SIGQUIT: number
  SIGHUP: number
  SIGCHLD: number
  SIGSTOP: number
  SIGCONT: number
  SIGUSR1: number
  SIGUSR2: number
  SIGPIPE: number
  SIGALRM: number

  -- Resource limit constants
  RLIMIT_AS: number
  RLIMIT_CPU: number
  RLIMIT_FSIZE: number
  RLIMIT_NOFILE: number
  RLIMIT_NPROC: number
  RLIMIT_RSS: number

  -- Priority scope constants
  PRIO_PROCESS: number
  PRIO_PGRP: number
  PRIO_USER: number
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

  -- Signals
  kill = kill,
  killpg = killpg,
  raise = raise,

  -- Termination
  exit = exit,

  -- Exec
  commandv = commandv,
  execve = execve,
  execvp = execvp,
  execvpe = execvpe,
  fexecve = fexecve,

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

  -- Signal constants
  SIGTERM = unix.SIGTERM,
  SIGKILL = unix.SIGKILL,
  SIGINT = unix.SIGINT,
  SIGQUIT = unix.SIGQUIT,
  SIGHUP = unix.SIGHUP,
  SIGCHLD = unix.SIGCHLD,
  SIGSTOP = unix.SIGSTOP,
  SIGCONT = unix.SIGCONT,
  SIGUSR1 = unix.SIGUSR1,
  SIGUSR2 = unix.SIGUSR2,
  SIGPIPE = unix.SIGPIPE,
  SIGALRM = unix.SIGALRM,

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
}

return M
