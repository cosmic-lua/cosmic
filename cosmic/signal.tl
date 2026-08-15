--- Signal handling utilities.
--- Wraps cosmo.unix signal functions for process signaling, handlers, and timers.
local unix = require("cosmo.unix")
local errstr = require("cosmic.errno").format
local errno_is = require("cosmic.errno").is_code

--- Options for setitimer: which timer, initial fire time, repeat interval.
--- Durations are integer milliseconds; 0 value_ms disarms the timer,
--- 0 interval_ms means one-shot.
local record SetitimerOptions
  which: integer
  value_ms: integer
  interval_ms: integer
end

--- setitimer's return is this SAME record: the previous timer,
--- `which` included, so a restore is `signal.setitimer(prev)` with no
--- reassembly. Sub-millisecond remainders round UP, so a still-armed
--- timer never reads as the 0 that would disarm it when passed back.

--- Signal set for blocking, unblocking, and waiting on signals.
--- The binding's own record (add/remove/fill/clear/contains), built by
--- sigset() and passed to sigprocmask, sigaction and sigsuspend.
local type Sigset = unix.Sigset

--- Signal handling module.
--- Provides signal constants, sigaction, sigprocmask, sigsuspend, and delivery functions.
--- The disposition sigaction replaced; a record so the error stays
--- reachable in slot 2. Restore with
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
  --- True once a signal was delivered and handled (the EINTR that IS
  --- this call's success); false, err on any other errno.
  --- A deliberate exception to the automatic EINTR retry policy
  --- (cosmic.stream): waiting for the interruption is the call's
  --- entire purpose.
  sigsuspend: function(mask?: Sigset): boolean, string

  --- Options for setitimer, and its result: the previous timer in the
  --- same shape, so a restore round-trips.
  type SetitimerOptions = SetitimerOptions

  --- Schedule SIGALRM signals at intervals.
  --- Returns the previous timer as a SetitimerOptions, or nil plus an
  --- error message.
  setitimer: function(opts: SetitimerOptions): SetitimerOptions | nil, string

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
--- Returns the previous timer as a SetitimerOptions (same shape as the
--- input, `which` included), or nil plus an error message on failure.
local function setitimer(opts: SetitimerOptions): SetitimerOptions | nil, string
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
    which = opts.which,
    value_ms = old_vsec * 1000 + math.ceil(old_vns / 1000000),
    interval_ms = old_isec * 1000 + math.ceil(old_ins / 1000000),
  }
end

-- Sigset is the binding's own type, so sigprocmask and sigsuspend are
-- ordinary calls needing no cast. The wrapper below still needs one:
-- it takes `handler` as `any`, because the formatter cannot parse a
-- bare `function | integer` union in a function statement, and `any`
-- does not pass to the binding's union.

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
  -- One call with whatever the caller gave: the binding tolerates
  -- explicit trailing nils, so no branch ladder is needed to avoid
  -- producing them.
  -- Cast the ARGUMENT, not the whole binding: casting `unix.sigaction`
  -- to a function type would mean restating its return tuple here, a
  -- hand-copy of what `cosmo/unix.d.tl` already declares and one liable
  -- to drift out of sync with it.
  local raw_handler = handler as (function | integer) -- cast: handler union
  local prev, prev_flags, prev_mask =
  unix.sigaction(sig, raw_handler, flags, mask)
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
  local old, err = unix.sigprocmask(how, set)
  if old == nil then
    return nil, errstr(err, "sigprocmask")
  end
  return old
end

--- Suspend the process until a signal is delivered.
--- @param mask Sigset? Temporary signal mask while suspended
--- @return boolean True once a signal was delivered and handled
--- @return string? Error message on any errno other than EINTR
--- @return string Error message: EINTR after a signal was handled
local function sigsuspend(mask?: Sigset): boolean, string
  local _, err, eno = unix.sigsuspend(mask)
  if errno_is(eno, "EINTR") then
    return true
  end
  return false, errstr(err, "sigsuspend")
end

local M = {} as SignalModule -- cast: record built incrementally

M.sigset = unix.sigset
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
