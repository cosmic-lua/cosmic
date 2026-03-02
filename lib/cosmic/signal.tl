--- Signal handling utilities.
--- Wraps cosmo.unix signal functions for process signaling, handlers, and timers.
local unix = require("cosmo.unix")
local Errno = require("cosmic.errno").Errno

--- Options for setitimer: specifies which timer, initial fire time, and repeat interval.
local record SetitimerOpts
  which: number
  valuesec: number
  valuens: number
  intervalsec: number
  intervalns: number
end

--- Result from setitimer: previous timer values.
local record SetitimerResult
  valuesec: number
  valuens: number
  intervalsec: number
  intervalns: number
end

--- Signal set for blocking, unblocking, and waiting on signals.
--- Wraps unix.Sigset for use with sigprocmask, sigaction, and sigsuspend.
local record Sigset
  --- Adds signal to bitset.
  add: function(self: Sigset, sig: number)
  --- Removes signal from bitset.
  remove: function(self: Sigset, sig: number)
  --- Sets all bits in signal bitset to true.
  fill: function(self: Sigset)
  --- Sets all bits in signal bitset to false.
  clear: function(self: Sigset)
  --- Returns true if signal is in the bitset.
  contains: function(self: Sigset, sig: number): boolean
end

--- Signal handling module.
--- Provides signal constants, sigaction, sigprocmask, sigsuspend, and delivery functions.
local record SignalModule

  -- Signal constants
  SIGABRT: number
  SIGALRM: number
  SIGBUS: number
  SIGCHLD: number
  SIGCONT: number
  SIGEMT: number
  SIGFPE: number
  SIGHUP: number
  SIGILL: number
  SIGINFO: number
  SIGINT: number
  SIGIO: number
  SIGKILL: number
  SIGPIPE: number
  SIGPROF: number
  SIGPWR: number
  SIGQUIT: number
  SIGRTMAX: number
  SIGRTMIN: number
  SIGSEGV: number
  SIGSTKFLT: number
  SIGSTOP: number
  SIGSYS: number
  SIGTERM: number
  SIGTRAP: number
  SIGTSTP: number
  SIGTTIN: number
  SIGTTOU: number
  SIGURG: number
  SIGUSR1: number
  SIGUSR2: number
  SIGVTALRM: number
  SIGWINCH: number
  SIGXCPU: number
  SIGXFSZ: number

  -- Signal mask operations
  SIG_BLOCK: number
  SIG_UNBLOCK: number
  SIG_SETMASK: number

  -- Default/ignore handlers
  SIG_DFL: number
  SIG_IGN: number

  -- sigaction flags
  SA_NOCLDSTOP: number
  SA_NOCLDWAIT: number
  SA_NODEFER: number
  SA_RESETHAND: number
  SA_RESTART: number

  -- Timer types
  ITIMER_REAL: number
  ITIMER_VIRTUAL: number
  ITIMER_PROF: number

  --- Create a new signal set containing the specified signals.
  --- The returned Sigset has methods: add(sig), remove(sig), fill(), clear(), contains(sig).
  Sigset: function(...: number): Sigset

  --- Register a signal handler for the specified signal.
  --- The handler can be a Lua function, SIG_IGN, or SIG_DFL.
  --- Returns the previous handler, flags, and mask.
  sigaction: function(sig: number, handler?: function | number, flags?: number, mask?: Sigset): function | number, number, Sigset

  --- Modify the process signal mask.
  --- how: SIG_BLOCK, SIG_UNBLOCK, or SIG_SETMASK
  --- Returns the previous signal mask.
  sigprocmask: function(how: number, set: Sigset): Sigset

  --- Suspend the process until a signal is delivered.
  --- Temporarily replaces the signal mask with the provided mask.
  sigsuspend: function(mask: Sigset): boolean, Errno

  --- Schedule SIGALRM signals at intervals.
  --- Accepts a SetitimerOpts record with named fields for clarity.
  --- Returns a SetitimerResult with the previous timer values.
  setitimer: function(opts: SetitimerOpts): SetitimerResult

  --- Send a signal to a process.
  --- pid > 0 signals one process by id; 0 signals current group; -1 signals all.
  kill: function(pid: number, sig: number): boolean, string

  --- Send a signal to a process group.
  killpg: function(pgrp: number, sig: number): boolean, string

  --- Send a signal to the current process.
  raise: function(sig: number): boolean, string

  --- Get the name of a signal.
  strsignal: function(sig: number): string
end

