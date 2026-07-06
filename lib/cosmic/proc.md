# proc

 Current process management.
 Identity, session/group control, exec, and resource usage.

 The global `arg` table layout when running a script:
   arg[-1]  — path to the cosmic interpreter binary (use this to re-invoke
              cosmic, e.g. to spawn a child running another script)
   arg[0]   — script path as the runtime sees it (/zip/main.lua when the
              script is dispatched by the embedded entry point — NOT the
              interpreter path)
   arg[1..] — user arguments
 `arg` is typed {string}, so negative indices need
 `rawget(arg, -1) as string` to pass the strict type checker.

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
  exit: function(exitcode?: number)
  commandv: function(prog: string): string
  execve: function(prog: string, args: {string}, env: {string}): nil, string
  execvp: function(prog: string, argv?: {string}): nil, string
  execvpe: function(prog: string, argv: {string}, envp?: {string}): nil, string
  fexecve: function(fd: number, argv: {string}, envp?: {string}): nil, string
  getrusage: function(who?: number): Rusage
  getrlimit: function(resource: number): number, number
  setrlimit: function(resource: number, soft: number, hard?: number): boolean, string
  nice: function(inc: number): number
  getpriority: function(which: number, who: number): number
  setpriority: function(which: number, who: number, prio: number): boolean, string
  sched_yield: function()
  is_main: function(): boolean
  RUSAGE_SELF: number
  RUSAGE_CHILDREN: number
  RUSAGE_THREAD: number
  RUSAGE_BOTH: number
  RLIMIT_AS: number
  RLIMIT_CPU: number
  RLIMIT_FSIZE: number
  RLIMIT_NOFILE: number
  RLIMIT_NPROC: number
  RLIMIT_RSS: number
  PRIO_PROCESS: number
  PRIO_PGRP: number
  PRIO_USER: number
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
function execve(prog: string, args: {string}, env: {string}): nil, string
```

 Replaces current process with new program.
 prog must be an absolute path (use commandv for PATH search).
 This function never returns on success.

**Parameters:**

- `prog` (string) - Absolute path to the executable
- `args` ({string}) - Argument vector passed to the program
- `env` ({string}) - Environment variables (KEY=value format)

**Returns:**

- nil, - string Only returns on error

### execvp

```teal
function execvp(prog: string, argv?: {string}): nil, string
```

 Executes program with PATH search.
 Unlike execve(), this searches for prog in $PATH.
 This function never returns on success.

**Parameters:**

- `prog` (string) - The program name to execute
- `argv` ({string}?) - Argument vector. Defaults to {prog}

**Returns:**

- nil, - string Only returns on error

### execvpe

```teal
function execvpe(prog: string, argv: {string}, envp?: {string}): nil, string
```

 Executes program with PATH search and custom environment.
 Like execvp() but also allows specifying a custom environment.
 This function never returns on success.

**Parameters:**

- `prog` (string) - The program name to execute
- `argv` ({string}) - Argument vector passed to the program
- `envp` ({string}?) - Environment variables. Inherits if not specified

**Returns:**

- nil, - string Only returns on error

### fexecve

```teal
function fexecve(fd: number, argv: {string}, envp?: {string}): nil, string
```

 Executes program from file descriptor.
 Allows executing a program that has already been opened.
 This function never returns on success.

**Parameters:**

- `fd` (number) - Open file descriptor pointing to an executable
- `argv` ({string}) - Argument vector passed to the program
- `envp` ({string}?) - Environment variables. Inherits if not specified

**Returns:**

- nil, - string Only returns on error

### getrusage

```teal
function getrusage(who?: number): Rusage
```

 Gets resource usage statistics.

**Parameters:**

- `who` (number?) - Who to query: RUSAGE_SELF (default), RUSAGE_CHILDREN, RUSAGE_THREAD, RUSAGE_BOTH

**Returns:**

- Rusage - Resource usage statistics

### getrlimit

```teal
function getrlimit(resource: number): number, number
```

 Gets resource limits for the current process.
 Returns the soft and hard limits for the specified resource.

**Parameters:**

- `resource` (number) - The RLIMIT_* constant identifying the resource

**Returns:**

- number - Soft limit (can be exceeded, may generate signal)
- number - Hard limit (cannot be exceeded by unprivileged processes)

### setrlimit

```teal
function setrlimit(resource: number, soft: number, hard?: number): boolean, string
```

 Sets resource limits for the current process.
 The soft limit can be raised up to the hard limit.
 Only privileged processes can raise the hard limit.

**Parameters:**

- `resource` (number) - The RLIMIT_* constant identifying the resource
- `soft` (number) - New soft limit
- `hard` (number?) - New hard limit (defaults to soft if not provided)

**Returns:**

- boolean - True on success
- string? - Error message on failure

### nice

```teal
function nice(inc: number): number
```

 Adjusts the nice value (scheduling priority) of the calling process.
 The nice value ranges from -20 (highest priority) to 19 (lowest priority).
 Only privileged processes can lower the nice value (increase priority).

**Parameters:**

- `inc` (number) - Value to add to current nice value

**Returns:**

- number - The new nice value

### getpriority

```teal
function getpriority(which: number, who: number): number
```

 Gets the scheduling priority of a process, process group, or user.

**Parameters:**

- `which` (number) - What `who` refers to: PRIO_PROCESS, PRIO_PGRP, or PRIO_USER
- `who` (number) - The id to query (0 = calling process/group/user)

**Returns:**

- number - The priority value (nice value), ranging from -20 to 19

### setpriority

```teal
function setpriority(which: number, who: number, prio: number): boolean, string
```

 Sets the scheduling priority of a process, process group, or user.

**Parameters:**

- `which` (number) - What `who` refers to: PRIO_PROCESS, PRIO_PGRP, or PRIO_USER
- `who` (number) - The id to modify (0 = calling process/group/user)
- `prio` (number) - New priority value (-20 to 19, lower = higher priority)

**Returns:**

- boolean - True on success
- string? - Error message on failure

### sched_yield

```teal
function sched_yield()
```

 Relinquishes the CPU, allowing other processes to run.
 Causes the calling thread to yield its scheduled time quantum.
