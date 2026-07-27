# fd

 File descriptor I/O operations.
 Wraps low-level file descriptor operations from cosmo.unix.
 Supports Lua 5.4's to-be-closed via __close metamethod on Handle and Pipe.

 cosmic.fd has NO stderr, stdout, or stdin handles. For stream I/O use
 Lua's standard library directly:
   io.stderr:write("error: " .. msg .. "\n")
   io.stdout:write(data)

 For whole-file path-based operations use cosmic.fs: fs.read(path),
 fs.write(path, data), fs.truncate(path).

 EINTR posture: Handle read/write retry automatically when a signal
 interrupts the call (the signal-safety wave). A pending Lua
 signal handler runs between the interrupted call and its retry, so
 handlers never starve; to break out of a blocking call instead, use
 O_NONBLOCK plus poll, or close the descriptor from the handler.
 The full policy and its exceptions live in cosmic.stream.

## Types

### Handle

 File handle for I/O operations.
 Conforms to the stream contract (cosmic.stream): read returns bare
 nil at end of file, write returns bytes written or nil + error.
 Supports Lua 5.4's to-be-closed via __close metamethod.

```teal
local record Handle
  __close: function(self: Handle)
  close: function(self: Handle): boolean, string
  closed: function(self: Handle): boolean
  fd: function(self: Handle): integer
  read: function(self: Handle, size?: integer, offset?: integer): string | nil, string
  write: function(self: Handle, data: string, offset?: integer): integer | nil, string
  seek: function(self: Handle, offset: integer, whence?: integer): integer | nil, string
  truncate: function(self: Handle, length?: integer): boolean, string
  sync: function(self: Handle): boolean, string
  datasync: function(self: Handle): boolean, string
  dup: function(self: Handle, newfd?: integer, flags?: integer, lowest?: integer): Handle | nil, string
  fcntl: function(self: Handle, cmd: integer, arg?: integer): integer | nil, string
end
```

### Pipe

 Pipe for inter-process communication.
 Supports Lua 5.4's to-be-closed via __close metamethod.

```teal
local record Pipe
  __close: function(self: Pipe)
  reader: Handle
  writer: Handle
  close: function(self: Pipe): boolean
  closed: function(self: Pipe): boolean
end
```

### FdModule

```teal
local record FdModule
  open: function(path: string, flags: integer, mode?: integer, dirfd?: integer): Handle | nil, string
  wrap: function(rawfd: integer): Handle
  pipe: function(flags?: integer): Pipe | nil, string
  O_RDONLY: integer
  O_WRONLY: integer
  O_RDWR: integer
  O_CREAT: integer
  O_TRUNC: integer
  O_APPEND: integer
  O_EXCL: integer
  O_CLOEXEC: integer
  O_NONBLOCK: integer
  O_DIRECT: integer
  O_DIRECTORY: integer
  O_NOFOLLOW: integer
  SEEK_SET: integer
  SEEK_CUR: integer
  SEEK_END: integer
  F_GETFD: integer
  F_SETFD: integer
  F_GETFL: integer
  F_SETFL: integer
  F_SETLK: integer
  F_SETLKW: integer
  F_GETLK: integer
  F_RDLCK: integer
  F_WRLCK: integer
  F_UNLCK: integer
  FD_CLOEXEC: integer
  AT_FDCWD: integer
end
```

## Functions

### open

```teal
function open(path: string, flags: integer, mode?: integer, dirfd?: integer): Handle | nil, string
```

 Open a file. flags: O_RDONLY, O_WRONLY, O_RDWR, combined with O_CREAT, O_TRUNC, etc.
 If dirfd is provided, path is relative to that directory (openat behavior).

### pipe

```teal
function pipe(flags?: integer): Pipe | nil, string
```

 Create a pipe. flags: O_CLOEXEC, O_NONBLOCK.

### wrap

```teal
function wrap(rawfd: integer): Handle
```

 Wrap an already-open raw file descriptor in a Handle.
 Lets fds from fs.tmpfd() (or any other source) enter the
 Handle world: h:read()/h:write()/h:close(), plus automatic cleanup
 via the __close metamethod. The Handle takes ownership: closing it
 closes the fd.

### handle:close

```teal
function handle:close(): boolean, string
```

 Close the handle. Idempotent.
 Returns false + error message if unix.close() fails; true on success.
 A second call on an already-closed handle always returns true.

### handle:closed

```teal
function handle:closed(): boolean
```

 Returns true if closed.

### handle:fd

```teal
function handle:fd(): integer
```

 Returns the underlying file descriptor, or -1 if closed.

### handle:read

```teal
function handle:read(size?: integer, offset?: integer): string | nil, string
```

 Read up to size bytes. Returns nil with NO error on EOF (Lua
 convention: `while true do local chunk = h:read(n); if not chunk
 then break end ... end`), and nil WITH an error on failure —
 including EAGAIN on a nonblocking fd with no data. A read
 interrupted by a signal is retried (see the module header).
 If offset is provided, reads at that position (pread behavior).

### handle:write

```teal
function handle:write(data: string, offset?: integer): integer | nil, string
```

 Write data. Returns number of bytes written (which may be fewer
 than #data — callers writing everything must loop). On failure
 returns nil plus an error. A write interrupted by a signal before
 any byte lands is retried (see the module header).
 If offset is provided, writes at that position (pwrite behavior).

### handle:seek

```teal
function handle:seek(offset: integer, whence?: integer): integer | nil, string
```

 Seek to position. whence: SEEK_SET (default), SEEK_CUR, SEEK_END.
 On failure returns nil plus an error.

### handle:truncate

```teal
function handle:truncate(length?: integer): boolean, string
```

 Truncate to length (default 0).

### handle:sync

```teal
function handle:sync(): boolean, string
```

 Flush data and metadata to disk.

### handle:datasync

```teal
function handle:datasync(): boolean, string
```

 Flush data to disk (but not necessarily metadata).

### handle:dup

```teal
function handle:dup(newfd?: integer, flags?: integer, lowest?: integer): Handle | nil, string
```

 Duplicate the handle.
 If newfd is provided, duplicates to that specific fd (dup2 behavior).
 flags can include O_CLOEXEC. lowest specifies minimum acceptable fd.

### handle:fcntl

```teal
function handle:fcntl(cmd: integer, value?: integer): integer | nil, string
```

 File control operations. cmd: F_GETFD, F_SETFD, F_GETFL, F_SETFL, F_SETLK, etc.

### p:close

```teal
function p:close(): boolean
```

### p:closed

```teal
function p:closed(): boolean
```