--- Send a signal to a process.
--- @param pid number The process ID (>0 for specific process, 0 for process group, -1 for all)
--- @param sig number The signal to send
--- @return boolean True on success
--- @return string? Error message on failure
local function kill(pid: number, sig: number): boolean, string
  local ok, err = unix.kill(pid, sig) as(boolean, any)
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
  local ok, err = unix.killpg(pgrp, sig) as(boolean, any)
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

--- Set an interval timer with opts record for clarity.
--- Calls raw unix.setitimer which expects C-order (interval first, value second).
--- Returns a SetitimerResult with previous timer values.
local function setitimer(opts: SetitimerOpts): SetitimerResult
  local old_isec, old_ins, old_vsec, old_vns = unix.setitimer(
    opts.which,
    opts.intervalsec or 0,
    opts.intervalns or 0,
    opts.valuesec or 0,
    opts.valuens or 0
  )
  return {
    valuesec = old_vsec,
    valuens = old_vns,
    intervalsec = old_isec,
    intervalns = old_ins,
  } as SetitimerResult
end

local M = {} as SignalModule

-- Re-export functions that use Sigset directly from unix
M.Sigset = unix.Sigset as function(...: number): Sigset
M.sigaction = unix.sigaction as function(sig: number, handler?: function | number, flags?: number, mask?: Sigset): (function | number, number, Sigset)
M.sigprocmask = unix.sigprocmask as function(how: number, set: Sigset): Sigset
M.sigsuspend = unix.sigsuspend as function(mask: Sigset): (boolean, Errno)
M.setitimer = setitimer

-- Delivery functions
M.kill = kill
M.killpg = killpg
M.raise = raise

-- Utilities
M.strsignal = strsignal

-- Signal constants
M.SIGABRT = unix.SIGABRT as number
M.SIGALRM = unix.SIGALRM as number
M.SIGBUS = unix.SIGBUS as number
M.SIGCHLD = unix.SIGCHLD as number
M.SIGCONT = unix.SIGCONT as number
M.SIGEMT = unix.SIGEMT as number
M.SIGFPE = unix.SIGFPE as number
M.SIGHUP = unix.SIGHUP as number
M.SIGILL = unix.SIGILL as number
M.SIGINFO = unix.SIGINFO as number
M.SIGINT = unix.SIGINT as number
M.SIGIO = unix.SIGIO as number
M.SIGKILL = unix.SIGKILL as number
M.SIGPIPE = unix.SIGPIPE as number
M.SIGPROF = unix.SIGPROF as number
M.SIGPWR = unix.SIGPWR as number
M.SIGQUIT = unix.SIGQUIT as number
M.SIGRTMAX = unix.SIGRTMAX as number
M.SIGRTMIN = unix.SIGRTMIN as number
M.SIGSEGV = unix.SIGSEGV as number
M.SIGSTKFLT = unix.SIGSTKFLT as number
M.SIGSTOP = unix.SIGSTOP as number
M.SIGSYS = unix.SIGSYS as number
M.SIGTERM = unix.SIGTERM as number
M.SIGTRAP = unix.SIGTRAP as number
M.SIGTSTP = unix.SIGTSTP as number
M.SIGTTIN = unix.SIGTTIN as number
M.SIGTTOU = unix.SIGTTOU as number
M.SIGURG = unix.SIGURG as number
M.SIGUSR1 = unix.SIGUSR1 as number
M.SIGUSR2 = unix.SIGUSR2 as number
M.SIGVTALRM = unix.SIGVTALRM as number
M.SIGWINCH = unix.SIGWINCH as number
M.SIGXCPU = unix.SIGXCPU as number
M.SIGXFSZ = unix.SIGXFSZ as number

-- Signal mask operations
M.SIG_BLOCK = unix.SIG_BLOCK as number
M.SIG_UNBLOCK = unix.SIG_UNBLOCK as number
M.SIG_SETMASK = unix.SIG_SETMASK as number

-- Default/ignore handlers
M.SIG_DFL = unix.SIG_DFL as number
M.SIG_IGN = unix.SIG_IGN as number

-- sigaction flags
M.SA_NOCLDSTOP = unix.SA_NOCLDSTOP as number
M.SA_NOCLDWAIT = unix.SA_NOCLDWAIT as number
M.SA_NODEFER = unix.SA_NODEFER as number
M.SA_RESETHAND = unix.SA_RESETHAND as number
M.SA_RESTART = unix.SA_RESTART as number

-- Timer types
M.ITIMER_REAL = unix.ITIMER_REAL as number
M.ITIMER_VIRTUAL = unix.ITIMER_VIRTUAL as number
M.ITIMER_PROF = unix.ITIMER_PROF as number

return M
