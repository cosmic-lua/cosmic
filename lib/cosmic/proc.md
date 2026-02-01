# proc

 Current process management.
 Identity, session/group control, exec, signals, and resource usage.

## Types

### Rusage

 Process resource usage statistics.
 Contains CPU time, memory usage, I/O, and context switch counters.

```teal
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
```

### Errno

 Error information from system calls.
 Provides detailed error codes and human-readable descriptions.

```teal
local record Errno
  errno: function(self: Errno): number
  winerr: function(self: Errno): number
  name: function(self: Errno): string
  call: function(self: Errno): string
  doc: function(self: Errno): string
end
```

### ProcModule

```teal
local record ProcModule
  getpid: function(): number
  getppid: function(): number
  getsid: function(pid: number): number
  getpgrp: function(): number
  getpgid: function(pid: number): number
  setpgrp: function(): number
  setpgid: function(pid: number, pgid: number): boolean
  setsid: function(): number
  daemon: function(nochdir?: boolean, noclose?: boolean): boolean
  kill: function(pid: number, sig: number): boolean
  killpg: function(pgrp: number, sig: number): boolean
  raise: function(sig: number): number
  exit: function(exitcode?: number)
  commandv: function(prog: string): string
  execve: function(prog: string, args: {string}, env: {string}): nil, Errno
  execvp: function(prog: string, argv?: {string}): nil, Errno
  execvpe: function(prog: string, argv: {string}, envp?: {string}): nil, Errno
  fexecve: function(fd: number, argv: {string}, envp?: {string}): nil, Errno
  getrusage: function(who?: number): Rusage
  is_main: function(): boolean
  RUSAGE_SELF: number
  RUSAGE_CHILDREN: number
  RUSAGE_THREAD: number
  RUSAGE_BOTH: number
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
```

## Functions

### getpid

```teal
function getpid(): number
```

 Returns process id of current process.
 This function does not fail.

**Returns:**

- number - The current process id

### getppid

```teal
function getppid(): number
```

 Returns process id of parent process.
 This function does not fail.

**Returns:**

- number - The parent process id

### getsid

```teal
function getsid(pid: number): number
```

 Gets session id for a process.

**Parameters:**

- `pid` (number) - The process id to query

**Returns:**

- number - The session id

### getpgrp

```teal
function getpgrp(): number
```

 Gets process group id of calling process.

**Returns:**

- number - The process group id

### getpgid

```teal
function getpgid(pid: number): number
```

 Gets process group id for a specific process.

**Parameters:**

- `pid` (number) - The process id to query

**Returns:**

- number - The process group id

### setpgrp

```teal
function setpgrp(): number
```

 Sets process group id (same as setpgid(0, 0)).

**Returns:**

- number - The new process group id

### setpgid

```teal
function setpgid(pid: number, pgid: number): boolean
```

 Sets process group id.

**Parameters:**

- `pid` (number) - Process id (0 means calling process)
- `pgid` (number) - Process group id (0 means use pid as pgid)

**Returns:**

- boolean - True on success

### setsid

```teal
function setsid(): number
```

 Creates a new session.
 The calling process becomes the session leader and process group leader.
 Used for creating daemons.
 Fails with ENOSYS on Windows NT.

**Returns:**

- number - The new session id

### daemon

```teal
function daemon(nochdir?: boolean, noclose?: boolean): boolean
```

 Daemonizes the current process.
 Performs standard Unix daemonization: fork, setsid, redirect I/O.

**Parameters:**

- `nochdir` (boolean?) - If true, don't change to root directory (default: false)
- `noclose` (boolean?) - If true, don't redirect stdin/stdout/stderr (default: false)

**Returns:**

- boolean - True on success

### kill

```teal
function kill(pid: number, sig: number): boolean
```

 Sends signal to process(es).

**Parameters:**

- `pid` (number) - Process id to signal. Negative values target process groups
- `sig` (number) - Signal number (e.g., SIGTERM, SIGKILL)

**Returns:**

- boolean - True on success

### killpg

```teal
function killpg(pgrp: number, sig: number): boolean
```

 Sends signal to process group.

**Parameters:**

- `pgrp` (number) - Process group id. If 0, sends to calling process's group
- `sig` (number) - Signal number

**Returns:**

- boolean - True on success

### raise

```teal
function raise(sig: number): number
```

 Sends signal to current process.
 Equivalent to kill(getpid(), sig).

**Parameters:**

- `sig` (number) - Signal number to raise

**Returns:**

- number - 0 on success

### exit

```teal
function exit(exitcode?: number)
```

 Terminates the current process immediately.
 Memory is freed, file descriptors are closed, connections are reset.
 This function never returns.

**Parameters:**

- `exitcode` (number?) - Exit code (defaults to 0)

### commandv

```teal
function commandv(prog: string): string
```

 Performs $PATH lookup of executable.
 Returns the absolute path to the executable if found, nil otherwise.
 On Windows, programs should be installed without .exe/.com suffix for discovery.

**Parameters:**

- `prog` (string) - The program name to search for

**Returns:**

- string? - The absolute path to the executable, or nil if not found

### execve

```teal
function execve(prog: string, args: {string}, env: {string}): nil, Errno
```

 Replaces current process with new program.
 prog must be an absolute path (use commandv for PATH search).
 This function never returns on success.

**Parameters:**

- `prog` (string) - Absolute path to the executable
- `args` ({string}) - Argument vector passed to the program
- `env` ({string}) - Environment variables (KEY=value format)

**Returns:**

- nil, - Errno Only returns on error

### execvp

```teal
function execvp(prog: string, argv?: {string}): nil, Errno
```

 Executes program with PATH search.
 Unlike execve(), this searches for prog in $PATH.
 This function never returns on success.

**Parameters:**

- `prog` (string) - The program name to execute
- `argv` ({string}?) - Argument vector. Defaults to {prog}

**Returns:**

- nil, - Errno Only returns on error

### execvpe

```teal
function execvpe(prog: string, argv: {string}, envp?: {string}): nil, Errno
```

 Executes program with PATH search and custom environment.
 Like execvp() but also allows specifying a custom environment.
 This function never returns on success.

**Parameters:**

- `prog` (string) - The program name to execute
- `argv` ({string}) - Argument vector passed to the program
- `envp` ({string}?) - Environment variables. Inherits if not specified

**Returns:**

- nil, - Errno Only returns on error

### fexecve

```teal
function fexecve(fd: number, argv: {string}, envp?: {string}): nil, Errno
```

 Executes program from file descriptor.
 Allows executing a program that has already been opened.
 This function never returns on success.

**Parameters:**

- `fd` (number) - Open file descriptor pointing to an executable
- `argv` ({string}) - Argument vector passed to the program
- `envp` ({string}?) - Environment variables. Inherits if not specified

**Returns:**

- nil, - Errno Only returns on error

### getrusage

```teal
function getrusage(who?: number): Rusage
```

 Gets resource usage statistics.

**Parameters:**

- `who` (number?) - Who to query: RUSAGE_SELF (default), RUSAGE_CHILDREN, RUSAGE_THREAD, RUSAGE_BOTH

**Returns:**

- Rusage - Resource usage statistics

### is_main

```teal
function is_main(): boolean
```

 Returns true if current script is being run as the main program.
 Returns false if the script is being loaded as a module via require().
 Use this to guard code that should only run when executed directly.

**Returns:**

- boolean - True if running as main script
