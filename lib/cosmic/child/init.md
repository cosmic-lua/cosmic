# child

 Child process management.

 The high-level spawn API. `spawn` starts a process and hands back a
 `Handle` you can `kill`, `wait` on (with an optional timeout), poll with
 `try_wait`, or stream from with `read`. `run` is the one-shot form that
 spawns, waits, and returns a structured `Result`. Low-level syscall
 passthroughs (fork/wait/kill/posix_spawn, the W* status helpers) live in
 `cosmic.proc`; this module builds the ergonomic layer on top.

 A Handle owns the child: `wait`/`run` reap it and cache the `Result`, so a
 second `wait` returns the same value instead of failing. An abandoned
 handle is not leaked — its `__gc`/`__close` metamethods SIGKILL and reap an
 un-waited child and close its pipes, so `local h <close> = spawn{...}` (or
 simply dropping the handle) never leaves a zombie.

## Types

### Result

 Structured outcome of a finished child.
 Exactly one of `code`/`signal` is set: `code` when the child exited,
 `signal` when a signal killed it. `ok` is true only on a zero exit.

```teal
local record Result
  code: integer
  signal: integer
  ok: boolean
  stdout: string
  stderr: string
end
```

### Handle

 Handle for a spawned process.
 Fields prefixed `_` are internal bookkeeping; use the methods.

```teal
local record Handle
  __close: function(self: Handle)
  pid: integer
  _st: childio.PumpState
  _result: Result
  _closed: boolean
  --  Sends `sig` (default SIGTERM) to the child. Fails once the child has
  --  been reaped, since its pid may have been recycled.
  kill: function(self: Handle, sig?: integer): boolean, string
  --  Non-blocking reap: the cached/final Result if the child has finished,
  --  `nil, nil` while it is still running, or `nil, err` on a wait error.
  try_wait: function(self: Handle): Result | nil, string
  --  Runs the child to completion (feeding stdin, draining stdout+stderr) and
  --  returns its Result. With `timeout_ms`, returns `nil, "timeout"` if the
  --  child has not finished in time; the handle stays usable (wait again, or
  --  kill it). Idempotent: repeat calls return the same cached Result.
  wait: function(self: Handle, timeout_ms?: integer): Result | nil, string
end
```

### Options

 Options for spawning a process.
 stdout/stderr Handles (cosmic.fd) become the child's fd 1/2 (the
 corresponding Result field is then ""). spawn does not take ownership
 of a Handle: the child gets its own copy of the descriptor, so close
 your end when you are done with it (see Example_run_pipe). Raw integer
 fds are not part of this surface (api-review-2, #602); wrap one with
 fd.wrap() if it comes from outside the fd module.

```teal
local record Options
  stdin: string | cfd.Handle
  stdout: cfd.Handle
  stderr: cfd.Handle
  env: {string}
  cwd: string
end
```

### ChildModule

```teal
local record ChildModule
  spawn: function(argv: {string}, opts?: Options): Handle | nil, string
  run: function(argv: {string}, opts?: Options): Result | nil, string
  prepare_zip_exec: function(zip_path: string): integer | nil, string
end
```

## Functions

### prepare_zip_exec

```teal
function prepare_zip_exec(zip_path: string): integer | nil, string
```

 Prepares an executable fd from a /zip/ path for fexecve.

**Parameters:**

- `zip_path` (string) - Path starting with /zip/

**Returns:**

- integer - | nil The file descriptor ready for fexecve
- string - Error message on failure

### spawn

```teal
function spawn(argv: {string}, opts?: Options): Handle | nil, string
```

 Spawns a child process with I/O control. Uses fexecve for /zip/ paths.
 Returns a Handle on success. If the program cannot be executed, spawn
 itself fails with `nil, "exec failed: ENOENT: ..."` — the error surfaces
 here, not as a bogus exit code from a later wait().
 To spawn cosmic itself, use `rawget(arg, -1)` — NOT arg[0], which is
 the script path (/zip/main.lua), not the interpreter.

**Parameters:**

- `argv` ({string}) - Command and arguments
- `opts` (Options?) - Spawn options

**Returns:**

- Handle - | nil, string? Process handle or nil + error

### run

```teal
function run(argv: {string}, opts?: Options): Result | nil, string
```

 One-shot spawn: run to completion and return the Result.

**Parameters:**

- `argv` ({string}) - Command and arguments
- `opts` (Options?) - Spawn options

**Returns:**

- Result - | nil, string? The Result, or nil + error

### handle:kill

```teal
function handle:kill(sig?: integer): boolean, string
```

### handle:wait

```teal
function handle:wait(timeout_ms?: integer): Result | nil, string
```

### handle:try_wait

```teal
function handle:try_wait(): Result | nil, string
```

### handle:read

```teal
function handle:read(size?: integer): string | nil, string
```
