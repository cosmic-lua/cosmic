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
 simply dropping the handle) never leaves a zombie. Side effect: requiring
 cosmic.child.io sets SIGPIPE to SIG_IGN process-wide (a child closing
 stdin early gets EPIPE on the write, not a dead parent).

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
  io_error: string
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
  --  Sends `sig` (default SIGTERM). Fails once reaped (pid may be recycled).
  kill: function(self: Handle, sig?: integer): boolean, string
  --  Non-blocking reap: Result if finished, `nil, nil` if running, or `nil, err` on failure.
  try_wait: function(self: Handle): Result | nil, string
  --  Runs the child to completion (feeding stdin, draining stdout+stderr) and
  --  returns its Result. With `timeout_ms`, returns `nil, "timeout"` if the
  --  child has not finished in time (the handle stays usable). Idempotent.
  wait: function(self: Handle, timeout_ms?: integer): Result | nil, string
end
```

### Options

 Options for spawning a process.
 stdout/stderr Handles (cosmic.fd) become the child's fd 1/2 (the
 matching Result field is then ""); spawn does not take ownership —
 the child gets its own copy, so close your end when done (see
 Example_run_pipe). Raw integer fds are not part of this surface
 (api-review-2); wrap one with fd.wrap() first. "inherit" writes to
 THIS process's fd 1/2 so output streams as it runs; Result stays "".

```teal
local record Options
  stdin: string | cfd.Handle
  stdout: cfd.Handle | childio.StdioMode
  stderr: cfd.Handle | childio.StdioMode
  --  the child's exact environment, as "KEY=VALUE" entries (nil
  --  inherits this process's). Build edited copies with
  --  cosmic.env's `list({drop = ..., set = ...})` — the old
  --  undocumented map shape is gone (api-review-5).
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
 itself fails with `nil, "exec failed: ENOENT: ..."`, not a bogus exit
 code from a later wait(). To spawn cosmic itself, use `rawget(arg, -1)`
 — NOT arg[0], the script path (/zip/main.lua), not the interpreter.

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
