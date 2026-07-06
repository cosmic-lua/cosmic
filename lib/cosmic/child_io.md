# child_io

 Low-level child-process I/O primitives.

 Holds the poll-driven `pump` that concurrently feeds a child's stdin while
 draining its stdout and stderr. Doing all three in one poll loop is what
 keeps large I/O in any direction from deadlocking on a full pipe buffer.
 The pump is deadline-aware and resumable: `cosmic.child` drives it through
 a shared PumpState so a `wait(timeout_ms)` that expires can be resumed by a
 later call, and the partial output collected so far is never lost.

## Types

### PumpState

 Mutable state threaded through `pump`. `cosmic.child` owns one per handle.
 Each fd field is nilled (and the fd closed) as that stream finishes, so a
 resumed pump only watches what is still live. `out`/`err_out` accumulate
 across calls; `stdin_off` records progress feeding `stdin_data`.

```teal
local record PumpState
  stdout_fd: number
  stderr_fd: number
  stdin_fd: number
  stdin_data: string
  stdin_off: integer
  out: {string}
  err_out: {string}
  io_err: string
end
```

### ChildIoModule

```teal
local record ChildIoModule
  PumpState: PumpState
  pump: function(state: PumpState, deadline_ms: number): boolean
  now_ms: function(): number
end
```

## Functions

### now_ms

```teal
function now_ms(): number
```

### pump

```teal
function pump(state: PumpState, deadline_ms: number): boolean
```

 Drive `state` forward: feed stdin while draining stdout/stderr, all in one
 poll loop so no direction can deadlock on a full pipe buffer. Returns
 `true` if `deadline_ms` (an absolute `now_ms()` value, or nil for no limit)
 elapsed before every stream finished — the child may still be running and
 the caller can resume by calling `pump` again with the same state. Returns
 `false` once stdin is fully sent and stdout/stderr have both hit EOF; each
 fd is closed and nilled in `state` as it completes.

**Parameters:**

- `state` (PumpState) - shared, mutable I/O state
- `deadline_ms` (number?) - absolute monotonic-ms deadline, or nil

**Returns:**

- boolean - timed_out
