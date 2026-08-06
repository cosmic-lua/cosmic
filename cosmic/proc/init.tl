--- Current process management.
--- Identity, session/group control, exec, and resource usage.
---
--- The global `arg` table layout when running a script: arg[-1] is the
--- cosmic interpreter binary's path (use interpreter() to reach it
--- typed and resolved); arg[0] is the script path as the runtime sees
--- it (/zip/main.lua when dispatched by the embedded entry point — NOT
--- the interpreter path); arg[1..] are user arguments.
local unix = require("cosmo.unix")
local cosmo = require("cosmo")
local errstr = require("cosmic.errno").wrap
local fs_path = require("cosmic.fs.path")

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

--- Performs $PATH lookup of executable (which(1)).
--- On Windows, programs should be installed without .exe/.com suffix for discovery.
--- @param prog string The program name to search for
--- @return string | nil The absolute path to the executable
--- @return string | nil Error message when not found (names the errno, so
--- not-found and permission-denied are distinguishable)
local function which(prog: string): string | nil, string
  local p, err = unix.commandv(prog)
  if not p then
    return nil, errstr(err, "which")
  end
  return p
end

--- Resolved-interpreter cache: argv0 is resolved against the cwd (and
--- $PATH) of the FIRST call, so a program that chdirs should call
--- interpreter() before doing so when it was started via a relative path.
local interpreter_path: string | nil = nil

--- Absolute path of the running cosmic interpreter — for re-invoking it
--- to run another script as a child: `child.start({proc.interpreter(),
--- "worker.tl"})`. This is `arg[-1]` resolved, NOT `arg[0]` (the script
--- path as the runtime sees it, `/zip/main.lua` in a packed binary). A
--- bare PATH-invoked argv0 (`cosmic`, the shebang shape) is resolved
--- with a real $PATH search. The result is cached across calls.
--- @return string | nil The interpreter's absolute path
--- @return string? Error message when argv0 is missing or unresolvable
local function interpreter(): string | nil, string
  if interpreter_path then
    return interpreter_path
  end
  local argv0 = rawget(arg, -1)
  if argv0 == nil or argv0 == "" then
    return nil, "interpreter: arg[-1] is not set"
  end
  local abs = fs_path.abspath(argv0)
  if fs_path.is_file(abs) then
    interpreter_path = abs
    return abs
  end
  -- A bare name found on $PATH (which() reports the errno when not).
  local found, err = which(argv0)
  if not found then
    return nil, "interpreter: cannot resolve '" .. argv0 .. "': " .. tostring(err)
  end
  interpreter_path = found
  return found
end

--- Replaces current process with new program; never returns on success.
--- prog must be an absolute path (use which() for PATH search).
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
--- @return integer | nil The child pid in the parent, 0 in the child, or nil + error on failure
local function fork(): integer | nil, string
  local pid, err = unix.fork(); if pid == nil then return nil, errstr(err, "fork") end
  return pid
end

--- Spawns a program via posix_spawn (no PATH search).
--- @param prog string Absolute path to the executable
--- @param argv {string} Argument vector passed to the program
--- @param envp {string}? Environment (KEY=value); inherits if omitted
--- @return integer | nil The child pid on success, or nil + error on failure
local function posix_spawn(prog: string, argv: {string}, envp?: {string}): integer | nil, string
  local pid, err = unix.spawn(prog, argv, envp); if pid == nil then return nil, errstr(err, "posix_spawn: " .. prog) end
  return pid
end

--- Spawns a program via posix_spawnp (PATH search).
--- @param prog string Program name to execute
--- @param argv {string} Argument vector passed to the program
--- @param envp {string}? Environment (KEY=value); inherits if omitted
--- @return integer | nil The child pid on success, or nil + error on failure
local function posix_spawnp(prog: string, argv: {string}, envp?: {string}): integer | nil, string
  local pid, err = unix.spawnp(prog, argv, envp); if pid == nil then return nil, errstr(err, "posix_spawnp: " .. prog) end
  return pid
end

