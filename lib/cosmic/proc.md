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
  getpid: function(): integer
  getppid: function(): integer
  getsid: function(pid: integer): integer | nil, string
  getpgrp: function(): integer
  getpgid: function(pid: integer): integer | nil, string
  setpgrp: function(): integer | nil, string
  setpgid: function(pid: integer, pgid: integer): boolean, string
  setsid: function(): integer | nil, string
  daemon: function(nochdir?: boolean, noclose?: boolean): boolean, string
  exit: function(exitcode?: integer)
  commandv: function(prog: string): string
  execve: function(prog: string, args: {string}, env: {string}): nil, string
  execvp: function(prog: string, argv?: {string}): nil, string
  execvpe: function(prog: string, argv: {string}, envp?: {string}): nil, string
  fexecve: function(fd: integer, argv: {string}, envp?: {string}): nil, string
  fork: function(): integer
  posix_spawn: function(prog: string, argv: {string}, envp?: {string}): integer
  posix_spawnp: function(prog: string, argv: {string}, envp?: {string}): integer
  wait: function(pid?: integer, options?: integer): integer | nil, integer, Rusage, string
  kill: function(pid: integer, sig: integer): boolean
  WIFEXITED: function(status: integer): boolean
  WEXITSTATUS: function(status: integer): integer
  WIFSIGNALED: function(status: integer): boolean
  WTERMSIG: function(status: integer): integer
  getrusage: function(who?: integer): Rusage
  getrlimit: function(resource: integer): integer | nil, integer, string
  setrlimit: function(resource: integer, soft: integer, hard?: integer): boolean, string
  nice: function(inc: integer): integer | nil, string
  getpriority: function(which: integer, who: integer): integer | nil, string
  setpriority: function(which: integer, who: integer, prio: integer): boolean, string
  sched_yield: function()
  is_main: function(): boolean
  RUSAGE_SELF: integer
  RUSAGE_CHILDREN: integer
  RUSAGE_THREAD: integer
  RUSAGE_BOTH: integer
  RLIMIT_AS: integer
  RLIMIT_CPU: integer
  RLIMIT_FSIZE: integer
  RLIMIT_NOFILE: integer
  RLIMIT_NPROC: integer
  RLIMIT_RSS: integer
  PRIO_PROCESS: integer
  PRIO_PGRP: integer
  PRIO_USER: integer
  WNOHANG: integer
  WUNTRACED: integer
  WCONTINUED: integer
end
```

## Functions

### getsid

```teal
function getsid(pid: integer): integer | nil, string
```

 Gets session id for a process.

**Parameters:**

- `pid` (integer) - The process id to query

**Returns:**

- integer - | nil The session id, or nil on failure
- string? - Error message on failure

### getpgrp

```teal
function getpgrp(): integer
```

 Gets process group id of calling process; does not fail.

**Returns:**

- integer - The process group id

### getpgid

```teal
function getpgid(pid: integer): integer | nil, string
```

 Gets process group id for a specific process.

**Parameters:**

- `pid` (integer) - The process id to query

**Returns:**

- integer - | nil The process group id, or nil on failure
- string? - Error message on failure

### setpgrp

```teal
function setpgrp(): integer | nil, string
```

 Sets process group id (same as setpgid(0, 0)).

**Returns:**

- integer - | nil The new process group id, or nil on failure
- string? - Error message on failure

### setpgid

```teal
function setpgid(pid: integer, pgid: integer): boolean, string
```

 Sets process group id.

**Parameters:**

- `pid` (integer) - Process id (0 means calling process)
- `pgid` (integer) - Process group id (0 means use pid as pgid)

**Returns:**

- boolean - True on success
- string? - Error message on failure

### setsid

```teal
function setsid(): integer | nil, string
```

 Creates a new session.
 The calling process becomes the session leader and process group leader.
 Used for creating daemons.
 Fails with ENOSYS on Windows NT.

**Returns:**

- integer - | nil The new session id, or nil on failure
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
function fexecve(fd: integer, argv: {string}, envp?: {string}): nil, string
```

 Executes program from an already-opened file descriptor; never
 returns on success.

**Parameters:**

- `fd` (integer) - Open file descriptor pointing to an executable
- `argv` ({string}) - Argument vector passed to the program
- `envp` ({string}?) - Environment variables. Inherits if not specified

**Returns:**

- nil, - string Only returns on error

### fork

```teal
function fork(): integer
```

 Creates a new process (fork).

**Returns:**

