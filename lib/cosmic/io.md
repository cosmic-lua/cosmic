# io

 File descriptor I/O operations.
 Wraps low-level file descriptor operations from cosmo.unix.

## Types

### PipeResult

 Result from a pipe operation.

```teal
local record PipeResult
  reader: number
  writer: number
end
```

### UnixIO

```teal
local record UnixIO
  open: function(path: string, flags: number, mode?: number, dirfd?: number): number, any
  close: function(fd: number): boolean, any
  read: function(fd: number, bufsiz?: number, offset?: number): string, any
  write: function(fd: number, data: string, offset?: number): number, any
  lseek: function(fd: number, offset: number, whence?: number): number, any
  truncate: function(path: string, length?: number): boolean, any
  ftruncate: function(fd: number, length?: number): boolean, any
  dup: function(oldfd: number, newfd?: number, flags?: number, lowest?: number): number, any
  pipe: function(flags?: number): number, number | any
  fcntl: function(fd: number, cmd: number, ...: any): any
  sync: function()
  fsync: function(fd: number): boolean, any
  fdatasync: function(fd: number): boolean, any
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
  F_RDLCK: number
  F_WRLCK: number
  F_UNLCK: number
  FD_CLOEXEC: number
  AT_FDCWD: number
end
```

### IoModule

```teal
local record IoModule
  slurp: function(path: string): string, string
  barf: function(path: string, data: string, mode?: number): boolean, string
  open: function(path: string, flags: number, mode?: number, dirfd?: number): number, string
  close: function(fd: number): boolean, string
  read: function(fd: number, size?: number, offset?: number): string, string
  write: function(fd: number, data: string, offset?: number): number, string
  lseek: function(fd: number, offset: number, whence?: number): number, string
  truncate: function(path: string, length?: number): boolean, string
  ftruncate: function(fd: number, length?: number): boolean, string
  dup: function(oldfd: number, newfd?: number, flags?: number, lowest?: number): number, string
  pipe: function(flags?: number): PipeResult, string
  fcntl: function(fd: number, cmd: number, ...: any): any
  sync: function()
  fsync: function(fd: number): boolean, string
  fdatasync: function(fd: number): boolean, string
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
function open(path: string, flags: number, mode?: number, dirfd?: number): number, string
```

 Opens a file and returns a file descriptor.

**Parameters:**

- `path` (string) - The path to the file
- `flags` (number) - Bitwise OR of O_* flags (e.g., O_RDONLY, O_WRONLY | O_CREAT)
- `mode` (number) - Optional file mode for creation (e.g., 0644)
- `dirfd` (number) - Optional directory file descriptor for relative paths

**Returns:**

- number - File descriptor on success
- string - Error message on failure

### close

```teal
function close(fd: number): boolean, string
```

 Closes a file descriptor.

**Parameters:**

- `fd` (number) - The file descriptor to close

**Returns:**

- boolean - True on success
- string - Error message on failure

### read

```teal
function read(fd: number, size?: number, offset?: number): string, string
```

 Reads from a file descriptor.
 Returns empty string on end of file.

**Parameters:**

- `fd` (number) - The file descriptor to read from
- `size` (number) - Optional maximum bytes to read (default: BUFSIZ)
- `offset` (number) - Optional offset for pread behavior

**Returns:**

- string - Data read on success
- string - Error message on failure

### write

```teal
function write(fd: number, data: string, offset?: number): number, string
```

 Writes to a file descriptor.

**Parameters:**

- `fd` (number) - The file descriptor to write to
- `data` (string) - The data to write
- `offset` (number) - Optional offset for pwrite behavior

**Returns:**

- number - Number of bytes written on success
- string - Error message on failure

### lseek

```teal
function lseek(fd: number, offset: number, whence?: number): number, string
```

 Seeks to a position in a file.

**Parameters:**

- `fd` (number) - The file descriptor
- `offset` (number) - The offset to seek to
- `whence` (number) - Optional seek mode: SEEK_SET (default), SEEK_CUR, or SEEK_END

**Returns:**

- number - New position from start of file
- string - Error message on failure

### truncate

```teal
function truncate(path: string, length?: number): boolean, string
```

 Truncates a file to a specified length.

**Parameters:**

- `path` (string) - The path to the file
- `length` (number) - Optional new length (default: 0)

**Returns:**

- boolean - True on success
- string - Error message on failure

### ftruncate

```teal
function ftruncate(fd: number, length?: number): boolean, string
```

 Truncates an open file to a specified length.

**Parameters:**

- `fd` (number) - The file descriptor
- `length` (number) - Optional new length (default: 0)

**Returns:**

- boolean - True on success
- string - Error message on failure

### dup

```teal
function dup(oldfd: number, newfd?: number, flags?: number, lowest?: number): number, string
```

 Duplicates a file descriptor.

**Parameters:**

- `oldfd` (number) - The file descriptor to duplicate
- `newfd` (number) - Optional specific fd number to use
- `flags` (number) - Optional flags (e.g., O_CLOEXEC)
- `lowest` (number) - Optional lowest acceptable fd number

**Returns:**

- number - New file descriptor on success
- string - Error message on failure

### pipe

```teal
function pipe(flags?: number): PipeResult, string
```

 Creates a pipe for inter-process communication.

**Parameters:**

- `flags` (number) - Optional flags (O_CLOEXEC, O_NONBLOCK, O_DIRECT)

**Returns:**

- PipeResult - Table with reader and writer file descriptors
- string - Error message on failure

### fcntl

```teal
function fcntl(fd: number, cmd: number, ...: any): any
```

 Performs file control operations.

**Parameters:**

- `fd` (number) - The file descriptor
- `cmd` (number) - The command (F_GETFD, F_SETFD, F_GETFL, F_SETFL, etc.)
- `...` (any) - Command-specific arguments

**Returns:**

- any - Command-specific return value

### sync

```teal
function sync()
```

 Flushes all file system buffers to disk.

### fsync

```teal
function fsync(fd: number): boolean, string
```

 Flushes file data and metadata to disk.

**Parameters:**

- `fd` (number) - The file descriptor

**Returns:**

- boolean - True on success
- string - Error message on failure

### fdatasync

```teal
function fdatasync(fd: number): boolean, string
```

 Flushes file data to disk (but not necessarily metadata).

**Parameters:**

- `fd` (number) - The file descriptor

**Returns:**

- boolean - True on success
- string - Error message on failure

### slurp

```teal
function slurp(path: string): string, string
```

 Reads entire file contents.

**Parameters:**

- `path` (string) - The path to the file

**Returns:**

- string - File contents on success
- string - Error message on failure (nil contents)

### barf

```teal
function barf(path: string, data: string, mode?: number): boolean, string
```

 Writes data to a file, creating or overwriting it.

**Parameters:**

- `path` (string) - The path to the file
- `data` (string) - The data to write
- `mode` (number) - Optional file mode (e.g., 0644)

**Returns:**

- boolean - True on success
- string - Error message on failure
