--- Unified filesystem module.
--- Combines path manipulation, filesystem operations, and directory
--- walking. Operations are named in English (#988): the POSIX names
--- that survive are the effectively-English concepts recorded in D20's
--- kept set (stat, statfs, symlink, readlink, truncate, dirname,
--- basename); everything else spells the operation out, and each old
--- name remains as a DEPRECATED alias until the pin advance.
local unix = require("cosmo.unix")
local types = require("cosmic.fs.types")
local Stat = types.Stat
local Dir = types.Dir
local Statfs = types.Statfs
local type WalkStat = types.WalkStat
local FileInfo = types.FileInfo

-- The submodule shards this surface re-exports
local fs_path = require("cosmic.fs.path")
local fs_ops = require("cosmic.fs.ops")
local fs_file = require("cosmic.fs.file")
local fs_dir = require("cosmic.fs.dir")
local fs_walk = require("cosmic.fs.walk")
local fs_find = require("cosmic.fs.find")
local fs_tree = require("cosmic.fs.tree")
local cfd = require("cosmic.fd")
local type Handle = cfd.Handle

--- Iterator over file paths, as returned by find_iter().
local type FileIter = fs_find.FileIter

--- Visitor verdict for visit()/walk(): nil continues, "skip" prunes,
--- "stop" ends the walk.
local type WalkAction = fs_walk.WalkAction

--- Options for visit()/walk() (max_depth).
local type WalkOptions = fs_walk.WalkOptions

--- One visited entry (path/name/stat/depth), as visit() hands to its
--- visitor.
local type Entry = types.Entry

--- Module interface
local record FsModule
  --- Iterator over file paths, as returned by find_iter().
  type FileIter = FileIter

  --- The types this module's own signatures return, exported so
  --- callers can name them without importing the cosmic.fs.types
  --- shard: `local st: fs.Stat`, `function f(d: fs.Dir)`.
  type Stat = Stat
  type Statfs = Statfs
  type Dir = Dir
  type FileInfo = FileInfo
  type WalkStat = WalkStat
  --- fd.Handle, as returned by temp_fd(); TempFile is temp_file()'s
  --- handle+path record (#988: was TmpFile).
  type Handle = Handle
  type TempFile = fs_ops.TempFile
  --- One timestamp (secs, nsecs) and the pair set_times applies;
  --- Stat:times() returns a Times, so stat(src):times() round-trips.
  type Timespec = fs_ops.Timespec
  type Times = fs_ops.Times
  --- Options for write(): mode (exact permission bits), atomic
  --- (same-directory temp file + fsync + rename).
  type WriteOptions = fs_file.WriteOptions

  --- Visitor verdict for visit()/walk(): nil continues, "skip" prunes,
  --- "stop" ends the walk.
  type WalkAction = WalkAction

  --- Options for visit()/walk() (max_depth; entries directly in dir
  --- are depth 1).
  type WalkOptions = WalkOptions

  -- Path manipulation
  dirname: function(str: string): string
  basename: function(str: string): string
  join: function(...: string): string
  --- Current user's home directory (nil + error when unset).
  home: function(): string | nil, string
  --- Expand a leading "~" or "~/" to the home directory (#988: was
  --- expanduser).
  expand_user: function(p: string): string
  --- True when the path names something (file, dir, special) — #988:
  --- was exists.
  is_present: function(path: string): boolean
  is_file: function(path: string): boolean
  is_dir: function(path: string): boolean
  is_link: function(path: string): boolean
  --- True for POSIX ("/x"), drive-letter ("C:/x", "C:\x"), and UNC
  --- ("\\server\share") absolute paths.
  is_absolute: function(p: string): boolean
  --- THE zip-slip guard shared by zip/tar/embed (#988: was
  --- unsafe_entry_name); see cosmic.fs.path.
  is_unsafe_entry_name: function(name: string): boolean
  normalize: function(p: string): string
  --- Prepend cwd to a relative path (#988: was abspath).
  absolute_path: function(p: string): string
  --- Make p relative to base, default cwd (#988: was relpath).
  relative_path: function(p: string, base?: string): string
  --- Split into root and dot-extension (#988: was splitext).
  split_extension: function(p: string): string, string

  -- Stat operations (stat keeps its POSIX name; the variants say how)
  stat: function(path: string): Stat | nil, string
  --- Stat the link itself, not its target (#988: was lstat).
  stat_link: function(path: string): Stat | nil, string
  --- Stat an open descriptor (#988: was fstat).
  stat_fd: function(fd: integer): Stat | nil, string

  -- Directory operations
  --- Create one directory (#988: was mkdir); parents must exist.
  make_dir: function(path: string, mode?: integer): boolean, string
  make_dirs: function(path: string, mode?: integer): boolean, string
  --- Remove one empty directory (#988: was rmdir).
  remove_dir: function(path: string): boolean, string
  --- Change the working directory (#988: was chdir; cwd() reads it).
  set_cwd: function(path: string): boolean, string
  cwd: function(): string | nil, string
  --- Open a directory handle (#988: was opendir).
  open_dir: function(path: string): Dir | nil, string
  --- Open a directory handle from a descriptor (#988: was fdopendir).
  open_dir_fd: function(fd: integer): Dir | nil, string

  -- Whole-file operations
  read: function(path: string): string | nil, string
  --- Write a file; opts carries mode and atomic (#988: write_atomic
  --- folded in; a bare-integer mode still works until pin advance).
  write: function(path: string, data: string, opts?: fs_file.WriteOptions | integer): boolean, string
  truncate: function(path: string, length?: integer): boolean, string

  -- File operations
  --- Remove a file or symlink (#988: was unlink); directories go
  --- through remove_dir()/remove_all().
  remove: function(path: string): boolean, string
  copy: function(src: string, dst: string): boolean, string
  --- Rename, falling back to copy+remove across filesystems. The
  --- strict-superset fs.rename is deleted (#988).
  move: function(oldpath: string, newpath: string): boolean, string
  touch: function(path: string, mode?: integer): boolean, string
  link: function(existingpath: string, newpath: string): boolean, string
  symlink: function(target: string, linkpath: string): boolean, string
  readlink: function(path: string): string | nil, string
  --- Canonical absolute path via the filesystem (#988: was realpath).
  resolve: function(path: string): string | nil, string
  remove_all: function(path: string): boolean, string
  copy_tree: function(src: string, dst: string): boolean, string

  -- Permission operations
  --- May the process access path this way (R_OK/W_OK/X_OK)? #988: was
  --- access, whose parameterless form duplicated is_present.
  is_accessible: function(path: string, mode: integer): boolean
  --- Set permission bits (#988: was chmod).
  set_mode: function(path: string, mode: integer): boolean, string
  --- Set the file mode creation mask, returning the previous one
  --- (#993: moved from cosmic.user).
  set_umask: function(mask: integer): integer
  --- Set owner and group (#988: was chown).
  set_owner: function(path: string, uid: integer, gid: integer): boolean, string

  -- Timestamp operations
  set_times: function(path: string, times: fs_ops.Times): boolean, string
  set_times_fd: function(fd: integer, times: fs_ops.Times): boolean, string

  -- Temporary file operations
  --- Template defaults to $TMPDIR/cosmic_XXXXXX (#988).
  temp_dir: function(template?: string): string | nil, string
  temp_file: function(template?: string): fs_ops.TempFile | nil, string
  --- An anonymous temp file as an open Handle (#988: was a bare fd).
  temp_fd: function(): Handle | nil, string

  -- Filesystem statistics
  statfs: function(path: string): Statfs | nil, string
  --- statfs on an open descriptor (#988: was fstatfs).
  statfs_fd: function(fd: integer): Statfs | nil, string

  --- Flush all filesystem buffers to disk, system-wide (sync(2)) —
  --- #988: was sync, ambiguous beside Handle:sync's one-file flush.
  sync_all: function()

  --- DEPRECATED positional walker (#987): visitor(path, name, st, ctx)
  --- with the first subtree error beside a non-nil result. Use visit().
  --- Deleted at the next pin advance.
  walk: function<T>(dir: string, visitor: function(string, string, WalkStat, T): (WalkAction ...), ctx?: T, opts?: WalkOptions): T | nil, string

  --- One visited entry: path (full — never join with name), name,
  --- stat, depth (entries directly in dir are depth 1).
  type Entry = Entry
  --- Walk dir depth-first with an Entry visitor: visitor(e: fs.Entry,
  --- ctx) may return "skip" (don't descend) or "stop" (end now).
  --- Slot 2 is the root-open failure; subtree errors come back in
  --- slot 3 as a list (nil when the walk was clean).
  visit: function<T>(dir: string, visitor: function(Entry, T): (WalkAction ...), ctx?: T, opts?: WalkOptions): T | nil, string, {string}

  --- Expand a glob pattern without recursing; components ("src/*.lua")
  --- are each globs, and matches of every entry type are returned
  --- sorted. Slot 2 is the root failure; deeper errors in slot 3.
  glob: function(dir: string, pattern: string): {string} | nil, string, {string}
  type FindOptions = fs_find.FindOptions
  --- Collect paths under dir; FindOptions selects basenames (glob or
  --- Lua pattern) and bounds the search (max_depth, recursive,
  --- include_dirs, sorted). Slot 2 is the root failure; subtree errors
  --- in slot 3.
  find: function(dir: string, opts?: fs_find.FindOptions): {string} | nil, string, {string}
  --- Iterate paths under dir lazily; same selection as find() except
  --- sorted. The exhausted iterator returns nil plus the subtree-error
  --- list.
  find_iter: function(dir: string, opts?: fs_find.FindOptions): FileIter | nil, string, any, any
  --- Matching files with their FileInfo, keyed by FULL path (#987:
  --- was relative); same options and slots as find.
  find_info: function(dir: string, opts?: fs_find.FindOptions): {string: FileInfo} | nil, string, {string}

  -- Access mode constants
  F_OK: integer
  R_OK: integer
  W_OK: integer
  X_OK: integer

  -- Dirent d_type constants, as returned by Dir:read()'s second value
  DT_BLK: integer
  DT_CHR: integer
  DT_DIR: integer
  DT_FIFO: integer
  DT_LNK: integer
  DT_REG: integer
  DT_SOCK: integer
  DT_UNKNOWN: integer

  --- DEPRECATED aliases (#988); every entry here is deleted at the
  --- next pin advance. TmpFile is TempFile; the rest alias the
  --- functions above.
  type TmpFile = fs_ops.TempFile
  expanduser: function(p: string): string
  exists: function(path: string): boolean
  unsafe_entry_name: function(name: string): boolean
  abspath: function(p: string): string
  relpath: function(p: string, base?: string): string
  splitext: function(p: string): string, string
  lstat: function(path: string): Stat | nil, string
  fstat: function(fd: integer): Stat | nil, string
  mkdir: function(path: string, mode?: integer): boolean, string
  rmdir: function(path: string): boolean, string
  chdir: function(path: string): boolean, string
  opendir: function(path: string): Dir | nil, string
  fdopendir: function(fd: integer): Dir | nil, string
  unlink: function(path: string): boolean, string
  write_atomic: function(path: string, data: string, mode?: integer): boolean, string
  realpath: function(path: string): string | nil, string
  access: function(path: string, mode?: integer): boolean
  chmod: function(path: string, mode: integer): boolean, string
  chown: function(path: string, uid: integer, gid: integer): boolean, string
  fstatfs: function(fd: integer): Statfs | nil, string
  sync: function()
end

local M: FsModule = {
  -- Path manipulation (re-exported from fs_path)
  dirname = fs_path.dirname,
  basename = fs_path.basename,
  join = fs_path.join,
  home = fs_path.home,
  expand_user = fs_path.expand_user,
  is_present = fs_path.is_present,
  is_file = fs_path.is_file,
  is_dir = fs_path.is_dir,
  is_link = fs_path.is_link,
  is_absolute = fs_path.is_absolute,
  is_unsafe_entry_name = fs_path.is_unsafe_entry_name,
  normalize = fs_path.normalize,
  absolute_path = fs_path.absolute_path,
  relative_path = fs_path.relative_path,
  split_extension = fs_path.split_extension,

  -- Stat operations (re-exported from fs_dir)
  stat = fs_dir.stat,
  stat_link = fs_dir.stat_link,
  stat_fd = fs_dir.stat_fd,

  -- Directory operations (re-exported from fs_dir)
  make_dir = fs_dir.make_dir,
  make_dirs = fs_dir.make_dirs,
  remove_dir = fs_dir.remove_dir,
  set_cwd = fs_dir.set_cwd,
  cwd = fs_dir.cwd,
  open_dir = fs_dir.open_dir,
  open_dir_fd = fs_dir.open_dir_fd,

  -- Whole-file operations (re-exported from fs_file)
  read = fs_file.read,
  write = fs_file.write,
  truncate = fs_file.truncate,

  -- File operations (re-exported from fs_ops)
  remove = fs_ops.remove,
  copy = fs_ops.copy,
  move = fs_ops.move,
  touch = fs_ops.touch,
  link = fs_ops.link,
  symlink = fs_ops.symlink,
  readlink = fs_ops.readlink,
  resolve = fs_ops.resolve,
  remove_all = fs_ops.remove_all,
  copy_tree = fs_tree.copy_tree,

  -- Permission operations (re-exported from fs_ops)
  is_accessible = fs_ops.is_accessible,
  set_mode = fs_ops.set_mode,
  set_umask = fs_ops.set_umask,
  set_owner = fs_ops.set_owner,

  -- Timestamp operations (re-exported from fs_ops)
  set_times = fs_ops.set_times,
  set_times_fd = fs_ops.set_times_fd,

  -- Temporary file operations (re-exported from fs_ops)
  temp_dir = fs_ops.temp_dir,
  temp_file = fs_ops.temp_file,
  temp_fd = fs_ops.temp_fd,

  -- Filesystem statistics (re-exported from fs_ops)
  statfs = fs_ops.statfs,
  statfs_fd = fs_ops.statfs_fd,
  sync_all = fs_ops.sync_all,

  -- Directory walking and the find family
  walk = fs_walk.walk,
  visit = fs_walk.visit,
  glob = fs_find.glob,
  find = fs_find.find,
  find_iter = fs_find.find_iter,
  find_info = fs_find.find_info,

  -- Access mode constants (re-exported from fs_ops)
  F_OK = fs_ops.F_OK,
  R_OK = fs_ops.R_OK,
  W_OK = fs_ops.W_OK,
  X_OK = fs_ops.X_OK,

  DT_BLK = unix.DT_BLK,
  DT_CHR = unix.DT_CHR,
  DT_DIR = unix.DT_DIR,
  DT_FIFO = unix.DT_FIFO,
  DT_LNK = unix.DT_LNK,
  DT_REG = unix.DT_REG,
  DT_SOCK = unix.DT_SOCK,
  DT_UNKNOWN = unix.DT_UNKNOWN,

  -- DEPRECATED aliases (#988); deleted at pin advance.
  expanduser = fs_path.expand_user,
  exists = fs_path.is_present,
  unsafe_entry_name = fs_path.is_unsafe_entry_name,
  abspath = fs_path.absolute_path,
  relpath = fs_path.relative_path,
  splitext = fs_path.split_extension,
  lstat = fs_dir.stat_link,
  fstat = fs_dir.stat_fd,
  mkdir = fs_dir.make_dir,
  rmdir = fs_dir.remove_dir,
  chdir = fs_dir.set_cwd,
  opendir = fs_dir.open_dir,
  fdopendir = fs_dir.open_dir_fd,
  unlink = fs_ops.remove,
  write_atomic = fs_file.write_atomic,
  realpath = fs_ops.resolve,
  access = fs_ops.access,
  chmod = fs_ops.set_mode,
  chown = fs_ops.set_owner,
  fstatfs = fs_ops.statfs_fd,
  sync = fs_ops.sync_all,
}

return M
