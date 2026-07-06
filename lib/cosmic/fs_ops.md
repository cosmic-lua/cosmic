# fs_ops

 Filesystem file operations, permissions, timestamps, and temp files.
 Internal submodule used by cosmic.fs.

## Types

### FsOpsModule

```teal
local record FsOpsModule
  unlink: function(path: string): boolean, string
  rename: function(oldpath: string, newpath: string): boolean, string
  link: function(existingpath: string, newpath: string): boolean, string
  symlink: function(target: string, linkpath: string): boolean, string
  readlink: function(path: string): string | nil, string
  realpath: function(path: string): string | nil, string
  rmrf: function(path: string): boolean, string
  access: function(path: string, mode: number): boolean
  chmod: function(path: string, mode: number): boolean, string
  chown: function(path: string, uid: number, gid: number): boolean, string
  utimensat: function(path: string, atime_secs: number, atime_nsecs: number, mtime_secs: number, mtime_nsecs: number): boolean, string
  futimens: function(fd: number, atime_secs: number, atime_nsecs: number, mtime_secs: number, mtime_nsecs: number): boolean, string
  mkdtemp: function(template: string): string | nil, string
  mkstemp: function(template: string): number | nil, string
  tmpfd: function(): number | nil, string
  statfs: function(path: string): Statfs | nil, string
  fstatfs: function(fd: number): Statfs | nil, string
  major: function(dev: number): number
  minor: function(dev: number): number
  F_OK: number
  R_OK: number
  W_OK: number
  X_OK: number
end
```

## Functions

### unlink

```teal
function unlink(path: string): boolean, string
```

 Remove a file or symbolic link.
 Does not remove directories; use rmdir() or rmrf() for that.

**Parameters:**

- `path` (string) - Path to the file to remove

**Returns:**

- boolean - True on success
- string - Error message if failed

### rename

```teal
function rename(oldpath: string, newpath: string): boolean, string
```

 Rename or move a file or directory.

**Parameters:**

- `oldpath` (string) - Current path
- `newpath` (string) - New path

**Returns:**

- boolean - True on success
- string - Error message if failed

### link

```teal
function link(existingpath: string, newpath: string): boolean, string
```

 Create a hard link.

**Parameters:**

- `existingpath` (string) - Path to the existing file
- `newpath` (string) - Path for the new link

**Returns:**

- boolean - True on success
- string - Error message if failed

### symlink

```teal
function symlink(target: string, linkpath: string): boolean, string
```

 Create a symbolic link.

**Parameters:**

- `target` (string) - Content of the symlink (where it points)
- `linkpath` (string) - Path where the symlink will be created

**Returns:**

- boolean - True on success
- string - Error message if failed

### readlink

```teal
function readlink(path: string): string | nil, string
```

 Read the target of a symbolic link.

**Parameters:**

- `path` (string) - Path to the symbolic link

**Returns:**

- string - | nil The symlink target, or nil on error
- string - Error message if failed

### realpath

```teal
function realpath(path: string): string | nil, string
```

 Get the canonical absolute path.
 Resolves all symbolic links and removes . and .. components.

**Parameters:**

- `path` (string) - Path to resolve

**Returns:**

- string - | nil Canonical path, or nil on error
- string - Error message if failed

### rmrf

```teal
function rmrf(path: string): boolean, string
```

 Recursively remove a directory and all its contents.
 Use with caution.

**Parameters:**

- `path` (string) - Path to the directory to remove

**Returns:**

- boolean - True on success
- string - Error message if failed

### access

```teal
function access(path: string, mode: number): boolean
```

 Check if the current process has access to a file.

**Parameters:**

- `path` (string) - Path to check
- `mode` (number) - Access mode: F_OK (exists), R_OK, W_OK, X_OK

**Returns:**

- boolean - True if access is allowed

### chmod

```teal
function chmod(path: string, mode: number): boolean, string
```

 Change file permissions.

**Parameters:**

- `path` (string) - Path to the file
- `mode` (number) - New permission bits (e.g., 0644)

**Returns:**

- boolean - True on success
- string - Error message if failed

### chown

```teal
function chown(path: string, uid: number, gid: number): boolean, string
```

 Change file owner and group.

**Parameters:**

- `path` (string) - Path to the file
- `uid` (number) - New owner user ID
- `gid` (number) - New owner group ID

**Returns:**

- boolean - True on success
- string - Error message if failed

### utimensat

```teal
function utimensat(path: string, atime_secs: number, atime_nsecs: number, mtime_secs: number, mtime_nsecs: number): boolean, string
```

 Change file access and modification times.

**Parameters:**

- `path` (string) - Path to the file
- `atime_secs` (number) - Access time seconds (nil to keep current)
- `atime_nsecs` (number) - Access time nanoseconds
- `mtime_secs` (number) - Modification time seconds (nil to keep current)
- `mtime_nsecs` (number) - Modification time nanoseconds

**Returns:**

- boolean - True on success
- string - Error message if failed

### futimens

```teal
function futimens(fd: number, atime_secs: number, atime_nsecs: number, mtime_secs: number, mtime_nsecs: number): boolean, string
```

 Change file access and modification times on a file descriptor.

**Parameters:**

- `fd` (number) - File descriptor
- `atime_secs` (number) - Access time seconds (nil to keep current)
- `atime_nsecs` (number) - Access time nanoseconds
- `mtime_secs` (number) - Modification time seconds (nil to keep current)
- `mtime_nsecs` (number) - Modification time nanoseconds

**Returns:**

- boolean - True on success
- string - Error message if failed

### mkdtemp

```teal
function mkdtemp(template: string): string | nil, string
```

 Create a temporary directory.

**Parameters:**

- `template` (string) - Path template ending in XXXXXX

**Returns:**

- string - | nil Path to the created directory, or nil on error
- string - Error message if failed

### mkstemp

```teal
function mkstemp(template: string): number | nil, string
```

 Create a temporary file.

**Parameters:**

- `template` (string) - Path template ending in XXXXXX

**Returns:**

- number - | nil File descriptor, or nil on error
- string - Path to the created file, or error message

### tmpfd

```teal
function tmpfd(): number | nil, string
```

 Create a temporary file descriptor.

**Returns:**

- number - | nil File descriptor, or nil on error
- string - Error message if failed

### statfs

```teal
function statfs(path: string): Statfs | nil, string
```

 Get filesystem statistics for a path.

**Parameters:**

- `path` (string) - Path to any file on the filesystem

**Returns:**

- Statfs - | nil Filesystem statistics, or nil on error
- string - Error message if failed

### fstatfs

```teal
function fstatfs(fd: number): Statfs | nil, string
```

 Get filesystem statistics from a file descriptor.

**Parameters:**

- `fd` (number) - File descriptor

**Returns:**

- Statfs - | nil Filesystem statistics, or nil on error
- string - Error message if failed

### major

```teal
function major(dev: number): number
```

 Extract major device number from a device ID.

**Parameters:**

- `dev` (number) - Device ID from stat

**Returns:**

- number - Major device number

### minor

```teal
function minor(dev: number): number
```

 Extract minor device number from a device ID.

**Parameters:**

- `dev` (number) - Device ID from stat

**Returns:**

- number - Minor device number
