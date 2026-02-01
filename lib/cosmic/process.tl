--- Process management utilities.
--- Wraps cosmo.unix process-related functions for process lifecycle management.
--- Includes process creation, control, identity, status inspection, and resource usage.
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

-- Process Creation --

--- Performs $PATH lookup of executable.
--- Returns the absolute path to the executable if found, nil otherwise.
--- On Windows, programs should be installed without .exe/.com suffix for discovery.
--- @param prog string The program name to search for
--- @return string? The absolute path to the executable, or nil if not found
local function commandv(prog: string): string
  return unix.commandv(prog)
end

--- Creates a new process (fork).
--- Returns twice: parent gets child's pid (> 0), child gets 0.
--- This is the Unix mitosis-style process creation.
--- @return number The child process id in parent, 0 in child
local function fork(): number
  return unix.fork()
end

--- Spawns a new process using posix_spawn.
--- More efficient than fork() + execve() on some systems.
--- @param prog string Absolute path to the executable
--- @param argv {string} Argument vector passed to the program
--- @param envp {string}? Environment variables (KEY=value format). Inherits if not specified
--- @return number The child process id on success
local function spawn(prog: string, argv: {string}, envp?: {string}): number
  return unix.spawn(prog, argv, envp)
end

--- Spawns a new process with PATH search.
--- Like spawn() but searches for prog in $PATH directories.
--- @param prog string The program name to execute
--- @param argv {string} Argument vector passed to the program
--- @param envp {string}? Environment variables. Inherits if not specified
--- @return number The child process id on success
local function spawnp(prog: string, argv: {string}, envp?: {string}): number
  return unix.spawnp(prog, argv, envp)
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

-- Process Control --

--- Waits for child process to terminate.
--- @param pid number? Process id to wait for. -1 waits for any child (default)
--- @param options number? Wait options (e.g., WNOHANG for non-blocking)
--- @return number The child process id that terminated
--- @return number Status code (use WIFEXITED, WEXITSTATUS, etc. to interpret)
--- @return Rusage Resource usage statistics
local function wait(pid?: number, options?: number): number, number, Rusage
  local wpid, status, rusage = unix.wait(pid, options)
  return wpid, status, rusage as Rusage
end

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

--- Terminates the current process immediately.
--- Memory is freed, file descriptors are closed, connections are reset.
--- This function never returns.
--- @param exitcode number? Exit code (defaults to 0)
local function exit(exitcode?: number)
  unix.exit(exitcode)
end

-- Process Identity & Management --

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

-- Status Helpers --

--- Returns true if process exited normally (via exit() or return from main).
--- @param wstatus number Status code from wait()
--- @return boolean True if process exited cleanly
local function WIFEXITED(wstatus: number): boolean
  return unix.WIFEXITED(wstatus)
end

--- Returns the exit code passed to exit().
--- Only valid if WIFEXITED(wstatus) is true.
--- @param wstatus number Status code from wait()
--- @return number The exit code
local function WEXITSTATUS(wstatus: number): number
  return unix.WEXITSTATUS(wstatus)
end

--- Returns true if process was terminated by a signal.
--- @param wstatus number Status code from wait()
--- @return boolean True if terminated by signal
local function WIFSIGNALED(wstatus: number): boolean
  return unix.WIFSIGNALED(wstatus)
end

--- Returns the signal number that terminated the process.
--- Only valid if WIFSIGNALED(wstatus) is true.
--- @param wstatus number Status code from wait()
--- @return number The signal number
local function WTERMSIG(wstatus: number): number
  return unix.WTERMSIG(wstatus)
end

-- Resource Usage --

--- Gets resource usage statistics.
--- @param who number? Who to query: RUSAGE_SELF (default), RUSAGE_CHILDREN, RUSAGE_THREAD, RUSAGE_BOTH
--- @return Rusage Resource usage statistics
local function getrusage(who?: number): Rusage
  return unix.getrusage(who) as Rusage
end

-- Script Detection --

--- Returns true if current script is being run as the main program.
--- Returns false if the script is being loaded as a module via require().
--- Use this to guard code that should only run when executed directly.
--- @return boolean True if running as main script
local function is_main(): boolean
  return cosmo.is_main()
end

local record ProcessModule
  -- Process creation
  commandv: function(prog: string): string
  fork: function(): number
  spawn: function(prog: string, argv: {string}, envp?: {string}): number
  spawnp: function(prog: string, argv: {string}, envp?: {string}): number
  execve: function(prog: string, args: {string}, env: {string}): nil, Errno
  execvp: function(prog: string, argv?: {string}): nil, Errno
  execvpe: function(prog: string, argv: {string}, envp?: {string}): nil, Errno
  fexecve: function(fd: number, argv: {string}, envp?: {string}): nil, Errno

  -- Process control
  wait: function(pid?: number, options?: number): number, number, Rusage
  kill: function(pid: number, sig: number): boolean
  killpg: function(pgrp: number, sig: number): boolean
  raise: function(sig: number): number
  exit: function(exitcode?: number)

  -- Process identity
  getpid: function(): number
  getppid: function(): number
  getsid: function(pid: number): number
  getpgrp: function(): number
  getpgid: function(pid: number): number
  setpgrp: function(): number
  setpgid: function(pid: number, pgid: number): boolean
  setsid: function(): number
  daemon: function(nochdir?: boolean, noclose?: boolean): boolean

  -- Status helpers
  WIFEXITED: function(wstatus: number): boolean
  WEXITSTATUS: function(wstatus: number): number
  WIFSIGNALED: function(wstatus: number): boolean
  WTERMSIG: function(wstatus: number): number

  -- Resource usage
  getrusage: function(who?: number): Rusage

  -- Script detection
  is_main: function(): boolean

  -- Wait options
  WNOHANG: number
  WUNTRACED: number
  WCONTINUED: number

  -- Rusage constants
  RUSAGE_SELF: number
  RUSAGE_CHILDREN: number
  RUSAGE_THREAD: number
  RUSAGE_BOTH: number

  -- Common signals
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
end

local M: ProcessModule = {
  -- Process creation
  commandv = commandv,
  fork = fork,
  spawn = spawn,
  spawnp = spawnp,
  execve = execve,
  execvp = execvp,
  execvpe = execvpe,
  fexecve = fexecve,

  -- Process control
  wait = wait,
  kill = kill,
  killpg = killpg,
  raise = raise,
  exit = exit,

  -- Process identity
  getpid = getpid,
  getppid = getppid,
  getsid = getsid,
  getpgrp = getpgrp,
  getpgid = getpgid,
  setpgrp = setpgrp,
  setpgid = setpgid,
  setsid = setsid,
  daemon = daemon,

  -- Status helpers
  WIFEXITED = WIFEXITED,
  WEXITSTATUS = WEXITSTATUS,
  WIFSIGNALED = WIFSIGNALED,
  WTERMSIG = WTERMSIG,

  -- Resource usage
  getrusage = getrusage,

  -- Script detection
  is_main = is_main,

  -- Wait options
  WNOHANG = unix.WNOHANG,
  WUNTRACED = unix.WUNTRACED,
  WCONTINUED = unix.WCONTINUED,

  -- Rusage constants
  RUSAGE_SELF = unix.RUSAGE_SELF,
  RUSAGE_CHILDREN = unix.RUSAGE_CHILDREN,
  RUSAGE_THREAD = unix.RUSAGE_THREAD,
  RUSAGE_BOTH = unix.RUSAGE_BOTH,

  -- Common signals
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
}

return M