- integer - The child pid in the parent, 0 in the child

### posix_spawn

```teal
function posix_spawn(prog: string, argv: {string}, envp?: {string}): integer
```

 Spawns a program via posix_spawn (no PATH search).

**Parameters:**

- `prog` (string) - Absolute path to the executable
- `argv` ({string}) - Argument vector passed to the program
- `envp` ({string}?) - Environment (KEY=value); inherits if omitted

**Returns:**

- integer - The child pid on success

### posix_spawnp

```teal
function posix_spawnp(prog: string, argv: {string}, envp?: {string}): integer
```

 Spawns a program via posix_spawnp (PATH search).

**Parameters:**

- `prog` (string) - Program name to execute
- `argv` ({string}) - Argument vector passed to the program
- `envp` ({string}?) - Environment (KEY=value); inherits if omitted

**Returns:**

- integer - The child pid on success

### wait

```teal
function wait(pid?: integer, options?: integer): integer | nil, integer, Rusage, string
```

 Waits for a child process to change state.

**Parameters:**

- `pid` (integer?) - Child pid to wait for (-1 or nil for any child)
- `options` (integer?) - Wait options (e.g. WNOHANG)

**Returns:**

- integer - | nil The pid that changed state (0 with WNOHANG if none), or nil on failure
- integer - Status word (interpret with WIFEXITED/WEXITSTATUS/...)
- Rusage - Resource usage for the reaped child
- string? - Error message on failure

### kill

```teal
function kill(pid: integer, sig: integer): boolean
```

 Sends a signal to a process.

**Parameters:**

- `pid` (integer) - Process id to signal
- `sig` (integer) - Signal number (e.g. SIGTERM, SIGKILL)

**Returns:**

- boolean - True on success

### getrusage

```teal
function getrusage(who?: integer): Rusage
```

 Gets resource usage statistics.

**Parameters:**

- `who` (integer?) - Who to query: RUSAGE_SELF (default), RUSAGE_CHILDREN, RUSAGE_THREAD, RUSAGE_BOTH

**Returns:**

- Rusage - Resource usage statistics

### getrlimit

```teal
function getrlimit(resource: integer): integer | nil, integer, string
```

 Gets resource limits for the current process.
 Returns the soft and hard limits for the specified resource.

**Parameters:**

- `resource` (integer) - The RLIMIT_* constant identifying the resource

**Returns:**

- integer - | nil Soft limit (can be exceeded, may generate signal), or nil on failure
- integer - Hard limit (cannot be exceeded by unprivileged processes)
- string? - Error message on failure

### setrlimit

```teal
function setrlimit(resource: integer, soft: integer, hard?: integer): boolean, string
```

 Sets resource limits for the current process.
 The soft limit can be raised up to the hard limit.
 Only privileged processes can raise the hard limit.

**Parameters:**

- `resource` (integer) - The RLIMIT_* constant identifying the resource
- `soft` (integer) - New soft limit
- `hard` (integer?) - New hard limit (defaults to soft if not provided)

**Returns:**

- boolean - True on success
- string? - Error message on failure

### nice

```teal
function nice(inc: integer): integer | nil, string
```

 Adjusts the nice value (scheduling priority) of the calling process.
 The nice value ranges from -20 (highest priority) to 19 (lowest priority).
 Only privileged processes can lower the nice value (increase priority).

**Parameters:**

- `inc` (integer) - Value to add to current nice value

**Returns:**

- integer - | nil The new nice value, or nil on failure
- string? - Error message on failure

### getpriority

```teal
function getpriority(which: integer, who: integer): integer | nil, string
```

 Gets the scheduling priority of a process, process group, or user.

**Parameters:**

- `which` (integer) - What `who` refers to: PRIO_PROCESS, PRIO_PGRP, or PRIO_USER
- `who` (integer) - The id to query (0 = calling process/group/user)

**Returns:**

- integer - | nil The priority value (-20 to 19), or nil on failure
- string? - Error message on failure

### setpriority

```teal
function setpriority(which: integer, who: integer, prio: integer): boolean, string
```

 Sets the scheduling priority of a process, process group, or user.

**Parameters:**

- `which` (integer) - What `who` refers to: PRIO_PROCESS, PRIO_PGRP, or PRIO_USER
- `who` (integer) - The id to modify (0 = calling process/group/user)
- `prio` (integer) - New priority value (-20 to 19, lower = higher priority)

**Returns:**

- boolean - True on success
- string? - Error message on failure
