# child

 Child process management.
 Spawn and manage child processes with I/O control.

## Types

### Rusage

 Process resource usage statistics.

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

### Handle

 Handle for a spawned process.
 stdin/stdout/stderr are cosmic.child_io Pipe wrappers (or nil when the
 corresponding stream was redirected to a raw fd via Opts).

```teal
local record Handle
  pid: number
  stdin: childio.Pipe
  stdout: childio.Pipe
  stderr: childio.Pipe
  wait: function(self: Handle): number | nil, string
  read: function(self: Handle, size?: number): boolean | string | nil, string, number
  communicate: function(self: Handle): string, string, number, string
end
```

### Opts

 Options for spawning a process.
 stdout/stderr: raw fd dup2'd onto fd 1/2; handle fields nil.
 Close write end before reading. See Example_spawn_pipe.

```teal
local record Opts
  stdin: string | number
  stdout: number
  stderr: number
  env: {string}
  cwd: string
end
```

### ChildModule

```teal
local record ChildModule
  spawn: function(argv: {string}, opts?: Opts): Handle | nil, string
  prepare_zip_exec: function(zip_path: string): number | nil, string
  fork: function(): number
  posix_spawn: function(prog: string, argv: {string}, envp?: {string}): number
  posix_spawnp: function(prog: string, argv: {string}, envp?: {string}): number
  wait: function(pid?: number, options?: number): number, number, Rusage
  kill: function(pid: number, sig: number): boolean
  WIFEXITED: function(wstatus: number): boolean
  WEXITSTATUS: function(wstatus: number): number
  WIFSIGNALED: function(wstatus: number): boolean
  WTERMSIG: function(wstatus: number): number
  WNOHANG: number
  WUNTRACED: number
  WCONTINUED: number
  SIGTERM: number
  SIGKILL: number
  SIGINT: number
  SIGCHLD: number
  SIGSTOP: number
  SIGCONT: number
end
```

## Functions

### fork

```teal
function fork(): number
```

 Creates a new process (fork).

**Returns:**

- number - The child process id in parent, 0 in child

### posix_spawn

```teal
function posix_spawn(prog: string, argv: {string}, envp?: {string}): number
```

 Spawns a new process using posix_spawn (low-level).

**Parameters:**

- `prog` (string) - Absolute path to the executable
- `argv` ({string}) - Argument vector passed to the program
- `envp` ({string}?) - Environment variables (KEY=value format)

**Returns:**

- number - The child process id on success

### posix_spawnp

```teal
function posix_spawnp(prog: string, argv: {string}, envp?: {string}): number
```

 Spawns a new process with PATH search (low-level).

**Parameters:**

- `prog` (string) - The program name to execute
- `argv` ({string}) - Argument vector passed to the program
- `envp` ({string}?) - Environment variables

**Returns:**

- number - The child process id on success

### wait

```teal
function wait(pid?: number, options?: number): number, number, Rusage
```

 Waits for child process to terminate.

**Parameters:**

- `pid` (number?) - Process id to wait for (-1 for any child)
- `options` (number?) - Wait options (e.g., WNOHANG)

**Returns:**

- number - The child process id that terminated
- number - Status code (use WIFEXITED, WEXITSTATUS to interpret)
- Rusage - Resource usage statistics

### kill

```teal
function kill(pid: number, sig: number): boolean
```

 Sends signal to child process.

**Parameters:**

- `pid` (number) - Process id to signal
- `sig` (number) - Signal number (e.g., SIGTERM, SIGKILL)

**Returns:**

- boolean - True on success

### WIFEXITED

```teal
function WIFEXITED(wstatus: number): boolean
```

 Returns true if process exited normally.

### WEXITSTATUS

```teal
function WEXITSTATUS(wstatus: number): number
```

 Returns the exit code (valid if WIFEXITED is true).

### WIFSIGNALED

```teal
function WIFSIGNALED(wstatus: number): boolean
```

 Returns true if process was terminated by a signal.

### WTERMSIG

```teal
function WTERMSIG(wstatus: number): number
```

 Returns the terminating signal number (valid if WIFSIGNALED is true).

### prepare_zip_exec

```teal
function prepare_zip_exec(zip_path: string): number | nil, string
```

 Prepares an executable fd from a /zip/ path.
 Opens the path to get a zip fd suitable for fexecve.

**Parameters:**

- `zip_path` (string) - Path starting with /zip/

**Returns:**

- number - | nil The file descriptor ready for fexecve
- string - Error message on failure

### spawn

```teal
function spawn(argv: {string}, opts?: Opts): Handle | nil, string
```

 Spawns a child process with I/O control. Uses fexecve for /zip/ paths.
 When Opts.stdout/stderr are fds they are dup2'd into child (handle fields
 nil); MUST close the write end before reading. See Example_spawn_pipe.
 To spawn cosmic itself, use `rawget(arg, -1)` — NOT arg[0] (gotchas #7).

**Parameters:**

- `argv` ({string}) - Command and arguments
- `opts` (Opts?) - Spawn options

**Returns:**

- Handle - | nil, string? Process handle or nil + error

### handle:wait

```teal
function handle:wait(): number | nil, string
```

 Wait for the process to exit and return its exit code.
 Feeds any stdin and drains stdout/stderr first so it cannot deadlock.

**Returns:**

- number - | nil The exit code if the process exited normally
- string - Error message if the process terminated abnormally

### handle:read

```teal
function handle:read(size?: number): boolean | string | nil, string, number
```

 Read output from the process.
 With a size, reads that many bytes from stdout and returns them (or
 nil, err). Without a size, runs the process to completion (feeding stdin,
 draining stdout+stderr) and returns success, stdout, and the exit code.
 To also capture stderr, use communicate().

**Parameters:**

- `size` (number) - Optional number of bytes to read from stdout

**Returns:**

- boolean|string|nil - Success (exit code 0) or, with size, the data read
- string - The stdout output, or the error when size read fails
- number - The exit code of the process

### handle:communicate

```teal
function handle:communicate(): string, string, number, string
```

 Run the process to completion and capture both output streams.
 Feeds any stdin while draining stdout and stderr concurrently, then reaps.

**Returns:**

- string - The captured stdout
- string - The captured stderr
- number - The exit code (-1 if the process did not exit normally)
- string - An error (signal death, or a pump I/O error), or nil
