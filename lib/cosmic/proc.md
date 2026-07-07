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

### ProcModule

```teal
local record ProcModule
  getpid: function(): number
  getppid: function(): number
  getsid: function(pid: number): number | nil, string
  getpgrp: function(): number
  getpgid: function(pid: number): number | nil, string
  setpgrp: function(): number | nil, string
  setpgid: function(pid: number, pgid: number): boolean, string
  setsid: function(): number | nil, string
  daemon: function(nochdir?: boolean, noclose?: boolean): boolean, string
  exit: function(exitcode?: number)
  commandv: function(prog: string): string
  execve: function(prog: string, args: {string}, env: {string}): nil, string
  execvp: function(prog: string, argv?: {string}): nil, string
  execvpe: function(prog: string, argv: {string}, envp?: {string}): nil, string
  fexecve: function(fd: number, argv: {string}, envp?: {string}): nil, string
  fork: function(): number
  posix_spawn: function(prog: string, argv: {string}, envp?: {string}): number
  posix_spawnp: function(prog: string, argv: {string}, envp?: {string}): number
  wait: function(pid?: number, options?: number): number | nil, number, Rusage, string
  kill: function(pid: number, sig: number): boolean
  WIFEXITED: function(status: number): boolean
  WEXITSTATUS: function(status: number): number
  WIFSIGNALED: function(status: number): boolean
  WTERMSIG: function(status: number): number
  getrusage: function(who?: number): Rusage
  getrlimit: function(resource: number): number | nil, number, string
  setrlimit: function(resource: number, soft: number, hard?: number): boolean, string
  nice: function(inc: number): number | nil, string
  getpriority: function(which: number, who: number): number | nil, string
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
  WNOHANG: number
  WUNTRACED: number
  WCONTINUED: number
end
```

## Functions

### getsid

```teal
function getsid(pid: number): number | nil, string
```

 Gets session id for a process.

**Parameters:**

- `pid` (number) - The process id to query

**Returns:**

- number - | nil The session id, or nil on failure
- string? - Error message on failure

### getpgrp

```teal
function getpgrp(): number
```

 Gets process group id of calling process; does not fail.

**Returns:**

- number - The process group id

### getpgid

```teal
function getpgid(pid: number): number | nil, string
```

 Gets process group id for a specific process.

**Parameters:**

- `pid` (number) - The process id to query

**Returns:**

- number - | nil The process group id, or nil on failure
- string? - Error message on failure

### setpgrp

```teal
function setpgrp(): number | nil, string
```

 Sets process group id (same as setpgid(0, 0)).

**Returns:**

- number - | nil The new process group id, or nil on failure
- string? - Error message on failure

### setpgid

```teal
function setpgid(pid: number, pgid: number): boolean, string
```

 Sets process group id.

**Parameters:**

- `pid` (number) - Process id (0 means calling process)
- `pgid` (number) - Process group id (0 means use pid as pgid)

**Returns:**

- boolean - True on success
- string? - Error message on failure

### setsid

```teal
function setsid(): number | nil, string
```

 Creates a new session.
 The calling process becomes the session leader and process group leader.
 Used for creating daemons.
 Fails with ENOSYS on Windows NT.

**Returns:**

- number - | nil The new session id, or nil on failure
- string? - Error message on failure

### daemon

```teal
function daemon(nochdir?: boolean, noclose?: boolean): boolean, string
```

 Daemonizes the current process.
 Performs standard Unix daemonization: fork, setsid, redirect I/O.

**Parameters:**

- `nochdir` (boolean?) - If true, don't change to root directory (default: false)
- `noclose` (boolean?) - If true, don't redirect stdin/stdout/stderr (default: false)

**Returns:**

- boolean - True on success
- string? - Error message on failure

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

 Replaces current process with new program; never returns on success.
 prog must be an absolute path (use commandv for PATH search).

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

 Executes program with PATH search; never returns on success.
 Unlike execve(), this searches for prog in $PATH.

**Parameters:**

- `prog` (string) - The program name to execute
- `argv` ({string}?) - Argument vector. Defaults to {prog}

**Returns:**

- nil, - string Only returns on error

### execvpe

```teal
function execvpe(prog: string, argv: {string}, envp?: {string}): nil, string
```

 Executes program with PATH search and custom environment; never
 returns on success. Like execvp() with a custom environment.

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

 Executes program from an already-opened file descriptor; never
 returns on success.

**Parameters:**

- `fd` (number) - Open file descriptor pointing to an executable
- `argv` ({string}) - Argument vector passed to the program
- `envp` ({string}?) - Environment variables. Inherits if not specified

**Returns:**

- nil, - string Only returns on error

### fork

```teal
function fork(): number
```

 Creates a new process (fork).

**Returns:**

- number - The child pid in the parent, 0 in the child

### posix_spawn

```teal
function posix_spawn(prog: string, argv: {string}, envp?: {string}): number
```

 Spawns a program via posix_spawn (no PATH search).

**Parameters:**

- `prog` (string) - Absolute path to the executable
- `argv` ({string}) - Argument vector passed to the program
- `envp` ({string}?) - Environment (KEY=value); inherits if omitted

**Returns:**

- number - The child pid on success

### posix_spawnp

```teal
function posix_spawnp(prog: string, argv: {string}, envp?: {string}): number
```

 Spawns a program via posix_spawnp (PATH search).

**Parameters:**

- `prog` (string) - Program name to execute
- `argv` ({string}) - Argument vector passed to the program
- `envp` ({string}?) - Environment (KEY=value); inherits if omitted

**Returns:**

- number - The child pid on success

### wait

```teal
function wait(pid?: number, options?: number): number | nil, number, Rusage, string
```

 Waits for a child process to change state.

**Parameters:**

- `pid` (number?) - Child pid to wait for (-1 or nil for any child)
- `options` (number?) - Wait options (e.g. WNOHANG)

**Returns:**

- number - | nil The pid that changed state (0 with WNOHANG if none), or nil on failure
- number - Status word (interpret with WIFEXITED/WEXITSTATUS/...)
- Rusage - Resource usage for the reaped child
- string? - Error message on failure

### kill

```teal
function kill(pid: number, sig: number): boolean
```

 Sends a signal to a process.

**Parameters:**

- `pid` (number) - Process id to signal
- `sig` (number) - Signal number (e.g. SIGTERM, SIGKILL)

**Returns:**

- boolean - True on success

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
function getrlimit(resource: number): number | nil, number, string
```

 Gets resource limits for the current process.
 Returns the soft and hard limits for the specified resource.

**Parameters:**

- `resource` (number) - The RLIMIT_* constant identifying the resource

**Returns:**

- number - | nil Soft limit (can be exceeded, may generate signal), or nil on failure
- number - Hard limit (cannot be exceeded by unprivileged processes)
- string? - Error message on failure

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
function nice(inc: number): number | nil, string
```

 Adjusts the nice value (scheduling priority) of the calling process.
 The nice value ranges from -20 (highest priority) to 19 (lowest priority).
 Only privileged processes can lower the nice value (increase priority).

**Parameters:**

- `inc` (number) - Value to add to current nice value

**Returns:**

- number - | nil The new nice value, or nil on failure
- string? - Error message on failure

### getpriority

```teal
function getpriority(which: number, who: number): number | nil, string
```

 Gets the scheduling priority of a process, process group, or user.

**Parameters:**

- `which` (number) - What `who` refers to: PRIO_PROCESS, PRIO_PGRP, or PRIO_USER
- `who` (number) - The id to query (0 = calling process/group/user)

**Returns:**

- number - | nil The priority value (-20 to 19), or nil on failure
- string? - Error message on failure

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
