# file

 Whole-file content operations: read, write, truncate, write_atomic.
 Internal submodule used by cosmic.fs.

## Types

### FsFileModule

```teal
local record FsFileModule
  read: function(path: string): string | nil, string
  write: function(path: string, data: string, mode?: number): boolean, string
  truncate: function(path: string, length?: number): boolean, string
  write_atomic: function(path: string, data: string, mode?: number): boolean, string
end
```

## Functions

### read

```teal
function read(path: string): string | nil, string
```

 Read entire file contents.

**Parameters:**

- `path` (string) - Path to the file

**Returns:**

- string - | nil File contents, or nil on error
- string - Error message if failed

### write

```teal
function write(path: string, data: string, mode?: number): boolean, string
```

 Write data to a file, creating or overwriting it.

**Parameters:**

- `path` (string) - Path to the file
- `data` (string) - Data to write
- `mode` (number) - Permission bits when creating (default 0644)

**Returns:**

- boolean - True on success
- string - Error message if failed

### truncate

```teal
function truncate(path: string, length?: number): boolean, string
```

 Truncate a file to the given length (default 0).

**Parameters:**

- `path` (string) - Path to the file
- `length` (number) - New length in bytes (default 0)

**Returns:**

- boolean - True on success
- string - Error message if failed

### write_atomic

```teal
function write_atomic(path: string, data: string, mode?: number): boolean, string
```

 Write data to a file atomically: write to a temporary file in the
 same directory, fsync it, then rename over the destination. Readers
 see either the old contents or the complete new contents, never a
 partial write; on failure the original file is untouched and the
 temporary file is removed.

**Parameters:**

- `path` (string) - Destination path
- `data` (string) - Data to write
- `mode` (number) - Permission bits for the file (default 0644)

**Returns:**

- boolean - True on success
- string - Error message if failed
