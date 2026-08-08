# fs

 Unified filesystem module.
 Combines path manipulation, filesystem operations, and directory
 walking. Operations are named in English (#988): the POSIX names
 that survive are the effectively-English concepts recorded in D20's
 kept set (stat, statfs, symlink, readlink, truncate, dirname,
 basename); everything else spells the operation out.

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
  --  Expand a leading "~" or "~/" to the home directory (#988: was
  --  expanduser).
  expand_user: function(p: string): string
  --  True when the path names something (file, dir, special) — #988:
  --  was exists.
  is_present: function(path: string): boolean
  is_file: function(path: string): boolean
  is_dir: function(path: string): boolean
  is_link: function(path: string): boolean
  --  True for POSIX ("/x"), drive-letter ("C:/x", "C:\x"), and UNC
  --  ("\\server\share") absolute paths.
  is_absolute: function(p: string): boolean
  --  THE zip-slip guard shared by zip/tar/embed (#988: was
  --  unsafe_entry_name); see cosmic.fs.path.
  is_unsafe_entry_name: function(name: string): boolean
  normalize: function(p: string): string
  --  Prepend cwd to a relative path (#988: was abspath).
  absolute_path: function(p: string): string
  --  Make p relative to base, default cwd (#988: was relpath).
  relative_path: function(p: string, base?: string): string
  --  Split into root and dot-extension (#988: was splitext).
  split_extension: function(p: string): string, string
  stat: function(path: string): Stat | nil, string
  --  Stat the link itself, not its target (#988: was lstat).
  stat_link: function(path: string): Stat | nil, string
  --  Stat an open descriptor (#988: was fstat).
  stat_fd: function(fd: integer): Stat | nil, string
  --  Create one directory (#988: was mkdir); parents must exist.
  make_dir: function(path: string, mode?: integer): boolean, string
  make_dirs: function(path: string, mode?: integer): boolean, string
  --  Remove one empty directory (#988: was rmdir).
  remove_dir: function(path: string): boolean, string
  --  Change the working directory (#988: was chdir; cwd() reads it).
  set_cwd: function(path: string): boolean, string
  cwd: function(): string | nil, string
  --  Open a directory handle (#988: was opendir).
  open_dir: function(path: string): Dir | nil, string
  --  Open a directory handle from a descriptor (#988: was fdopendir).
  open_dir_fd: function(fd: integer): Dir | nil, string
  read: function(path: string): string | nil, string
  --  Write a file; opts carries mode and atomic (#988: write_atomic
  --  folded in; a bare-integer mode still works until pin advance).
  write: function(path: string, data: string, opts?: fs_file.WriteOptions | integer): boolean, string
  truncate: function(path: string, length?: integer): boolean, string
  --  Remove a file or symlink (#988: was unlink); directories go
  --  through remove_dir()/remove_all().
  remove: function(path: string): boolean, string
  copy: function(src: string, dst: string): boolean, string
  --  Rename, falling back to copy+remove across filesystems. The
  --  strict-superset fs.rename is deleted (#988).
  move: function(oldpath: string, newpath: string): boolean, string
  touch: function(path: string, mode?: integer): boolean, string
  link: function(existingpath: string, newpath: string): boolean, string
  symlink: function(target: string, linkpath: string): boolean, string
  readlink: function(path: string): string | nil, string
  --  Canonical absolute path via the filesystem (#988: was realpath).
  resolve: function(path: string): string | nil, string
  remove_all: function(path: string): boolean, string
  copy_tree: function(src: string, dst: string): boolean, string
  --  May the process access path this way (R_OK/W_OK/X_OK)? #988: was
  --  access, whose parameterless form duplicated is_present.
  is_accessible: function(path: string, mode: integer): boolean
  --  Set permission bits (#988: was chmod).
  set_mode: function(path: string, mode: integer): boolean, string
  --  Set the file mode creation mask, returning the previous one
  --  (#993: moved from cosmic.user).
  set_umask: function(mask: integer): integer
  --  Set owner and group (#988: was chown).
  set_owner: function(path: string, uid: integer, gid: integer): boolean, string
  set_times: function(path: string, times: fs_ops.Times): boolean, string
  set_times_fd: function(fd: integer, times: fs_ops.Times): boolean, string
  --  Template defaults to $TMPDIR/cosmic_XXXXXX (#988).
  temp_dir: function(template?: string): string | nil, string
  temp_file: function(template?: string): fs_ops.TempFile | nil, string
  --  An anonymous temp file as an open Handle (#988: was a bare fd).
  temp_fd: function(): Handle | nil, string
  statfs: function(path: string): Statfs | nil, string
  --  statfs on an open descriptor (#988: was fstatfs).
  statfs_fd: function(fd: integer): Statfs | nil, string
  --  Flush all filesystem buffers to disk, system-wide (sync(2)) —
  --  #988: was sync, ambiguous beside Handle:sync's one-file flush.
  sync_all: function()
  --  Walk dir depth-first with an Entry visitor: visitor(e: fs.Entry,
  --  ctx) may return "skip" (don't descend) or "stop" (end now).
  --  Slot 2 is the root-open failure; subtree errors come back in
  --  slot 3 as a list (nil when the walk was clean).
  visit: function<T>(dir: string, visitor: function(Entry, T): (WalkAction ...), ctx?: T, opts?: WalkOptions): T | nil, string, {string}
  --  Expand a glob pattern without recursing; components ("src/*.lua")
  --  are each globs, and matches of every entry type are returned
  --  sorted. Slot 2 is the root failure; deeper errors in slot 3.
  glob: function(dir: string, pattern: string): {string} | nil, string, {string}
  --  Collect paths under dir; FindOptions selects basenames (glob or
  --  Lua pattern) and bounds the search (max_depth, recursive,
  --  include_dirs, sorted). Slot 2 is the root failure; subtree errors
  --  in slot 3.
  find: function(dir: string, opts?: fs_find.FindOptions): {string} | nil, string, {string}
  --  Iterate paths under dir lazily; same selection as find() except
  --  sorted. The exhausted iterator returns nil plus the subtree-error
  --  list.
  find_iter: function(dir: string, opts?: fs_find.FindOptions): FileIter | nil, string, any, any
  --  Matching files with their FileInfo, keyed by FULL path (#987:
  --  was relative); same options and slots as find.
  find_info: function(dir: string, opts?: fs_find.FindOptions): {string: FileInfo} | nil, string, {string}
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
