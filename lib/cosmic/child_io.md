# child_io

 Low-level child-process I/O primitives.

 Holds the pipe wrapper shared by cosmic.child and a poll-driven `pump`
 that concurrently feeds a child's stdin while draining its stdout and
 stderr. Doing all three in one poll loop is what keeps large I/O in any
 direction from deadlocking on a full pipe buffer.

## Types

### Pipe

 A pipe endpoint. `fd` is a plain field (not a method like io.Handle:fd()).

```teal
local record Pipe
  fd: number
  write: function(self: Pipe, data: string): number, string
  read: function(self: Pipe, size?: number): string, string
  close: function(self: Pipe)
end
```

### ChildIoModule

```teal
local record ChildIoModule
  Pipe: Pipe
  make_pipe: function(fd: number): Pipe
  pump: function(stdout_fd: number, stderr_fd: number, stdin_fd: number, stdin_data: string): string, string, string
end
```

## Functions

### make_pipe

```teal
function make_pipe(fd: number): Pipe
```

 Wrap a raw pipe fd in a Pipe. Returns nil when fd is nil.
 read()/write() return `nil, err` on a real I/O error; read() returns ""
 only on genuine end-of-file, so an error is never mistaken for EOF.

**Parameters:**

- `fd` (number) - Raw file descriptor, or nil

**Returns:**

- Pipe - wrapper, or nil when fd is nil

### pump

```teal
function pump(stdout_fd: number, stderr_fd: number, stdin_fd: number, stdin_data: string): string, string, string
```

 Concurrently write `stdin_data` to `stdin_fd` while draining `stdout_fd`
 and `stderr_fd` to end-of-file, all in one poll loop so no direction can
 deadlock on a full pipe buffer. `stdin_fd` is closed when the write
 finishes or the child hangs up (EPIPE); stdout/stderr fds are left open
 for the caller to close. A read/write error stops that stream and is
 reported; EPIPE on stdin (the child stopped reading) is not an error.

**Parameters:**

- `stdout_fd` (number) - stdout read end, or nil
- `stderr_fd` (number) - stderr read end, or nil
- `stdin_fd` (number) - stdin write end, or nil
- `stdin_data` (string) - bytes to send to stdin, or nil

**Returns:**

- string - collected stdout
- string - collected stderr
- string? - first I/O error, or nil when clean

### pipe:write

```teal
function pipe:write(data: string): number, string
```

### pipe:read

```teal
function pipe:read(size?: number): string, string
```
