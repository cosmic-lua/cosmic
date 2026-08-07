# child

 Child process management.

 The high-level API: `start` hands back a `Handle` you can `stop`,
 `wait` on (with an optional timeout), poll with `try_wait`, or
 stream from with `read`; `run` is the one-shot start-wait form. The
 raw syscalls (fork/wait/kill, W* helpers) live in `cosmic.proc`.

 A Handle owns the child: `wait`/`run` reap it and cache the `Result`, so
 a second `wait` returns the same value instead of failing. An abandoned
 handle is not leaked — its `__gc`/`__close` metamethods SIGKILL and reap
 an un-waited child and close its pipes, so `local h <close> = start{...}`
 (or simply dropping the handle) never leaves a zombie. Side effect: the
 first start() sets SIGPIPE to SIG_IGN process-wide (EPIPE on the write,
 not a dead parent) — unless you already installed a SIGPIPE handler.
 Testing a server you start? Have it print `READY <port>` and block on
 reading that line — the readiness pattern in `cosmic --docs guide.recipes`.

## Types

### Handle

 Handle for a started process.
 Fields prefixed `_` are internal bookkeeping; use the methods.

```teal
local record Handle
  __close: function(self: Handle)
  pid: integer
  _st: childio.PumpState
  _result: Result
  _closed: boolean
  --  Sends `sig` (default SIGTERM); start's partner (D20 rule 9).
  --  Fails once reaped (pid may be recycled).
  stop: function(self: Handle, sig?: integer): boolean, string
  --  DEPRECATED alias of stop (D20 transition, #976); deleted at the
  --  next pin advance (#981-class) once the pinned build engine moves.
  kill: function(self: Handle, sig?: integer): boolean, string
  --  Non-blocking reap: TryWait{finished, result} — result set exactly
  --  when finished — or `nil, err` on a wait failure.
  try_wait: function(self: Handle): TryWait | nil, string
  --  Runs the child to completion (feeding stdin, draining stdout+stderr) and
  --  returns its Result. With `timeout_ms`, returns `nil, "timeout"` if the
  --  child has not finished in time (the handle stays usable). Idempotent.
  wait: function(self: Handle, timeout_ms?: integer): Result | nil, string
  --  Streaming read of up to `size` bytes (default 65536) from the child's
  --  stdout. Returns bare nil at end of file (cosmic.stream contract). For
  --  whole-output capture use `wait`/`run`, which also collect stderr.
  read: function(self: Handle, size?: integer): string | nil, string
end
```

### ChildModule

```teal
local record ChildModule
  start: function(argv: {string}, opts?: Options): Handle | nil, string
  run: function(argv: {string}, opts?: Options): Result | nil, string
end
```

### Result

 Structured outcome of a finished child.
 The records (see cosmic.child.types): a finished child's Result,
 try_wait's TryWait answer, and the start/run Options.

alias of `cosmic.child.types.Result` — field and method table: `cosmic --docs cosmic.child.types.Result`

### TryWait

alias of `cosmic.child.types.TryWait` — field and method table: `cosmic --docs cosmic.child.types.TryWait`

### Options

alias of `cosmic.child.types.Options` — field and method table: `cosmic --docs cosmic.child.types.Options`

## Functions

### start

```teal
function start(argv: {string}, opts?: Options): Handle | nil, string
```

 Starts a child process with I/O control. Uses fexecve for /zip/ paths.
 Returns a Handle on success. If the program cannot be executed, start
 itself fails with `nil, "exec failed: ENOENT: ..."`, not a bogus exit
 code from a later wait(). To start cosmic itself, use cosmic.proc's
 `interpreter()` — NOT arg[0] (/zip/main.lua), not the interpreter.

**Parameters:**

- `argv` ({string}) - Command and arguments
- `opts` (Options?) - Start options

**Returns:**

- Handle - | nil, string? Process handle or nil + error

### run

```teal
function run(argv: {string}, opts?: Options): Result | nil, string
```

 One-shot start: run the child to completion and return its Result,
 or `nil, string` when the child never started (or the reap failed)
 — so `check.must(child.run(...))` means what it says.

**Parameters:**

- `argv` ({string}) - Command and arguments
- `opts` (Options?) - Start options

**Returns:**

- Result - | nil, string The Result, or nil plus why

### handle:stop

```teal
function handle:stop(sig?: integer): boolean, string
```

### handle:wait

```teal
function handle:wait(timeout_ms?: integer): Result | nil, string
```

### handle:try_wait

```teal
function handle:try_wait(): TryWait | nil, string
```

### handle:read

```teal
function handle:read(size?: integer): string | nil, string
```
