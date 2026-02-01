# fs

 Filesystem operations.
 Wraps cosmo.unix for file and directory operations: stat, mkdir, chmod, symlink, etc.

## Types

### Stat

 File or directory metadata.
 Use is_dir(), is_file(), etc. to check file type.

```teal
local record Stat
  --  Returns file size in bytes.
  size: function(self: Stat): number
  --  Returns file mode (permissions and type bits).
  mode: function(self: Stat): number
  --  Returns owner user ID.
  uid: function(self: Stat): number
  --  Returns owner group ID.
  gid: function(self: Stat): number
  --  Returns birth time as seconds, nanoseconds.
  birthtim: function(self: Stat): number, number
  --  Returns modification time as seconds, nanoseconds.
  mtim: function(self: Stat): number, number
  --  Returns access time as seconds, nanoseconds.
  atim: function(self: Stat): number, number
  --  Returns status change time as seconds, nanoseconds.
  ctim: function(self: Stat): number, number
  --  Returns number of 512-byte blocks allocated.
  blocks: function(self: Stat): number
  --  Returns number of hard links.
  nlink: function(self: Stat): number
end
```

### Dir

 Handle for reading directory entries.

```teal
local record Dir
  --  Reads next directory entry. Returns nil when done.
  read: function(self: Dir): string
  --  Closes directory handle.
  close: function(self: Dir)
  --  Returns file descriptor for this directory.
  fd: function(self: Dir): number
  --  Rewinds to beginning of directory.
  rewind: function(self: Dir)
  --  Returns current position in directory stream.
  tell: function(self: Dir): number
end
```

### FsModule

 Module interface

```teal
local record FsModule
  stat: function(path: string, follow_symlinks?: boolean): Stat, string
  fstat: function(fd: number): Stat, string
  is_dir: function(mode: number): boolean
  is_file: function(mode: number): boolean
  is_link: function(mode: number): boolean
  is_block_device: function(mode: number): boolean
  is_char_device: function(mode: number): boolean
  is_fifo: function(mode: number): boolean
  is_socket: function(mode: number): boolean
  mkdir: function(path: string, mode?: number): boolean, string
  makedirs: function(path: string, mode?: number): boolean, string
  rmdir: function(path: string): boolean, string
  chdir: function(path: string): boolean, string
  getcwd: function(): string, string
  opendir: function(path: string): Dir, string
  fdopendir: function(fd: number): Dir, string
  unlink: function(path: string): boolean, string
  rename: function(oldpath: string, newpath: string): boolean, string
  link: function(existingpath: string, newpath: string): boolean, string
  symlink: function(target: string, linkpath: string): boolean, string
  readlink: function(path: string): string, string
  realpath: function(path: string): string, string
  rmrf: function(path: string): boolean, string
  access: function(path: string, mode: number): boolean
  chmod: function(path: string, mode: number): boolean, string
  chown: function(path: string, uid: number, gid: number): boolean, string
  utimensat: function(path: string, atime_secs: number, atime_nsecs: number, mtime_secs: number, mtime_nsecs: number): boolean, string
  futimens: function(fd: number, atime_secs: number, atime_nsecs: number, mtime_secs: number, mtime_nsecs: number): boolean, string
  mkdtemp: function(template: string): string, string
  mkstemp: function(template: string): number, string
  tmpfd: function(): number, string
  F_OK: number
  R_OK: number
  W_OK: number
  X_OK: number
end
```

## Functions

### stat

```teal
function stat(path: string, follow_symlinks?: boolean): Stat, string
```

 Get file metadata.
 Follows symbolic links by default.

**Parameters:**

- `path` (string) - Path to the file or directory
- `follow_symlinks` (boolean) - Whether to follow symlinks (default true)

**Returns:**

- Stat - File metadata, or nil on error
- string - Error message if failed

### fstat

```teal
function fstat(fd: number): Stat, string
```

 Get file metadata from file descriptor.

**Parameters:**

- `fd` (number) - File descriptor

**Returns:**

- Stat - File metadata, or nil on error
- string - Error message if failed

### is_dir

```teal
function is_dir(mode: number): boolean
```

 Check if mode represents a directory.

**Parameters:**

- `mode` (number) - File mode from stat

**Returns:**

- boolean - True if directory

### is_file

```teal
function is_file(mode: number): boolean
```

 Check if mode represents a regular file.

**Parameters:**

- `mode` (number) - File mode from stat

**Returns:**

- boolean - True if regular file

### is_link

```teal
function is_link(mode: number): boolean
```

 Check if mode represents a symbolic link.

**Parameters:**

- `mode` (number) - File mode from stat

**Returns:**

- boolean - True if symbolic link

### is_block_device

```teal
function is_block_device(mode: number): boolean
```

 Check if mode represents a block device.

**Parameters:**

- `mode` (number) - File mode from stat

**Returns:**

- boolean - True if block device

### is_char_device

```teal
function is_char_device(mode: number): boolean
```

 Check if mode represents a character device.

**Parameters:**

- `mode` (number) - File mode from stat

