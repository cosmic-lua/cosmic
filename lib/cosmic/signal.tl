--- Signal handling utilities.
--- Wraps cosmo.unix signal functions for process signaling, handlers, and timers.
local unix = require("cosmo.unix")
local errstr = require("cosmic.errno").str

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
  SIGFPE: number
  SIGHUP: number
  SIGILL: number
  SIGINT: number
  SIGKILL: number
  SIGPIPE: number
  SIGPROF: number
  SIGQUIT: number
  SIGSEGV: number
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
  --- Returns the previous handler, flags, and mask; on failure returns
  --- nil, nil, nil plus an error message.
  sigaction: function(sig: number, handler?: function | number, flags?: number, mask?: Sigset): function | number, number, Sigset, string

  --- Modify the process signal mask.
  --- how: SIG_BLOCK, SIG_UNBLOCK, or SIG_SETMASK
  --- Returns the previous signal mask, or nil plus an error message.
  sigprocmask: function(how: number, set: Sigset): Sigset | nil, string

  --- Suspend the process until a signal is delivered.
  --- Temporarily replaces the signal mask with the provided mask.
  --- Always returns nil plus an error message: EINTR once a signal
  --- was delivered and handled, or another errno on failure.
  sigsuspend: function(mask?: Sigset): nil, string

  --- Schedule SIGALRM signals at intervals.
  --- Accepts a SetitimerOpts record with named fields for clarity.
  --- Returns a SetitimerResult with the previous timer values, or
  --- nil plus an error message.
  setitimer: function(opts: SetitimerOpts): SetitimerResult | nil, string

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
  local ok, err = unix.kill(pid, sig)
  if not ok then
    return false, errstr(err, "kill")
  end
  return true
end

--- Send a signal to a process group.
--- @param pgrp number The process group ID
--- @param sig number The signal to send
--- @return boolean True on success
--- @return string? Error message on failure
local function killpg(pgrp: number, sig: number): boolean, string
  local ok, err = unix.killpg(pgrp, sig)
  if not ok then
    return false, errstr(err, "killpg")
  end
  return true
end

--- Send a signal to the current process.
--- Equivalent to kill(getpid(), sig).
--- @param sig number The signal to send
--- @return boolean True on success
--- @return string? Error message on failure
local function raise(sig: number): boolean, string
  local rc, err = unix.raise(sig)
  if rc == nil then
    return false, errstr(err, "raise")
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
--- Returns a SetitimerResult with previous timer values, or nil plus
--- an error message on failure.
local function setitimer(opts: SetitimerOpts): SetitimerResult | nil, string
  local old_isec, old_ins, old_vsec, old_vns = unix.setitimer(
    opts.which,
    opts.intervalsec or 0,
    opts.intervalns or 0,
    opts.valuesec or 0,
    opts.valuens or 0
  )
  if old_isec == nil then
    -- On failure the binding returns (nil, err, errno): the error string
    -- arrives in the second slot.
    return nil, errstr(old_ins, "setitimer")
  end
  return {
    valuesec = old_vsec,
    valuens = old_vns,
    intervalsec = old_isec,
    intervalns = old_ins,
  }
end

-- The binding's Sigset is a distinct nominal record the generated
-- declarations do not export, so calls go through casts that mirror its
-- signature — but never ones that erase the error slots.
local raw_sigaction = unix.sigaction as function(sig: number, handler?: any, flags?: number, mask?: Sigset): (any, any, any)
local raw_sigprocmask = unix.sigprocmask as function(number, Sigset): (Sigset, any)
local raw_sigsuspend = unix.sigsuspend as function(Sigset): (any, any)

--- Register a signal handler for the specified signal.
--- @param sig number The signal to handle
--- @param handler function | number? Lua function, SIG_IGN, or SIG_DFL
--- @param flags number? sigaction flags (e.g. SA_RESTART)
--- @param mask Sigset? Signals to block during handler execution
--- @return function | number The previous handler, or nil on failure
--- @return number The previous flags
--- @return Sigset The previous mask
--- @return string? Error message on failure
-- handler and the first return are typed any here because the formatter
-- cannot parse a bare `function | number` union in a function statement;
-- the SignalModule record above carries the precise public type.
local function sigaction(sig: number, handler?: any, flags?: number, mask?: Sigset): any, number, Sigset, string
  -- Never pass explicit trailing nils: the binding leaves nil-valued
  -- stack slots 3/4 in place, which shifts the stack index it later uses
  -- to store a Lua handler in its registry table — the handler would be
  -- registered as nil and never dispatched.
  local prev, prev_flags, prev_mask: any, any, any
  if mask ~= nil then
    prev, prev_flags, prev_mask = raw_sigaction(sig, handler, flags or 0, mask)
  elseif flags ~= nil then
    prev, prev_flags, prev_mask = raw_sigaction(sig, handler, flags)
  elseif handler ~= nil then
    prev, prev_flags, prev_mask = raw_sigaction(sig, handler)
  else
    prev, prev_flags, prev_mask = raw_sigaction(sig)
  end
  if prev == nil then
    -- On failure the binding returns (nil, err, errno): the error string
    -- arrives in the second slot.
    return nil, nil, nil, errstr(prev_flags, "sigaction")
  end
  return prev, prev_flags as number, prev_mask as Sigset
