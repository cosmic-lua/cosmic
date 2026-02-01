# child

 Child process management.
 Spawn and manage child processes with I/O control.

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

### Pipe

 Pipe for reading/writing process I/O.

```teal
local record Pipe
  fd: number
  write: function(self: Pipe, data: string): number
  read: function(self: Pipe, size?: number): string
  close: function(self: Pipe)
end
```

### Handle

 Handle for a spawned process.

```teal
local record Handle
  pid: number
  stdin: Pipe
  stdout: Pipe
  stderr: Pipe
  wait: function(self: Handle): number, string
  read: function(self: Handle, size?: number): boolean | string, string, number
end
```

### Opts

 Options for spawning a process.

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
  spawn: function(argv: {string}, opts?: Opts): Handle, string
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
 Returns twice: parent gets child's pid (> 0), child gets 0.

**Returns:**

- number - The child process id in parent, 0 in child

### posix_spawn

```teal
function posix_spawn(prog: string, argv: {string}, envp?: {string}): number
```

 Spawns a new process using posix_spawn (low-level).
 More efficient than fork() + execve() on some systems.

**Parameters:**

- `prog` (string) - Absolute path to the executable
- `argv` ({string}) - Argument vector passed to the program
- `envp` ({string}?) - Environment variables (KEY=value format). Inherits if not specified

**Returns:**

- number - The child process id on success

### posix_spawnp

```teal
function posix_spawnp(prog: string, argv: {string}, envp?: {string}): number
```

 Spawns a new process with PATH search (low-level).
 Like posix_spawn() but searches for prog in $PATH directories.

**Parameters:**

- `prog` (string) - The program name to execute
- `argv` ({string}) - Argument vector passed to the program
- `envp` ({string}?) - Environment variables. Inherits if not specified

**Returns:**

- number - The child process id on success

### wait

```teal
function wait(pid?: number, options?: number): number, number, Rusage
```

 Waits for child process to terminate.

**Parameters:**

- `pid` (number?) - Process id to wait for. -1 waits for any child (default)
- `options` (number?) - Wait options (e.g., WNOHANG for non-blocking)

**Returns:**

- number - The child process id that terminated
- number - Status code (use WIFEXITED, WEXITSTATUS, etc. to interpret)
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

 Returns true if process exited normally (via exit() or return from main).

**Parameters:**

- `wstatus` (number) - Status code from wait()

**Returns:**

- boolean - True if process exited cleanly

### WEXITSTATUS

```teal
function WEXITSTATUS(wstatus: number): number
```

 Returns the exit code passed to exit().
 Only valid if WIFEXITED(wstatus) is true.

**Parameters:**

- `wstatus` (number) - Status code from wait()

**Returns:**

- number - The exit code

### WIFSIGNALED

```teal
function WIFSIGNALED(wstatus: number): boolean
```

 Returns true if process was terminated by a signal.

**Parameters:**

- `wstatus` (number) - Status code from wait()

**Returns:**

- boolean - True if terminated by signal

### WTERMSIG

```teal
function WTERMSIG(wstatus: number): number
```

 Returns the signal number that terminated the process.
 Only valid if WIFSIGNALED(wstatus) is true.

**Parameters:**

- `wstatus` (number) - Status code from wait()

**Returns:**

- number - The signal number

### spawn

```teal
function spawn(argv: {string}, opts?: Opts): Handle, string
```

 Spawns a child process with I/O control.

**Parameters:**

- `argv` ({string}) - Command and arguments
- `opts` (Opts?) - Spawn options (stdin, stdout, stderr, env, cwd)

**Returns:**

- Handle - Process handle with stdin, stdout, stderr pipes
- string? - Error message if spawn failed

### pipe:write

```teal
function pipe:write(data: string): number
```

### pipe:read

```teal
function pipe:read(size?: number): string
```

### handle:wait

```teal
function handle:wait(): number, string
```

 Wait for the process to exit and return its exit code.
 Closes stdin and reads/closes stdout and stderr before waiting.

**Returns:**

- number - The exit code if the process exited normally
- string - Error message if the process terminated abnormally

### handle:read

```teal
function handle:read(size?: number): boolean | string, string, number
```

 Read output from the process.
 If size is specified, reads that many bytes and returns the data as a string.
 If size is not specified, reads all output, waits for process to exit, and returns
 success status, output, and exit code.

**Parameters:**

- `size` (number) - Optional number of bytes to read

**Returns:**

- boolean|string - Success status (true if exit code is 0) or output string if size specified
- string - The stdout output from the process
- number - The exit code of the process