**Returns:**

- boolean - True if character device

### is_fifo

```teal
function is_fifo(mode: number): boolean
```

 Check if mode represents a FIFO (named pipe).

**Parameters:**

- `mode` (number) - File mode from stat

**Returns:**

- boolean - True if FIFO

### is_socket

```teal
function is_socket(mode: number): boolean
```

 Check if mode represents a socket.

**Parameters:**

- `mode` (number) - File mode from stat

**Returns:**

- boolean - True if socket

### mkdir

```teal
function mkdir(path: string, mode?: number): boolean, string
```

 Create a directory.
 Parent directories must exist. Use makedirs() to create parents.

**Parameters:**

- `path` (string) - Path to the directory to create
- `mode` (number) - Permission bits (default 0755)

**Returns:**

- boolean - True on success
- string - Error message if failed

### makedirs

```teal
function makedirs(path: string, mode?: number): boolean, string
```

 Create a directory and any missing parent directories.

**Parameters:**

- `path` (string) - Path to the directory to create
- `mode` (number) - Permission bits (default 0755)

**Returns:**

- boolean - True on success
- string - Error message if failed

### rmdir

```teal
function rmdir(path: string): boolean, string
```

 Remove an empty directory.

**Parameters:**

- `path` (string) - Path to the directory to remove

**Returns:**

- boolean - True on success
- string - Error message if failed

### chdir

```teal
function chdir(path: string): boolean, string
```

 Change current working directory.

**Parameters:**

- `path` (string) - Path to the new working directory

**Returns:**

- boolean - True on success
- string - Error message if failed

### getcwd

```teal
function getcwd(): string, string
```

 Get current working directory.

**Returns:**

- string - Current working directory path
- string - Error message if failed

### opendir

```teal
function opendir(path: string): Dir, string
```

 Open a directory for reading.
 Call dir:read() to iterate entries, dir:close() when done.

**Parameters:**

- `path` (string) - Path to the directory

**Returns:**

- Dir - Directory handle, or nil on error
- string - Error message if failed

### fdopendir

```teal
function fdopendir(fd: number): Dir, string
```

 Open a directory from a file descriptor.

**Parameters:**

- `fd` (number) - File descriptor for an open directory

**Returns:**

- Dir - Directory handle, or nil on error
- string - Error message if failed

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
function readlink(path: string): string, string
```

 Read the target of a symbolic link.

**Parameters:**

- `path` (string) - Path to the symbolic link

**Returns:**

- string - The symlink target, or nil on error
- string - Error message if failed

### realpath

```teal
function realpath(path: string): string, string
```

 Get the canonical absolute path.
 Resolves all symbolic links and removes . and .. components.

**Parameters:**

- `path` (string) - Path to resolve

**Returns:**

- string - Canonical path, or nil on error
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
 Pass nil for either time to leave it unchanged.

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
function mkdtemp(template: string): string, string
```

 Create a temporary directory.
 The template must end with XXXXXX which will be replaced with random characters.

**Parameters:**

- `template` (string) - Path template ending in XXXXXX

**Returns:**

- string - Path to the created directory, or nil on error
- string - Error message if failed

### mkstemp

```teal
function mkstemp(template: string): number, string
```

 Create a temporary file.
 The template must end with XXXXXX which will be replaced with random characters.
 Returns both the file descriptor and the path.

**Parameters:**

- `template` (string) - Path template ending in XXXXXX

**Returns:**

- number - File descriptor, or nil on error
- string - Path to the created file, or error message

### tmpfd

```teal
function tmpfd(): number, string
```

 Create a temporary file descriptor.
 The file is automatically deleted when closed.

**Returns:**

- number - File descriptor, or nil on error
- string - Error message if failed

## Examples

### basic

 Example demonstrating basic fs operations

```teal
  local fs = require("cosmic.fs")
  local path = require("cosmo.path")

  -- Create a temp directory
  local tmpdir = fs.mkdtemp("/tmp/fs_example_XXXXXX")
  if not tmpdir then
    print("failed to create temp dir")
    return
  end
  print("created temp dir:", tmpdir)

  -- Create a subdirectory
  local subdir = path.join(tmpdir, "subdir")
  local ok, err = fs.mkdir(subdir)
  if not ok then
    print("mkdir failed:", err)
    fs.rmrf(tmpdir)
    return
  end

  -- Check if it exists
  local st = fs.stat(subdir)
  if st and fs.is_dir(st:mode()) then
    print("subdir is a directory")
  end

  -- Create a symlink
  local linkpath = path.join(tmpdir, "link")
  ok, err = fs.symlink(subdir, linkpath)
  if ok then
    local target = fs.readlink(linkpath)
    print("symlink points to:", target)
  end

  -- Clean up
  fs.rmrf(tmpdir)
  print("cleaned up")
```

Output:
```
created temp dir:	/tmp/fs_example_XXXXXX (with random suffix)
  -- subdir is a directory
  -- symlink points to:	/tmp/fs_example_XXXXXX/subdir
  -- cleaned up

```