end

--- Modify the process signal mask.
--- @param how number SIG_BLOCK, SIG_UNBLOCK, or SIG_SETMASK
--- @param set Sigset The signal set to apply
--- @return Sigset | nil The previous signal mask, or nil on failure
--- @return string? Error message on failure
local function sigprocmask(how: number, set: Sigset): Sigset | nil, string
  local old, err = raw_sigprocmask(how, set)
  if old == nil then
    return nil, errstr(err, "sigprocmask")
  end
  return old
end

--- Suspend the process until a signal is delivered.
--- @param mask Sigset? Temporary signal mask while suspended
--- @return nil Always nil (sigsuspend only returns after a signal)
--- @return string Error message: EINTR after a signal was handled
local function sigsuspend(mask?: Sigset): nil, string
  local _, err = raw_sigsuspend(mask)
  return nil, errstr(err, "sigsuspend")
end

local M = {} as SignalModule

M.Sigset = unix.Sigset as function(...: number): Sigset
M.sigaction = sigaction
M.sigprocmask = sigprocmask
M.sigsuspend = sigsuspend
M.setitimer = setitimer

-- Delivery functions
M.kill = kill
M.killpg = killpg
M.raise = raise

-- Utilities
M.strsignal = strsignal

-- Signal constants
M.SIGABRT = unix.SIGABRT
M.SIGALRM = unix.SIGALRM
M.SIGBUS = unix.SIGBUS
M.SIGCHLD = unix.SIGCHLD
M.SIGCONT = unix.SIGCONT
M.SIGFPE = unix.SIGFPE
M.SIGHUP = unix.SIGHUP
M.SIGILL = unix.SIGILL
M.SIGINT = unix.SIGINT
M.SIGKILL = unix.SIGKILL
M.SIGPIPE = unix.SIGPIPE
M.SIGPROF = unix.SIGPROF
M.SIGQUIT = unix.SIGQUIT
M.SIGSEGV = unix.SIGSEGV
M.SIGSTOP = unix.SIGSTOP
M.SIGSYS = unix.SIGSYS
M.SIGTERM = unix.SIGTERM
M.SIGTRAP = unix.SIGTRAP
M.SIGTSTP = unix.SIGTSTP
M.SIGTTIN = unix.SIGTTIN
M.SIGTTOU = unix.SIGTTOU
M.SIGURG = unix.SIGURG
M.SIGUSR1 = unix.SIGUSR1
M.SIGUSR2 = unix.SIGUSR2
M.SIGVTALRM = unix.SIGVTALRM
M.SIGWINCH = unix.SIGWINCH
M.SIGXCPU = unix.SIGXCPU
M.SIGXFSZ = unix.SIGXFSZ

-- Signal mask operations
M.SIG_BLOCK = unix.SIG_BLOCK
M.SIG_UNBLOCK = unix.SIG_UNBLOCK
M.SIG_SETMASK = unix.SIG_SETMASK

-- Default/ignore handlers
M.SIG_DFL = unix.SIG_DFL
M.SIG_IGN = unix.SIG_IGN

-- sigaction flags
M.SA_NOCLDSTOP = unix.SA_NOCLDSTOP
M.SA_NOCLDWAIT = unix.SA_NOCLDWAIT
M.SA_NODEFER = unix.SA_NODEFER
M.SA_RESETHAND = unix.SA_RESETHAND
M.SA_RESTART = unix.SA_RESTART

-- Timer types
M.ITIMER_REAL = unix.ITIMER_REAL
M.ITIMER_VIRTUAL = unix.ITIMER_VIRTUAL
M.ITIMER_PROF = unix.ITIMER_PROF

return M
