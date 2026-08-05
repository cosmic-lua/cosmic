--- Signal handling utilities.
--- Wraps cosmo.unix signal functions for process signaling, handlers, and timers.
local unix = require("cosmo.unix")
local errstr = require("cosmic.errno").wrap

--- Options for setitimer: which timer, initial fire time, repeat interval.
--- Durations are integer milliseconds (api-review-6: was four s+ns
--- fields); 0 value_ms disarms the timer, 0 interval_ms means one-shot.
local record SetitimerOptions
  which: integer
  value_ms: integer
  interval_ms: integer
end

--- Result from setitimer: the previous timer, in the same shape.
--- Sub-millisecond remainders round UP, so a still-armed timer never
--- reads as the 0 that would disarm it when passed back.
local record SetitimerResult
  value_ms: integer
  interval_ms: integer
end

--- Signal set for blocking, unblocking, and waiting on signals.
--- Wraps unix.Sigset for use with sigprocmask, sigaction, and sigsuspend.
--- This mirror is deliberate: the generated unix record cannot re-export
--- the Sigset record type because its `Sigset` name is taken by the
--- constructor function field there. Here the constructor is
--- `sigset(...)` (lowercase), so the TYPE name Sigset stays free to
--- export — a Teal record cannot hold a value field and a type alias
--- under one name.
local record Sigset
  --- Adds signal to bitset.
  add: function(self: Sigset, sig: integer)
  --- Removes signal from bitset.
  remove: function(self: Sigset, sig: integer)
  --- Sets all bits in signal bitset to true.
  fill: function(self: Sigset)
  --- Sets all bits in signal bitset to false.
  clear: function(self: Sigset)
  --- Returns true if signal is in the bitset.
  contains: function(self: Sigset, sig: integer): boolean
end

--- Signal handling module.
--- Provides signal constants, sigaction, sigprocmask, sigsuspend, and delivery functions.
--- The disposition sigaction replaced. A record rather than
--- (handler, flags, mask, err) returns: the old shape put the error in
--- slot 4, unreachable from `local prev, err = ...`. Restore with
--- `signal.sigaction(sig, prev.handler, prev.flags, prev.mask)`.
local record PrevAction
  --- The previous handler: a Lua function, or SIG_DFL/SIG_IGN.
  handler: function | integer
  flags: integer
  mask: Sigset
end

local record SignalModule

  -- Signal constants
  SIGABRT: integer
  SIGALRM: integer
  SIGBUS: integer
  SIGCHLD: integer
  SIGCONT: integer
  SIGFPE: integer
  SIGHUP: integer
  SIGILL: integer
  SIGINT: integer
  SIGKILL: integer
  SIGPIPE: integer
  SIGPROF: integer
  SIGQUIT: integer
  SIGSEGV: integer
  SIGSTOP: integer
  SIGSYS: integer
  SIGTERM: integer
  SIGTRAP: integer
  SIGTSTP: integer
  SIGTTIN: integer
  SIGTTOU: integer
  SIGURG: integer
  SIGUSR1: integer
  SIGUSR2: integer
  SIGVTALRM: integer
  SIGWINCH: integer
  SIGXCPU: integer
  SIGXFSZ: integer

  -- Signal mask operations
  SIG_BLOCK: integer
  SIG_UNBLOCK: integer
  SIG_SETMASK: integer

  -- Default/ignore handlers
  SIG_DFL: integer
  SIG_IGN: integer

  -- sigaction flags
  SA_NOCLDSTOP: integer
  SA_NOCLDWAIT: integer
  SA_NODEFER: integer
  SA_RESETHAND: integer
  SA_RESTART: integer

  -- Timer types
  ITIMER_REAL: integer
  ITIMER_VIRTUAL: integer
  ITIMER_PROF: integer

  --- The signal-set type, nameable as `signal.Sigset`.
  type Sigset = Sigset

  --- Create a new signal set containing the specified signals.
  --- The returned Sigset has methods: add(sig), remove(sig), fill(), clear(), contains(sig).
  sigset: function(...: integer): Sigset

  --- Register a signal handler for the specified signal.
  --- The handler can be a Lua function, SIG_IGN, or SIG_DFL.
  --- Lua handlers are DEFERRED: the C-level handler only records the
  --- signal, and the Lua function runs between VM instructions once the
  --- interpreter regains control — ordinary VM context, so any Lua code
  --- is safe inside it (no async-signal-safety constraints). A signal
  --- arriving during a blocking call surfaces there as EINTR first; the
  --- ergonomic wrappers run the handler and retry (cosmic.stream).
  --- An error raised inside a handler is logged, not propagated.
  --- Returns the previous handler, flags, and mask; on failure returns
  --- nil, nil, nil plus an error message.
  type PrevAction = PrevAction
  sigaction: function(sig: integer, handler?: function | integer, flags?: integer, mask?: Sigset): PrevAction | nil, string

  --- Modify the process signal mask.
  --- how: SIG_BLOCK, SIG_UNBLOCK, or SIG_SETMASK
  --- Returns the previous signal mask, or nil plus an error message.
  sigprocmask: function(how: integer, set: Sigset): Sigset | nil, string

  --- Suspend the process until a signal is delivered.
  --- Temporarily replaces the signal mask with the provided mask.
  --- Always returns nil plus an error message: EINTR once a signal
  --- was delivered and handled, or another errno on failure.
  --- A deliberate exception to the automatic EINTR retry policy
  --- (cosmic.stream): waiting for the interruption is the call's
  --- entire purpose.
  sigsuspend: function(mask?: Sigset): nil, string

  --- Schedule SIGALRM signals at intervals.
  --- Accepts a SetitimerOptions record with named fields for clarity.
  --- Returns a SetitimerResult with the previous timer values, or
  --- nil plus an error message.
  setitimer: function(opts: SetitimerOptions): SetitimerResult | nil, string

  --- Send a signal to a process.
  --- pid > 0 signals one process by id; 0 signals current group; -1 signals all.
  kill: function(pid: integer, sig: integer): boolean, string

  --- Send a signal to a process group.
  killpg: function(pgrp: integer, sig: integer): boolean, string

  --- Send a signal to the current process.
  raise: function(sig: integer): boolean, string

  --- Get the name of a signal.
  strsignal: function(sig: integer): string