--- Waits for a child process to change state.
--- A raw passthrough: EINTR surfaces here, unlike child.Handle:wait.
--- @param pid integer? Child pid to wait for (-1 or nil for any child)
--- @param options integer? Wait options (e.g. WNOHANG)
--- @return integer | nil The pid that changed state (0 with WNOHANG if none), or nil on failure
--- @return integer Status word (interpret with WIFEXITED/WEXITSTATUS/...)
--- @return Rusage Resource usage for the reaped child
--- @return string? Error message on failure
--- What wait(2) reaped. A record rather than (pid, status, rusage,
--- err) returns: the old shape put the error in slot 4, unreachable
--- from `local pid, err = ...` and from check.must.
local record WaitResult
  pid: integer
  --- Raw status word; decode with WIFEXITED/WEXITSTATUS/WIFSIGNALED/WTERMSIG.
  status: integer
  rusage: Rusage
end

local function wait(pid?: integer, options?: integer): WaitResult | nil, string
  local wpid, status, rusage = unix.wait(pid, options)
  if wpid == nil then
    -- On failure the binding returns (nil, err, errno): the error string
    -- arrives in the second slot, where the status word would have been.
    return nil, errstr(status, "wait")
  end
  return {pid = wpid, status = status, rusage = rusage}
end

--- True if the child exited normally.
local WIFEXITED: function(status: integer): boolean = unix.WIFEXITED

--- The exit code (valid when WIFEXITED is true).
local WEXITSTATUS: function(status: integer): integer = unix.WEXITSTATUS

--- True if the child was terminated by a signal.
local WIFSIGNALED: function(status: integer): boolean = unix.WIFSIGNALED

--- The terminating signal number (valid when WIFSIGNALED is true).
local WTERMSIG: function(status: integer): integer = unix.WTERMSIG

-- Resource usage, limits and priority live in cosmic.proc.rusage
-- (an internal shard; the public surface is unchanged).
local rusage_mod = require("cosmic.proc.rusage")

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
  --- getrusage's result record, re-exported so callers can name it
  --- without requiring cosmo.unix (which examples/tests must not).
  type Rusage = Rusage

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
  interpreter: function(): string | nil, string
  which: function(prog: string): string | nil, string
  execve: function(prog: string, args: {string}, env: {string}): nil, string
  execvp: function(prog: string, argv?: {string}): nil, string
  execvpe: function(prog: string, argv: {string}, envp?: {string}): nil, string
  fexecve: function(fd: integer, argv: {string}, envp?: {string}): nil, string

  -- Process control (children)
  fork: function(): integer | nil, string
  posix_spawn: function(prog: string, argv: {string}, envp?: {string}): integer | nil, string
  posix_spawnp: function(prog: string, argv: {string}, envp?: {string}): integer | nil, string
  type WaitResult = WaitResult
  wait: function(pid?: integer, options?: integer): WaitResult | nil, string
  WIFEXITED: function(status: integer): boolean
  WEXITSTATUS: function(status: integer): integer
  WIFSIGNALED: function(status: integer): boolean
  WTERMSIG: function(status: integer): integer

  -- Resource usage
  getrusage: function(who?: integer): Rusage | nil, string

  -- Resource limits
  type Rlimit = rusage_mod.Rlimit
  getrlimit: function(resource: integer): rusage_mod.Rlimit | nil, string
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
  interpreter = interpreter,
  which = which,
  execve = execve,
  execvp = execvp,
  execvpe = execvpe,
  fexecve = fexecve,

  -- Process control (children)
  fork = fork,
  posix_spawn = posix_spawn,
  posix_spawnp = posix_spawnp,
  wait = wait,
  WIFEXITED = WIFEXITED,
  WEXITSTATUS = WEXITSTATUS,
  WIFSIGNALED = WIFSIGNALED,
  WTERMSIG = WTERMSIG,

  -- Resource usage
  getrusage = rusage_mod.getrusage,

  -- Resource limits
  getrlimit = rusage_mod.getrlimit,
  setrlimit = rusage_mod.setrlimit,

  -- Priority
  nice = rusage_mod.nice,
  getpriority = rusage_mod.getpriority,
  setpriority = rusage_mod.setpriority,

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
