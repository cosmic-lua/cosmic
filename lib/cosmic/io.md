# io

 File descriptor I/O operations.
 Wraps low-level file descriptor operations from cosmo.unix.
 Supports Lua 5.4's to-be-closed via __close metamethod on Handle and Pipe.

 WARNING: naming this module "io" shadows Lua's built-in io library:
   local io = require("cosmic.io")  -- WRONG: hides io.stderr, io.stdin, etc.

 Use a distinct local name instead:
   local cio = require("cosmic.io")

 cosmic.io has NO stderr, stdout, or stdin handles. For stream I/O use
 Lua's standard library directly:
   io.stderr:write("error: " .. msg .. "\n")
   io.stdout:write(data)

 cosmic.io provides file-descriptor–level operations (open, read, write,
 pipe, slurp, barf) for cases where you need explicit fd control.

## Types

### Handle

 File handle for I/O operations.
 Supports Lua 5.4's to-be-closed via __close metamethod.

```teal
local record Handle
  close: function(self: Handle): boolean, string
  closed: function(self: Handle): boolean
  fd: function(self: Handle): number
  read: function(self: Handle, size?: number, offset?: number): string | nil, string
  write: function(self: Handle, data: string, offset?: number): number | nil, string
  seek: function(self: Handle, offset: number, whence?: number): number | nil, string
  truncate: function(self: Handle, length?: number): boolean, string
  sync: function(self: Handle): boolean, string
  datasync: function(self: Handle): boolean, string
  dup: function(self: Handle, newfd?: number, flags?: number, lowest?: number): Handle | nil, string
  fcntl: function(self: Handle, cmd: number, arg?: number): number | nil, string
end
```

### Pipe

 Pipe for inter-process communication.
 Supports Lua 5.4's to-be-closed via __close metamethod.

```teal
local record Pipe
  reader: Handle
  writer: Handle
  close: function(self: Pipe): boolean
  closed: function(self: Pipe): boolean
end
```

### IoModule

```teal
local record IoModule
  slurp: function(path: string): string | nil, string
  barf: function(path: string, data: string, mode?: number): boolean, string
  open: function(path: string, flags: number, mode?: number, dirfd?: number): Handle | nil, string
  pipe: function(flags?: number): Pipe | nil, string
  truncate: function(path: string, length?: number): boolean, string
  sync: function()
  O_RDONLY: number
  O_WRONLY: number
  O_RDWR: number
  O_CREAT: number
  O_TRUNC: number
  O_APPEND: number
  O_EXCL: number
  O_CLOEXEC: number
  O_NONBLOCK: number
  O_DIRECT: number
  O_DIRECTORY: number
  O_NOFOLLOW: number
  SEEK_SET: number
  SEEK_CUR: number
  SEEK_END: number
  F_GETFD: number
  F_SETFD: number
  F_GETFL: number
  F_SETFL: number
  F_SETLK: number
  F_SETLKW: number
  F_GETLK: number
  F_RDLCK: number
  F_WRLCK: number
  F_UNLCK: number
  FD_CLOEXEC: number
  AT_FDCWD: number
end
```

## Functions

### open

```teal
function open(path: string, flags: number, mode?: number, dirfd?: number): Handle | nil, string
```

 Open a file. flags: O_RDONLY, O_WRONLY, O_RDWR, combined with O_CREAT, O_TRUNC, etc.
 If dirfd is provided, path is relative to that directory (openat behavior).

### pipe

```teal
function pipe(flags?: number): Pipe | nil, string
```

 Create a pipe. flags: O_CLOEXEC, O_NONBLOCK.

### truncate

```teal
function truncate(path: string, length?: number): boolean, string
```

 Truncate a file by path.

### sync

```teal
function sync()
```

 Flush all file system buffers to disk.

### slurp

```teal
function slurp(path: string): string | nil, string
```

 Read entire file contents.

### barf

```teal
function barf(path: string, data: string, mode?: number): boolean, string
```

 Write data to file, creating or overwriting it.

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
function handle:fd(): number
```

 Returns the underlying file descriptor, or -1 if closed.

### handle:read

```teal
function handle:read(size?: number, offset?: number): string | nil, string
```

 Read up to size bytes. Returns empty string on EOF.
 If offset is provided, reads at that position (pread behavior).

### handle:write

```teal
function handle:write(data: string, offset?: number): number | nil, string
```

 Write data. Returns number of bytes written.
 If offset is provided, writes at that position (pwrite behavior).

### handle:seek

```teal
function handle:seek(offset: number, whence?: number): number | nil, string
```

 Seek to position. whence: SEEK_SET (default), SEEK_CUR, SEEK_END.

### handle:truncate

```teal
function handle:truncate(length?: number): boolean, string
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
function handle:dup(newfd?: number, flags?: number, lowest?: number): Handle | nil, string
```

 Duplicate the handle.
 If newfd is provided, duplicates to that specific fd (dup2 behavior).
 flags can include O_CLOEXEC. lowest specifies minimum acceptable fd.

### handle:fcntl

```teal
function handle:fcntl(cmd: number, arg?: number): number | nil, string
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