end

--- Send a signal to a process.
--- @param pid integer The process ID (>0 for specific process, 0 for process group, -1 for all)
--- @param sig integer The signal to send
--- @return boolean True on success
--- @return string? Error message on failure
local function kill(pid: integer, sig: integer): boolean, string
  local ok, err = unix.kill(pid, sig)
  if not ok then
    return false, errstr(err, "kill")
  end
  return true
end

--- Send a signal to a process group.
--- @param pgrp integer The process group ID
--- @param sig integer The signal to send
--- @return boolean True on success
--- @return string? Error message on failure
local function killpg(pgrp: integer, sig: integer): boolean, string
  local ok, err = unix.killpg(pgrp, sig)
  if not ok then
    return false, errstr(err, "killpg")
  end
  return true
end

--- Send a signal to the current process.
--- Equivalent to kill(getpid(), sig).
--- @param sig integer The signal to send
--- @return boolean True on success
--- @return string? Error message on failure
local function raise(sig: integer): boolean, string
  local rc, err = unix.raise(sig)
  if rc == nil then
    return false, errstr(err, "raise")
  end
  return true
end

--- Get the name of a signal.
--- @param sig integer The signal number
--- @return string The signal name (e.g., "SIGKILL")
local function strsignal(sig: integer): string
  return unix.strsignal(sig)
end

--- Set an interval timer with opts record for clarity.
--- Calls raw unix.setitimer which expects C-order (interval first, value second).
--- Returns a SetitimerResult with previous timer values, or nil plus
--- an error message on failure.
local function setitimer(opts: SetitimerOptions): SetitimerResult | nil, string
  local value_ms = opts.value_ms or 0
  local interval_ms = opts.interval_ms or 0
  local old_isec, old_ins, old_vsec, old_vns = unix.setitimer(
    opts.which,
    math.floor(interval_ms / 1000),
    math.floor(interval_ms % 1000) * 1000000,
    math.floor(value_ms / 1000),
    math.floor(value_ms % 1000) * 1000000
  )
  if old_isec == nil then
    -- On failure the binding returns (nil, err, errno): the error string
    -- arrives in the second slot.
    return nil, errstr(old_ins, "setitimer")
  end
  return {
    value_ms = old_vsec * 1000 + math.ceil(old_vns / 1000000),
    interval_ms = old_isec * 1000 + math.ceil(old_ins / 1000000),
  }
end

-- The binding's Sigset is a distinct nominal record the generated
-- declarations do not export, so calls go through casts that mirror its
-- signature — but never ones that erase the error slots.
-- cast: function shape for nominal Sigset
local raw_sigaction = unix.sigaction as function(sig: integer, handler?: any, flags?: integer, mask?: Sigset): (any, any, any)
-- cast: function shape for nominal Sigset
local raw_sigprocmask = unix.sigprocmask as function(integer, Sigset): (Sigset, any)
-- cast: function shape for nominal Sigset
local raw_sigsuspend = unix.sigsuspend as function(Sigset): (any, any)

--- Register a signal handler for the specified signal.
--- Lua handlers run deferred in ordinary VM context (see the
--- SignalModule record doc): any Lua is safe inside one, delivery
--- happens between VM instructions, and handler errors are logged,
--- not propagated.
--- @param sig integer The signal to handle
--- @param handler function | integer? Lua function, SIG_IGN, or SIG_DFL
--- @param flags integer? sigaction flags (e.g. SA_RESTART)
--- @param mask Sigset? Signals to block during handler execution
--- @return function | integer The previous handler, or nil on failure
--- @return integer The previous flags
--- @return Sigset The previous mask
--- @return string? Error message on failure
-- handler and the first return are typed any here because the formatter
-- cannot parse a bare `function | integer` union in a function statement;
-- the SignalModule record above carries the precise public type.
local function sigaction(sig: integer, handler?: any, flags?: integer, mask?: Sigset): PrevAction | nil, string
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
    return nil, errstr(prev_flags, "sigaction")
  end
  -- The binding returns an untyped triple; type each slot on its way in.
  local phandler = prev as (function | integer) -- cast: from any
  local pflags = prev_flags as integer -- cast: from any
  local pmask = prev_mask as Sigset -- cast: from any
  return {handler = phandler, flags = pflags, mask = pmask}
end

--- Modify the process signal mask.
--- @param how integer SIG_BLOCK, SIG_UNBLOCK, or SIG_SETMASK
--- @param set Sigset The signal set to apply
--- @return Sigset | nil The previous signal mask, or nil on failure
--- @return string? Error message on failure
local function sigprocmask(how: integer, set: Sigset): Sigset | nil, string
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

local M = {} as SignalModule -- cast: record built incrementally

-- cast: function shape for nominal Sigset
M.sigset = unix.Sigset as function(...: integer): Sigset
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
