# proc

 Current process management.
 Identity, session/group control, exec, and resource usage.

 The global `arg` table layout when running a script: arg[-1] is the
 cosmic interpreter binary's path (use interpreter() to reach it
 typed and resolved); arg[0] is the script path as the runtime sees
 it (/zip/main.lua when dispatched by the embedded entry point — NOT
 the interpreter path); arg[1..] are user arguments.

## Types

### WaitResult

 Waits for a child process to change state.
 A raw passthrough: EINTR surfaces here, unlike child.Handle:wait.
 What wait(2) reaped. A record rather than (pid, status, rusage,
 err) returns: the old shape put the error in slot 4, unreachable
 from `local pid, err = ...` and from check.must.

```teal
local record WaitResult
  pid: integer
  --  Raw status word; decode with WIFEXITED/WEXITSTATUS/WIFSIGNALED/WTERMSIG.
  status: integer
  rusage: Rusage
end
```

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
  interpreter: function(): string | nil, string
  which: function(prog: string): string | nil, string
  execve: function(prog: string, args: {string}, env: {string}): nil, string
  execvp: function(prog: string, argv?: {string}): nil, string
  execvpe: function(prog: string, argv: {string}, envp?: {string}): nil, string
  fexecve: function(fd: integer, argv: {string}, envp?: {string}): nil, string
  fork: function(): integer | nil, string
  wait: function(pid?: integer, options?: integer): WaitResult | nil, string
  WIFEXITED: function(status: integer): boolean
  WEXITSTATUS: function(status: integer): integer
  WIFSIGNALED: function(status: integer): boolean
  WTERMSIG: function(status: integer): integer
  getrusage: function(who?: integer): Rusage | nil, string
  getrlimit: function(resource: integer): rusage_mod.Rlimit | nil, string
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

### Rusage

 Process resource usage statistics (the generated unix.Rusage record):
 CPU time, memory usage, I/O, and context switch counters.

alias of `cosmo.unix.Rusage` — field and method table: `cosmic --docs cosmo.unix.Rusage`

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

### which

```teal
function which(prog: string): string | nil, string
```

 Performs $PATH lookup of executable (which(1)).
 On Windows, programs should be installed without .exe/.com suffix for discovery.
 not-found and permission-denied are distinguishable)

**Parameters:**

- `prog` (string) - The program name to search for

**Returns:**

- string - | nil The absolute path to the executable
- string - | nil Error message when not found (names the errno, so

### interpreter

```teal
function interpreter(): string | nil, string
```

 Absolute path of the running cosmic interpreter — for re-invoking it
 to run another script as a child: `child.start({proc.interpreter(),
 "worker.tl"})`. This is `arg[-1]` resolved, NOT `arg[0]` (the script
 path as the runtime sees it, `/zip/main.lua` in a packed binary). A
 bare PATH-invoked argv0 (`cosmic`, the shebang shape) is resolved
 with a real $PATH search. The result is cached across calls.

**Returns:**

- string - | nil The interpreter's absolute path
- string? - Error message when argv0 is missing or unresolvable

### execve

```teal
function execve(prog: string, args: {string}, env: {string}): nil, string
```

 Replaces current process with new program; never returns on success.
 prog must be an absolute path (use which() for PATH search).

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
function fork(): integer | nil, string
```

 Creates a new process (fork).

**Returns:**

- integer - | nil The child pid in the parent, 0 in the child, or nil + error on failure

### wait

```teal
function wait(pid?: integer, options?: integer): WaitResult | nil, string
```
