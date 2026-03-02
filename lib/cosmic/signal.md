# signal

 Signal handling utilities.
 Wraps cosmo.unix signal functions for process signaling, handlers, and timers.

## Types

### SetitimerOpts

 Options for setitimer: specifies which timer, initial fire time, and repeat interval.

```teal
local record SetitimerOpts
  which: number
  valuesec: number
  valuens: number
  intervalsec: number
  intervalns: number
end
```

### SetitimerResult

 Result from setitimer: previous timer values.

```teal
local record SetitimerResult
  valuesec: number
  valuens: number
  intervalsec: number
  intervalns: number
end
```

### Sigset

 Signal set for blocking, unblocking, and waiting on signals.
 Wraps unix.Sigset for use with sigprocmask, sigaction, and sigsuspend.

```teal
local record Sigset
  --  Adds signal to bitset.
  add: function(self: Sigset, sig: number)
  --  Removes signal from bitset.
  remove: function(self: Sigset, sig: number)
  --  Sets all bits in signal bitset to true.
  fill: function(self: Sigset)
  --  Sets all bits in signal bitset to false.
  clear: function(self: Sigset)
  --  Returns true if signal is in the bitset.
  contains: function(self: Sigset, sig: number): boolean
end
```

### SignalModule

 Signal handling module.
 Provides signal constants, sigaction, sigprocmask, sigsuspend, and delivery functions.

```teal
local record SignalModule
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
  SIG_BLOCK: number
  SIG_UNBLOCK: number
  SIG_SETMASK: number
  SIG_DFL: number
  SIG_IGN: number
  SA_NOCLDSTOP: number
  SA_NOCLDWAIT: number
  SA_NODEFER: number
  SA_RESETHAND: number
  SA_RESTART: number
  ITIMER_REAL: number
  ITIMER_VIRTUAL: number
  ITIMER_PROF: number
  --  Create a new signal set containing the specified signals.
  methods: add(sig), remove(sig), fill(), clear(), contains(sig).
  --  Create a new signal set containing the specified signals.
  --  The returned Sigset has methods: add(sig), remove(sig), fill(), clear(), contains(sig).
  Sigset: function(...: number): Sigset
  --  Register a signal handler for the specified signal.
  --  The handler can be a Lua function, SIG_IGN, or SIG_DFL.
  --  Returns the previous handler, flags, and mask.
  sigaction: function(sig: number, handler?: function | number, flags?: number, mask?: Sigset): function | number, number, Sigset
  --  Modify the process signal mask.
  how: SIG_BLOCK, SIG_UNBLOCK, or SIG_SETMASK
  --  Modify the process signal mask.
  --  how: SIG_BLOCK, SIG_UNBLOCK, or SIG_SETMASK
  --  Returns the previous signal mask.
  sigprocmask: function(how: number, set: Sigset): Sigset
  --  Suspend the process until a signal is delivered.
  --  Temporarily replaces the signal mask with the provided mask.
  sigsuspend: function(mask: Sigset): boolean, Errno
  --  Schedule SIGALRM signals at intervals.
  --  Accepts a SetitimerOpts record with named fields for clarity.
  --  Returns a SetitimerResult with the previous timer values.
  setitimer: function(opts: SetitimerOpts): SetitimerResult
  --  Send a signal to a process.
  --  pid > 0 signals one process by id; 0 signals current group; -1 signals all.
  kill: function(pid: number, sig: number): boolean, string
  --  Send a signal to a process group.
  killpg: function(pgrp: number, sig: number): boolean, string
  --  Send a signal to the current process.
  raise: function(sig: number): boolean, string
  --  Get the name of a signal.
  strsignal: function(sig: number): string
  --  Send a signal to a process.
  pid: number, sig: number): boolean, string
  errno: doc()
end
```

## Functions

### kill

```teal
function kill(pid: number, sig: number): boolean, string
```

 Send a signal to a process.

**Parameters:**

- `pid` (number) - The process ID (>0 for specific process, 0 for process group, -1 for all)
- `sig` (number) - The signal to send

**Returns:**

- boolean - True on success
- string? - Error message on failure

### killpg

```teal
function killpg(pgrp: number, sig: number): boolean, string
```

 Send a signal to a process group.

**Parameters:**

- `pgrp` (number) - The process group ID
- `sig` (number) - The signal to send

**Returns:**

- boolean - True on success
- string? - Error message on failure

### raise

```teal
function raise(sig: number): boolean, string
```

 Send a signal to the current process.
 Equivalent to kill(getpid(), sig).

**Parameters:**

- `sig` (number) - The signal to send

**Returns:**

- boolean - True on success
- string? - Error message on failure

### strsignal

```teal
function strsignal(sig: number): string
```

 Get the name of a signal.

**Parameters:**

- `sig` (number) - The signal number

**Returns:**

- string - The signal name (e.g., "SIGKILL")

### setitimer

```teal
function setitimer(opts: SetitimerOpts): SetitimerResult
```

 Set an interval timer with opts record for clarity.
 Calls raw unix.setitimer which expects C-order (interval first, value second).
 Returns a SetitimerResult with previous timer values.
