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
  is_file: function(path: string): boolean
  is_dir: function(path: string): boolean
  is_link: function(path: string): boolean
  --  True for POSIX ("/x"), drive-letter ("C:/x", "C:\x"), and UNC
  --  ("\\server\share") absolute paths.
  is_absolute: function(p: string): boolean
  --  THE zip-slip guard shared by zip/tar/embed; see cosmic.fs.path.
  unsafe_entry_name: function(name: string): boolean
  normalize: function(p: string): string
  abspath: function(p: string): string
  relpath: function(p: string, base?: string): string
  splitext: function(p: string): string, string
  ext: function(p: string): string
  stat: function(path: string): Stat | nil, string
  lstat: function(path: string): Stat | nil, string
  fstat: function(fd: integer): Stat | nil, string
  mkdir: function(path: string, mode?: integer): boolean, string
  make_dirs: function(path: string, mode?: integer): boolean, string
  rmdir: function(path: string): boolean, string
  chdir: function(path: string): boolean, string
  cwd: function(): string | nil, string
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
  remove_all: function(path: string): boolean, string
  copy_tree: function(src: string, dst: string): boolean, string
  access: function(path: string, mode?: integer): boolean
  chmod: function(path: string, mode: integer): boolean, string
  chown: function(path: string, uid: integer, gid: integer): boolean, string
  set_times: function(path: string, times: fs_ops.Times): boolean, string
  set_times_fd: function(fd: integer, times: fs_ops.Times): boolean, string
  temp_dir: function(template: string): string | nil, string
  temp_file: function(template?: string): fs_ops.TmpFile | nil, string
  temp_fd: function(): integer | nil, string
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
  --  Recursively collect files under dir; opts selects basenames by
  --  glob or Lua pattern (default: all files).
  find: function(dir: string, opts?: fs_walk.FindOptions): {string} | nil, string
  --  Iterate files under dir lazily; same selection as find().
  find_iter: function(dir: string, opts?: fs_walk.FindOptions): FileIter | nil, string, any, any
  --  Recursively collect files under dir with their FileInfo (mode).
  find_info: function(dir: string): {string: FileInfo} | nil, string
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

### WalkStat

alias of `cosmic.fs.types.WalkStat` — field and method table: `cosmic --docs cosmic.fs.types.WalkStat`

### Handle

alias of `cosmic.fd.Handle` — field and method table: `cosmic --docs cosmic.fd.Handle`

### FileIter

 Iterator over file paths, as returned by files().

alias of `cosmic.fs.walk.FileIter` — field and method table: `cosmic --docs cosmic.fs.walk.FileIter`

### WalkAction

 Visitor verdict for walk(): nil continues, "skip" prunes, "stop" ends the walk.

alias of `cosmic.fs.walk.WalkAction` — field and method table: `cosmic --docs cosmic.fs.walk.WalkAction`

### WalkOptions

 Options for walk() (max_depth).

alias of `cosmic.fs.walk.WalkOptions` — field and method table: `cosmic --docs cosmic.fs.walk.WalkOptions`

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
 Parent directories must exist. Use make_dirs() to create parents.

**Parameters:**

- `path` (string) - Path to the directory to create
- `mode` (integer) - Permission bits (default 0755)

**Returns:**

- boolean - True on success
- string - Error message if failed

### make_dirs

```teal
function make_dirs(path: string, mode?: integer): boolean, string
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

### cwd

```teal
function cwd(): string | nil, string
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
