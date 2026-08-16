# fs

 Unified filesystem module.
 Combines path manipulation, filesystem operations, and directory
 walking. Operations are named in English: the POSIX names that
 survive are the ones already effectively English (stat, statfs,
 symlink, readlink, truncate, dirname, basename); everything else
 spells the operation out.

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
  expand_user: function(p: string): string
  --  True when the path names something (file, dir, special).
  is_present: function(path: string): boolean
  is_file: function(path: string): boolean
  is_dir: function(path: string): boolean
  is_link: function(path: string): boolean
  --  True for POSIX ("/x"), drive-letter ("C:/x", "C:\x"), and UNC
  --  ("\\server\share") absolute paths.
  is_absolute: function(p: string): boolean
  --  THE zip-slip guard shared by zip/tar/embed; see cosmic.fs.path.
  is_unsafe_entry_name: function(name: string): boolean
  normalize: function(p: string): string
  --  Prepend cwd to a relative path.
  absolute_path: function(p: string): string
  --  Make p relative to base, default cwd.
  relative_path: function(p: string, base?: string): string
  --  Split into root and dot-extension.
  split_extension: function(p: string): string, string
  stat: function(path: string): Stat | nil, string
  --  Stat the link itself, not its target.
  stat_link: function(path: string): Stat | nil, string
  --  Stat an open descriptor.
  stat_fd: function(fd: integer): Stat | nil, string
  --  Create one directory; parents must exist.
  make_dir: function(path: string, mode?: integer): boolean, string
  make_dirs: function(path: string, mode?: integer): boolean, string
  --  Remove one empty directory.
  remove_dir: function(path: string): boolean, string
  --  Change the working directory; cwd() reads it.
  set_cwd: function(path: string): boolean, string
  cwd: function(): string | nil, string
  --  Open a directory handle.
  open_dir: function(path: string): Dir | nil, string
  --  Open a directory handle from a descriptor.
  open_dir_fd: function(fd: integer): Dir | nil, string
  read: function(path: string): string | nil, string
  --  Write a file; opts carries mode and atomic.
  write: function(path: string, data: string, opts?: fs_file.WriteOptions): boolean, string
  truncate: function(path: string, length?: integer): boolean, string
  --  Remove a file or symlink; directories go through
  --  remove_dir()/remove_all().
  remove: function(path: string): boolean, string
  copy: function(src: string, dst: string): boolean, string
  --  Rename, falling back to copy+remove across filesystems.
  move: function(oldpath: string, newpath: string): boolean, string
  touch: function(path: string, mode?: integer): boolean, string
  link: function(existingpath: string, newpath: string): boolean, string
  symlink: function(target: string, linkpath: string): boolean, string
  readlink: function(path: string): string | nil, string
  --  Canonical absolute path via the filesystem.
  resolve: function(path: string): string | nil, string
  remove_all: function(path: string): boolean, string
  copy_tree: function(src: string, dst: string): boolean, string
  --  May the process access path this way (R_OK/W_OK/X_OK)? A
  --  parameterless form would duplicate is_present, so the mode is
  --  required.
  is_accessible: function(path: string, mode: integer): boolean
  --  Set permission bits.
  set_mode: function(path: string, mode: integer): boolean, string
  --  Parse octal digits ("755") into the integer a mode argument wants.
  --  Infallible: anything not matching `^[0-7]+$` yields 0.
  octal: function(digits: string): integer
  --  Set the file mode creation mask, returning the previous one.
  set_umask: function(mask: integer): integer
  --  Set owner and group.
  set_owner: function(path: string, uid: integer, gid: integer): boolean, string
  set_times: function(path: string, times: fs_ops.Times): boolean, string
  set_times_fd: function(fd: integer, times: fs_ops.Times): boolean, string
  --  Template defaults to $TMPDIR/cosmic_XXXXXX.
  temp_dir: function(template?: string): string | nil, string
  temp_file: function(template?: string): fs_ops.TempFile | nil, string
  --  An anonymous temp file as an open Handle.
  temp_fd: function(): Handle | nil, string
  statfs: function(path: string): Statfs | nil, string
  --  statfs on an open descriptor.
  statfs_fd: function(fd: integer): Statfs | nil, string
  --  Flush all filesystem buffers to disk, system-wide (sync(2)) —
  --  distinct from Handle:sync's one-file flush.
  sync_all: function()
  --  Walk dir depth-first with an Entry visitor: visitor(e: fs.Entry,
  --  ctx) may return "skip" (don't descend) or "stop" (end now).
  --  Slot 2 is the root-open failure; subtree errors ride on the
  --  result as `.errors` (nil when the walk was clean).
  visit: function<T>(dir: string, visitor: function(Entry, T): (WalkAction ...), ctx?: T, opts?: WalkOptions): Walked | nil, string
  --  Expand a glob pattern without recursing; components ("src/*.lua")
  --  are each globs, and matches of every entry type are returned
  --  sorted. Slot 2 is the root failure; deeper errors in `.errors`.
  glob: function(dir: string, pattern: string): Found | nil, string
  --  Collect paths under dir; FindOptions selects basenames (glob or
  --  Lua pattern) and bounds the search (max_depth, recursive,
  --  include_dirs, sorted). Slot 2 is the root failure; subtree errors
  --  in `.errors`.
  find: function(dir: string, opts?: fs_find.FindOptions): Found | nil, string
  --  Iterate paths under dir lazily; same selection as find() except
  --  sorted. The exhausted iterator returns nil plus the subtree-error
  --  list; the iterator itself is the closeable handle, so a loop that
  --  stops early wants `<close>` — or `visit`, which owns its loop.
  find_iter: function(dir: string, opts?: fs_find.FindOptions): FileIter | nil, string
  --  Matching files with their FileInfo, keyed by FULL path; same
  --  options and slots as find.
  find_info: function(dir: string, opts?: fs_find.FindOptions): FoundInfo | nil, string
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
  fstatfs: function(fd: integer): Statfs | nil, string
  sync: function()
end
```

### WalkStat

alias of `cosmic.fs.types.WalkStat` — field and method table: `cosmic --docs cosmic.fs.types.WalkStat`

### Handle

alias of `cosmic.fd.Handle` — field and method table: `cosmic --docs cosmic.fd.Handle`

### FileIter

 Iterator over file paths, as returned by find_iter().

alias of `cosmic.fs.find.FileIter` — field and method table: `cosmic --docs cosmic.fs.find.FileIter`

### WalkAction

 Visitor verdict for visit()/walk(): nil continues, "skip" prunes,
 "stop" ends the walk.

alias of `cosmic.fs.walk.WalkAction` — field and method table: `cosmic --docs cosmic.fs.walk.WalkAction`

### WalkOptions

 Options for visit()/walk() (max_depth).

alias of `cosmic.fs.walk.WalkOptions` — field and method table: `cosmic --docs cosmic.fs.walk.WalkOptions`

### Entry

 One visited entry (path/name/stat/depth), as visit() hands to its
 visitor.

alias of `cosmic.fs.types.Entry` — field and method table: `cosmic --docs cosmic.fs.types.Entry`
