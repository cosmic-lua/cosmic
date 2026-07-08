# fs

 Unified filesystem module.
 Combines path manipulation, filesystem operations, and directory walking.

## Types

### RawDir

```teal
local record RawDir
  read: function(self: RawDir): string, number
  close: function(self: RawDir)
  fd: function(self: RawDir): number
  rewind: function(self: RawDir)
  tell: function(self: RawDir): number
end
```

### FsModule

 Module interface

```teal
local record FsModule
  dirname: function(str: string): string
  basename: function(str: string): string
  join: function(...: string): string
  exists: function(path: string): boolean
  isfile: function(path: string): boolean
  isdir: function(path: string): boolean
  islink: function(path: string): boolean
  normalize: function(p: string): string
  abspath: function(p: string): string
  relpath: function(p: string, base?: string): string
  splitext: function(p: string): string, string
  ext: function(p: string): string
  stat: function(path: string): Stat | nil, string
  lstat: function(path: string): Stat | nil, string
  fstat: function(fd: number): Stat | nil, string
  mkdir: function(path: string, mode?: number): boolean, string
  makedirs: function(path: string, mode?: number): boolean, string
  rmdir: function(path: string): boolean, string
  chdir: function(path: string): boolean, string
  getcwd: function(): string | nil, string
  opendir: function(path: string): Dir | nil, string
  fdopendir: function(fd: number): Dir | nil, string
  read: function(path: string): string | nil, string
  write: function(path: string, data: string, mode?: number): boolean, string
  truncate: function(path: string, length?: number): boolean, string
  unlink: function(path: string): boolean, string
  rename: function(oldpath: string, newpath: string): boolean, string
  copy: function(src: string, dst: string): boolean, string
  move: function(oldpath: string, newpath: string): boolean, string
  touch: function(path: string, mode?: number): boolean, string
  write_atomic: function(path: string, data: string, mode?: number): boolean, string
  link: function(existingpath: string, newpath: string): boolean, string
  symlink: function(target: string, linkpath: string): boolean, string
  readlink: function(path: string): string | nil, string
  realpath: function(path: string): string | nil, string
  rmrf: function(path: string): boolean, string
  copytree: function(src: string, dst: string): boolean, string
  access: function(path: string, mode?: number): boolean
  chmod: function(path: string, mode: number): boolean, string
  chown: function(path: string, uid: number, gid: number): boolean, string
  utimensat: function(path: string, atime_secs: number, atime_nsecs: number, mtime_secs: number, mtime_nsecs: number): boolean, string
  futimens: function(fd: number, atime_secs: number, atime_nsecs: number, mtime_secs: number, mtime_nsecs: number): boolean, string
  mkdtemp: function(template: string): string | nil, string
  tmpfile: function(template?: string): Handle | nil, string, string
  tmpfd: function(): number | nil, string
  statfs: function(path: string): Statfs | nil, string
  fstatfs: function(fd: number): Statfs | nil, string
  sync: function()
  major: function(dev: number): number
  minor: function(dev: number): number
  walk: function < T > (dir: string, visitor: function(string, string, WalkStat, T): (WalkAction ...), ctx?: T): T | nil, string
  collect: function(dir: string, pattern: string): {string} | nil, string
  collect_matching: function(dir: string, lua_pattern: string): {string} | nil, string
  collect_all: function(dir: string): {string: FileInfo} | nil, string
  files: function(dir: string, pattern?: string): FileIter | nil, string, any, any
  F_OK: number
  R_OK: number
  W_OK: number
  X_OK: number
  DT_BLK: number
  DT_CHR: number
  DT_DIR: number
  DT_FIFO: number
  DT_LNK: number
  DT_REG: number
  DT_SOCK: number
  DT_UNKNOWN: number
end
```

## Functions

### stat

```teal
function stat(path: string): Stat | nil, string
```

 Get file metadata.
 Follows symbolic links: stat on a symlink describes its target.
 Use lstat() to inspect the symlink itself.

**Parameters:**

- `path` (string) - Path to the file or directory

**Returns:**

- Stat - | nil File metadata, or nil on error
- string - Error message if failed

### lstat

```teal
function lstat(path: string): Stat | nil, string
```

 Get file metadata without following symbolic links.
 lstat on a symlink describes the link itself, not its target.

**Parameters:**

- `path` (string) - Path to the file or symlink

**Returns:**

- Stat - | nil File metadata, or nil on error
- string - Error message if failed

### fstat

```teal
function fstat(fd: number): Stat | nil, string
```

 Get file metadata from file descriptor.

**Parameters:**

- `fd` (number) - File descriptor

**Returns:**

- Stat - | nil File metadata, or nil on error
- string - Error message if failed

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
function getcwd(): string | nil, string
```

 Get current working directory.

**Returns:**

- string - | nil Current working directory path
- string - Error message if failed

### opendir

```teal
function opendir(path: string): Dir | nil, string
```

 Open a directory for reading.
 Call dir:read() to iterate entries, dir:close() when done.
 Supports automatic cleanup with `<close>` attribute.

**Parameters:**

- `path` (string) - Path to the directory

**Returns:**

- Dir - | nil Directory handle, or nil on error
- string - Error message if failed

### fdopendir

```teal
function fdopendir(fd: number): Dir | nil, string
```

 Open a directory from a file descriptor.
 Supports automatic cleanup with `<close>` attribute.

**Parameters:**

- `fd` (number) - File descriptor for an open directory

**Returns:**

- Dir - | nil Directory handle, or nil on error
- string - Error message if failed
