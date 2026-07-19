# fs

 Unified filesystem module.
 Combines path manipulation, filesystem operations, and directory walking.

## Types

### FsModule

 Module interface

```teal
local record FsModule
  dirname: function(str: string): string
  basename: function(str: string): string
  join: function(...: string): string
  --  Current user's home directory (nil + error when unset).
  home: function(): string | nil, string
  --  Expand a leading "~" or "~/" to the home directory.
  expanduser: function(p: string): string
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
  fstat: function(fd: integer): Stat | nil, string
  mkdir: function(path: string, mode?: integer): boolean, string
  makedirs: function(path: string, mode?: integer): boolean, string
  rmdir: function(path: string): boolean, string
  chdir: function(path: string): boolean, string
  getcwd: function(): string | nil, string
  opendir: function(path: string): Dir | nil, string
  fdopendir: function(fd: integer): Dir | nil, string
  read: function(path: string): string | nil, string
  write: function(path: string, data: string, mode?: integer): boolean, string
  truncate: function(path: string, length?: integer): boolean, string
  unlink: function(path: string): boolean, string
  rename: function(oldpath: string, newpath: string): boolean, string
  copy: function(src: string, dst: string): boolean, string
  move: function(oldpath: string, newpath: string): boolean, string
  touch: function(path: string, mode?: integer): boolean, string
  write_atomic: function(path: string, data: string, mode?: integer): boolean, string
  link: function(existingpath: string, newpath: string): boolean, string
  symlink: function(target: string, linkpath: string): boolean, string
  readlink: function(path: string): string | nil, string
  realpath: function(path: string): string | nil, string
  rmrf: function(path: string): boolean, string
  copytree: function(src: string, dst: string): boolean, string
  access: function(path: string, mode?: integer): boolean
  chmod: function(path: string, mode: integer): boolean, string
  chown: function(path: string, uid: integer, gid: integer): boolean, string
  utimensat: function(path: string, atime_secs: integer, atime_nsecs: integer, mtime_secs: integer, mtime_nsecs: integer): boolean, string
  futimens: function(fd: integer, atime_secs: integer, atime_nsecs: integer, mtime_secs: integer, mtime_nsecs: integer): boolean, string
  mkdtemp: function(template: string): string | nil, string
  tmpfile: function(template?: string): Handle | nil, string, string
  tmpfd: function(): integer | nil, string
  statfs: function(path: string): Statfs | nil, string
  fstatfs: function(fd: integer): Statfs | nil, string
  --  Flush all filesystem buffers to disk, system-wide (sync(2)).
  --  Per-file flushing is Handle:sync()/Handle:datasync() in cosmic.fd.
  sync: function()
  major: function(dev: integer): integer
  minor: function(dev: integer): integer
  --  Walk a directory tree depth-first, calling the visitor per entry.
  --  Visitor signature: visitor(path, name, st, ctx): nil | "skip" | "stop"
  --    path = full path to the entry (e.g. "dir/sub/file.txt") — do NOT join with name.
  --    name = basename of the entry (e.g. "file.txt").
  --    st   = WalkStat (import: local types = require("cosmic.fs.types"); types.WalkStat).
  --  Returning "skip" does not descend into the entry (dirs only); "stop"
  --  ends the walk now; returning nothing continues.
  --  Root open failure returns nil, err; subtree failures return the first
  --  error alongside the results.
  walk: function<T>(dir: string, visitor: function(string, string, WalkStat, T): (WalkAction ...), ctx?: T, opts?: WalkOptions): T | nil, string
  --  Expand a glob pattern without recursing; components ("src/*.lua")
  --  are each globs, and matches of every entry type are returned sorted.
  glob: function(dir: string, pattern: string): {string} | nil, string
  --  Recursively collect files under dir whose names match a glob
  --  pattern (collect's pattern is ALWAYS a glob).
  collect: function(dir: string, pattern: string): {string} | nil, string
  --  Recursively collect files under dir whose names match a Lua pattern.
  collect_matching: function(dir: string, lua_pattern: string): {string} | nil, string
  collect_all: function(dir: string): {string: FileInfo} | nil, string
  files: function(dir: string, pattern?: string): FileIter | nil, string, any, any
  F_OK: integer
  R_OK: integer
  W_OK: integer
  X_OK: integer
  DT_BLK: integer
  DT_CHR: integer
  DT_DIR: integer
  DT_FIFO: integer
  DT_LNK: integer
  DT_REG: integer
  DT_SOCK: integer
  DT_UNKNOWN: integer
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
function fstat(fd: integer): Stat | nil, string
```

 Get file metadata from file descriptor.

**Parameters:**

- `fd` (integer) - File descriptor

**Returns:**

- Stat - | nil File metadata, or nil on error
- string - Error message if failed

### mkdir

```teal
function mkdir(path: string, mode?: integer): boolean, string
```

 Create a directory.
 Parent directories must exist. Use makedirs() to create parents.

**Parameters:**

- `path` (string) - Path to the directory to create
- `mode` (integer) - Permission bits (default 0755)

**Returns:**

- boolean - True on success
- string - Error message if failed

### makedirs

```teal
function makedirs(path: string, mode?: integer): boolean, string
```

 Create a directory and any missing parent directories.

**Parameters:**

- `path` (string) - Path to the directory to create
- `mode` (integer) - Permission bits (default 0755)

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
function fdopendir(fd: integer): Dir | nil, string
```

 Open a directory from a file descriptor.
 Supports automatic cleanup with `<close>` attribute.

**Parameters:**

- `fd` (integer) - File descriptor for an open directory

**Returns:**

- Dir - | nil Directory handle, or nil on error
- string - Error message if failed
