--- Signal handling utilities.
--- Wraps cosmo.unix signal functions for process signaling, handlers, and timers.
local unix = require("cosmo.unix")

local record Errno
  errno: function(self: Errno): number
  winerr: function(self: Errno): number
  name: function(self: Errno): string
  call: function(self: Errno): string
  doc: function(self: Errno): string
end

--- Send a signal to a process.
--- @param pid number The process ID (>0 for specific process, 0 for process group, -1 for all)
--- @param sig number The signal to send
--- @return boolean True on success
--- @return string? Error message on failure
local function kill(pid: number, sig: number): boolean, string
  local ok, err = unix.kill(pid, sig) as (boolean, any)
  if not ok then
    if err then
      local errno = err as Errno
      if errno.doc then
        return false, errno:doc()
      end
      return false, tostring(err)
    end
    return false, "kill failed"
  end
  return true
end

--- Send a signal to a process group.
--- @param pgrp number The process group ID
--- @param sig number The signal to send
--- @return boolean True on success
--- @return string? Error message on failure
local function killpg(pgrp: number, sig: number): boolean, string
  local ok, err = unix.killpg(pgrp, sig) as (boolean, any)
  if not ok then
    if err then
      local errno = err as Errno
      if errno.doc then
        return false, errno:doc()
      end
      return false, tostring(err)
    end
    return false, "killpg failed"
  end
  return true
end

--- Send a signal to the current process.
--- Equivalent to kill(getpid(), sig).
--- @param sig number The signal to send
--- @return boolean True on success
--- @return string? Error message on failure
local function raise(sig: number): boolean, string
  local result = unix.raise(sig) as number
  if result ~= 0 then
    return false, "raise failed"
  end
  return true
end

--- Get the name of a signal.
--- @param sig number The signal number
--- @return string The signal name (e.g., "SIGKILL")
local function strsignal(sig: number): string
  return unix.strsignal(sig)
end

-- Re-export functions that use Sigset directly from unix to preserve type compatibility
local M = {
  --- Create a new signal set containing the specified signals.
  --- The returned Sigset has methods: add(sig), remove(sig), fill(), clear(), contains(sig).
  Sigset = unix.Sigset,

  --- Register a signal handler for the specified signal.
  --- The handler can be a Lua function, SIG_IGN, or SIG_DFL.
  --- Returns the previous handler, flags, and mask.
  sigaction = unix.sigaction,

  --- Modify the process signal mask.
  --- how: SIG_BLOCK, SIG_UNBLOCK, or SIG_SETMASK
  --- mask: A Sigset object
  --- Returns the previous signal mask.
  sigprocmask = unix.sigprocmask,

  --- Suspend the process until a signal is delivered.
  --- Temporarily replaces the signal mask with the provided mask.
  sigsuspend = unix.sigsuspend,

  --- Schedule SIGALRM signals at intervals.
  --- which: ITIMER_REAL, ITIMER_VIRTUAL, or ITIMER_PROF
  setitimer = unix.setitimer,

  -- Delivery functions
  kill = kill,
  killpg = killpg,
  raise = raise,

  -- Utilities
  strsignal = strsignal,

  -- Signal constants
  SIGABRT = unix.SIGABRT,
  SIGALRM = unix.SIGALRM,
  SIGBUS = unix.SIGBUS,
  SIGCHLD = unix.SIGCHLD,
  SIGCONT = unix.SIGCONT,
  SIGEMT = unix.SIGEMT,
  SIGFPE = unix.SIGFPE,
  SIGHUP = unix.SIGHUP,
  SIGILL = unix.SIGILL,
  SIGINFO = unix.SIGINFO,
  SIGINT = unix.SIGINT,
  SIGIO = unix.SIGIO,
  SIGKILL = unix.SIGKILL,
  SIGPIPE = unix.SIGPIPE,
  SIGPROF = unix.SIGPROF,
  SIGPWR = unix.SIGPWR,
  SIGQUIT = unix.SIGQUIT,
  SIGRTMAX = unix.SIGRTMAX,
  SIGRTMIN = unix.SIGRTMIN,
  SIGSEGV = unix.SIGSEGV,
  SIGSTKFLT = unix.SIGSTKFLT,
  SIGSTOP = unix.SIGSTOP,
  SIGSYS = unix.SIGSYS,
  SIGTERM = unix.SIGTERM,
  SIGTRAP = unix.SIGTRAP,
  SIGTSTP = unix.SIGTSTP,
  SIGTTIN = unix.SIGTTIN,
  SIGTTOU = unix.SIGTTOU,
  SIGURG = unix.SIGURG,
  SIGUSR1 = unix.SIGUSR1,
  SIGUSR2 = unix.SIGUSR2,
  SIGVTALRM = unix.SIGVTALRM,
  SIGWINCH = unix.SIGWINCH,
  SIGXCPU = unix.SIGXCPU,
  SIGXFSZ = unix.SIGXFSZ,

  -- Signal mask operations
  SIG_BLOCK = unix.SIG_BLOCK,
  SIG_UNBLOCK = unix.SIG_UNBLOCK,
  SIG_SETMASK = unix.SIG_SETMASK,

  -- Default/ignore handlers
  SIG_DFL = unix.SIG_DFL,
  SIG_IGN = unix.SIG_IGN,

  -- sigaction flags
  SA_NOCLDSTOP = unix.SA_NOCLDSTOP,
  SA_NOCLDWAIT = unix.SA_NOCLDWAIT,
  SA_NODEFER = unix.SA_NODEFER,
  SA_RESETHAND = unix.SA_RESETHAND,
  SA_RESTART = unix.SA_RESTART,

  -- Timer types
  ITIMER_REAL = unix.ITIMER_REAL,
  ITIMER_VIRTUAL = unix.ITIMER_VIRTUAL,
  ITIMER_PROF = unix.ITIMER_PROF,
}

return M
