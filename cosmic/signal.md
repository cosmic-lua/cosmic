# signal

 Signal handling utilities.
 Wraps cosmo.unix signal functions for process signaling, handlers, and timers.

## Types

### SetitimerOptions

 Options for setitimer: which timer, initial fire time, repeat interval.
 Durations are integer milliseconds; 0 value_ms disarms the timer,
 0 interval_ms means one-shot.

```teal
local record SetitimerOptions
  which: integer
  value_ms: integer
  interval_ms: integer
end
```

### Sigset

 Signal set for blocking, unblocking, and waiting on signals.
 Wraps unix.Sigset for use with sigprocmask, sigaction, and sigsuspend.
 This mirror is deliberate: the generated unix record cannot re-export
 the Sigset record type because its `Sigset` name is taken by the
 constructor function field there. Here the constructor is
 `sigset(...)` (lowercase), so the TYPE name Sigset stays free to
 export — a Teal record cannot hold a value field and a type alias
 under one name.

```teal
local record Sigset
  --  Adds signal to bitset.
  add: function(self: Sigset, sig: integer)
  --  Removes signal from bitset.
  remove: function(self: Sigset, sig: integer)
  --  Sets all bits in signal bitset to true.
  fill: function(self: Sigset)
  --  Sets all bits in signal bitset to false.
  clear: function(self: Sigset)
  --  Returns true if signal is in the bitset.
  contains: function(self: Sigset, sig: integer): boolean
end
```

### PrevAction

 Signal handling module.
 Provides signal constants, sigaction, sigprocmask, sigsuspend, and delivery functions.
 The disposition sigaction replaced. A record rather than
 (handler, flags, mask, err) returns: the old shape put the error in
 slot 4, unreachable from `local prev, err = ...`. Restore with
 `signal.sigaction(sig, prev.handler, prev.flags, prev.mask)`.

```teal
local record PrevAction
  --  The previous handler: a Lua function, or SIG_DFL/SIG_IGN.
  handler: function | integer
  flags: integer
  mask: Sigset
end
```

### SignalModule

```teal
local record SignalModule
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
  SIG_BLOCK: integer
  SIG_UNBLOCK: integer
  SIG_SETMASK: integer
  SIG_DFL: integer
  SIG_IGN: integer
  SA_NOCLDSTOP: integer
  SA_NOCLDWAIT: integer
  SA_NODEFER: integer
  SA_RESETHAND: integer
  SA_RESTART: integer
  ITIMER_REAL: integer
  ITIMER_VIRTUAL: integer
  ITIMER_PROF: integer
  --  Create a new signal set containing the specified signals.
  --  The returned Sigset has methods: add(sig), remove(sig), fill(), clear(), contains(sig).
  sigset: function(...: integer): Sigset
  sigaction: function(sig: integer, handler?: function | integer, flags?: integer, mask?: Sigset): PrevAction | nil, string
  --  Modify the process signal mask.
  --  how: SIG_BLOCK, SIG_UNBLOCK, or SIG_SETMASK
  --  Returns the previous signal mask, or nil plus an error message.
  sigprocmask: function(how: integer, set: Sigset): Sigset | nil, string
  --  Suspend the process until a signal is delivered.
  --  Temporarily replaces the signal mask with the provided mask.
  --  True once a signal was delivered and handled (the EINTR that IS
  --  this call's success — #999: success used to be an error string,
  --  so asserting it always threw); false, err on any other errno.
  --  A deliberate exception to the automatic EINTR retry policy
  --  (cosmic.stream): waiting for the interruption is the call's
  --  entire purpose.
  sigsuspend: function(mask?: Sigset): boolean, string
  --  Schedule SIGALRM signals at intervals.
  --  Returns the previous timer as a SetitimerOptions, or nil plus an
  --  error message.
  setitimer: function(opts: SetitimerOptions): SetitimerOptions | nil, string
  --  Send a signal to a process.
  --  pid > 0 signals one process by id; 0 signals current group; -1 signals all.
  kill: function(pid: integer, sig: integer): boolean, string
  --  Send a signal to a process group.
  killpg: function(pgrp: integer, sig: integer): boolean, string
  --  Send a signal to the current process.
  raise: function(sig: integer): boolean, string
  --  Get the name of a signal.
  strsignal: function(sig: integer): string
end
```

## Functions

### kill

```teal
function kill(pid: integer, sig: integer): boolean, string
```

 Send a signal to a process.

**Parameters:**

- `pid` (integer) - The process ID (>0 for specific process, 0 for process group, -1 for all)
- `sig` (integer) - The signal to send

**Returns:**

- boolean - True on success
- string? - Error message on failure

### killpg

```teal
function killpg(pgrp: integer, sig: integer): boolean, string
```

 Send a signal to a process group.

**Parameters:**

- `pgrp` (integer) - The process group ID
- `sig` (integer) - The signal to send

**Returns:**

- boolean - True on success
- string? - Error message on failure

### raise

```teal
function raise(sig: integer): boolean, string
```

 Send a signal to the current process.
 Equivalent to kill(getpid(), sig).

**Parameters:**

- `sig` (integer) - The signal to send

**Returns:**

- boolean - True on success
- string? - Error message on failure

### strsignal

```teal
function strsignal(sig: integer): string
```

 Get the name of a signal.

**Parameters:**

- `sig` (integer) - The signal number

**Returns:**

- string - The signal name (e.g., "SIGKILL")

### setitimer

```teal
function setitimer(opts: SetitimerOptions): SetitimerOptions | nil, string
```

 Set an interval timer with opts record for clarity.
 Returns the previous timer as a SetitimerOptions (same shape as the
 input, `which` included), or nil plus an error message on failure.

### sigaction

```teal
function sigaction(sig: integer, handler?: any, flags?: integer, mask?: Sigset): PrevAction | nil, string
```

### sigprocmask

```teal
function sigprocmask(how: integer, set: Sigset): Sigset | nil, string
```

 Modify the process signal mask.

**Parameters:**

- `how` (integer) - SIG_BLOCK, SIG_UNBLOCK, or SIG_SETMASK
- `set` (Sigset) - The signal set to apply

**Returns:**

- Sigset - | nil The previous signal mask, or nil on failure
- string? - Error message on failure

### sigsuspend

```teal
function sigsuspend(mask?: Sigset): boolean, string
```

 Suspend the process until a signal is delivered.

**Parameters:**

- `mask` (Sigset?) - Temporary signal mask while suspended

**Returns:**

- boolean - True once a signal was delivered and handled
- string? - Error message on any errno other than EINTR
- string - Error message: EINTR after a signal was handled
