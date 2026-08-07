--- Unified filesystem module.
--- Combines path manipulation, filesystem operations, and directory walking.
local unix = require("cosmo.unix")
local types = require("cosmic.fs.types")
local errstr = require("cosmic.errno").wrap
local Stat = types.Stat
local Dir = types.Dir
local Statfs = types.Statfs
local type WalkStat = types.WalkStat
local FileInfo = types.FileInfo

-- Re-export path functions from fs_path submodule
local fs_path = require("cosmic.fs.path")

-- Re-export file operations from fs_ops / fs_file submodules
local fs_ops = require("cosmic.fs.ops")
local fs_file = require("cosmic.fs.file")
local cfd = require("cosmic.fd")
local type Handle = cfd.Handle

-- Wrap a raw unix.Dir with __close support
local function make_dir(raw: unix.Dir): Dir
  local is_closed = false

  local dir: Dir = {
    -- The second return is the dirent d_type (fs.DT_DIR / DT_REG /
    -- DT_LNK / ... / DT_UNKNOWN) where the filesystem supports it,
    -- so "is this entry a directory" needs no stat(2) call.
    read = function(_self: Dir): string, integer
      if is_closed then return nil end
      local name, kind = raw:read()
      return name, kind
    end,
    close = function(_self: Dir)
      if not is_closed then
        raw:close()
        is_closed = true
      end
    end,
    fd = function(_self: Dir): integer
      if is_closed then return -1 end
      return (raw:fd())
    end,
    rewind = function(_self: Dir)
      if not is_closed then raw:rewind() end
    end,
    tell = function(_self: Dir): integer
      if is_closed then return -1 end
      return (raw:tell())
    end,
    closed = function(_self: Dir): boolean
      return is_closed
    end,
  }

  local mt: metatable < Dir > = {
    __close = function(self: Dir)
      self:close()
    end
  }

  return setmetatable(dir, mt)
end

-- Stat operations

--- Get file metadata.
--- Follows symbolic links: stat on a symlink describes its target.
--- Use lstat() to inspect the symlink itself.
--- @param path string Path to the file or directory
--- @return Stat | nil File metadata, or nil on error
--- @return string Error message if failed
local function stat(path: string): Stat | nil, string
  local st, err = unix.stat(path)
  if not st then
    return nil, errstr(err, "stat: " .. path)
  end
  return types.wrap(st)
end

--- Get file metadata without following symbolic links.
--- lstat on a symlink describes the link itself, not its target.
--- @param path string Path to the file or symlink
--- @return Stat | nil File metadata, or nil on error
--- @return string Error message if failed
local function lstat(path: string): Stat | nil, string
  local st, err = unix.stat(path, unix.AT_SYMLINK_NOFOLLOW)
  if not st then
    return nil, errstr(err, "lstat: " .. path)
  end
  return types.wrap(st)
end

--- Get file metadata from file descriptor.
--- @param fd integer File descriptor
--- @return Stat | nil File metadata, or nil on error
--- @return string Error message if failed
local function fstat(fd: integer): Stat | nil, string
  local st, err = unix.fstat(fd)
  if not st then
    return nil, errstr(err, "fstat")
  end
  return types.wrap(st)
end

-- Directory operations

--- Create a directory.
--- Parent directories must exist. Use make_dirs() to create parents.
--- @param path string Path to the directory to create
--- @param mode integer Permission bits (default 0755)
--- @return boolean True on success
--- @return string Error message if failed
local function mkdir(path: string, mode?: integer): boolean, string
  mode = mode or tonumber("755", 8)
  local ok, err = unix.mkdir(path, mode)
  if not ok then
    return false, errstr(err, "mkdir: " .. path)
  end
  return true
end

--- Create a directory and any missing parent directories.
--- @param path string Path to the directory to create
--- @param mode integer Permission bits (default 0755)
--- @return boolean True on success
--- @return string Error message if failed
local function make_dirs(path: string, mode?: integer): boolean, string
  mode = mode or tonumber("755", 8)
  local ok, err = unix.makedirs(path, mode)
  if not ok then
    return false, errstr(err, "make_dirs: " .. path)
  end
  return true
end

--- Remove an empty directory.
--- @param path string Path to the directory to remove
--- @return boolean True on success
--- @return string Error message if failed
local function rmdir(path: string): boolean, string
  local ok, err = unix.rmdir(path)
  if not ok then
    return false, errstr(err, "rmdir: " .. path)
  end
  return true
end

--- Change current working directory.
--- @param path string Path to the new working directory
--- @return boolean True on success
--- @return string Error message if failed
local function chdir(path: string): boolean, string
  local ok, err = unix.chdir(path)
  if not ok then
    return false, errstr(err, "chdir: " .. path)
  end
  return true
end

--- Get current working directory.
--- @return string | nil Current working directory path
--- @return string Error message if failed
local function cwd(): string | nil, string
  local dir, err = unix.getcwd()
  if not dir then
    return nil, errstr(err, "cwd")
  end
  return dir
end

--- Open a directory for reading.
--- Call dir:read() to iterate entries, dir:close() when done.
--- Supports automatic cleanup with `<close>` attribute.
--- @param path string Path to the directory
--- @return Dir | nil Directory handle, or nil on error
--- @return string Error message if failed
local function opendir(path: string): Dir | nil, string
  -- `is` is safe here since every cosmic-installed loader (dispatcher
  -- searcher, embed wrapper) resolves the unix.Dir userdata
  -- marker; explicit tl.loader() installs are unsupported.
  local raw, err = unix.opendir(path)
  if raw is unix.Dir then
    return make_dir(raw)
  end
  return nil, errstr(err, "opendir: " .. path)
end

--- Open a directory from a file descriptor.
--- Supports automatic cleanup with `<close>` attribute.
--- @param fd integer File descriptor for an open directory
--- @return Dir | nil Directory handle, or nil on error
--- @return string Error message if failed
local function fdopendir(fd: integer): Dir | nil, string
  local raw, err = unix.fdopendir(fd)
  if raw is unix.Dir then
    return make_dir(raw)
  end
  return nil, errstr(err, "fdopendir")
end

-- Re-export the walker (fs_walk) and the find family (fs_find)
local fs_walk = require("cosmic.fs.walk")
local fs_find = require("cosmic.fs.find")

-- Recursive tree operations
local fs_tree = require("cosmic.fs.tree")

--- Iterator over file paths, as returned by files().
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
  --- Iterator over file paths, as returned by files().
  type FileIter = FileIter

  --- The types this module's own signatures return, exported so
  --- callers can name them without importing the cosmic.fs.types
  --- shard: `local st: fs.Stat`, `function f(d: fs.Dir)`.
  type Stat = Stat
  type Statfs = Statfs
  type Dir = Dir
  type FileInfo = FileInfo
  type WalkStat = WalkStat
  --- fd.Handle, as wrapped by temp_fd() + fd.wrap(); TmpFile is
  --- temp_file()'s handle+path record.
  type Handle = Handle
  type TmpFile = fs_ops.TmpFile

  --- Visitor verdict for walk(): nil continues, "skip" prunes, "stop" ends the walk.
  type WalkAction = WalkAction

  --- Options for walk() (max_depth; entries directly in dir are depth 1).
  type WalkOptions = WalkOptions

  -- Path manipulation
  dirname: function(str: string): string
  basename: function(str: string): string
  join: function(...: string): string
  --- Current user's home directory (nil + error when unset).
  home: function(): string | nil, string
  --- Expand a leading "~" or "~/" to the home directory.
  expanduser: function(p: string): string
  exists: function(path: string): boolean
  is_file: function(path: string): boolean
  is_dir: function(path: string): boolean
  is_link: function(path: string): boolean
  --- True for POSIX ("/x"), drive-letter ("C:/x", "C:\x"), and UNC
  --- ("\\server\share") absolute paths.
  is_absolute: function(p: string): boolean
  --- THE zip-slip guard shared by zip/tar/embed; see cosmic.fs.path.
  unsafe_entry_name: function(name: string): boolean
  normalize: function(p: string): string
  abspath: function(p: string): string
  relpath: function(p: string, base?: string): string
  splitext: function(p: string): string, string
  ext: function(p: string): string

  -- Stat operations
  stat: function(path: string): Stat | nil, string
  lstat: function(path: string): Stat | nil, string
  fstat: function(fd: integer): Stat | nil, string

  -- Directory operations
  mkdir: function(path: string, mode?: integer): boolean, string
  make_dirs: function(path: string, mode?: integer): boolean, string
  rmdir: function(path: string): boolean, string
  chdir: function(path: string): boolean, string
  cwd: function(): string | nil, string
  opendir: function(path: string): Dir | nil, string
  fdopendir: function(fd: integer): Dir | nil, string

  -- Whole-file operations
  read: function(path: string): string | nil, string
  write: function(path: string, data: string, mode?: integer): boolean, string
  truncate: function(path: string, length?: integer): boolean, string

  -- File operations
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

  -- Permission operations
  access: function(path: string, mode?: integer): boolean
  chmod: function(path: string, mode: integer): boolean, string
  chown: function(path: string, uid: integer, gid: integer): boolean, string

  -- Timestamp operations
  type Timespec = fs_ops.Timespec
  type Times = fs_ops.Times
  set_times: function(path: string, times: fs_ops.Times): boolean, string
  set_times_fd: function(fd: integer, times: fs_ops.Times): boolean, string

  -- Temporary file operations
  temp_dir: function(template: string): string | nil, string
  temp_file: function(template?: string): fs_ops.TmpFile | nil, string
  temp_fd: function(): integer | nil, string

  -- Filesystem statistics
  statfs: function(path: string): Statfs | nil, string
  fstatfs: function(fd: integer): Statfs | nil, string

  --- Flush all filesystem buffers to disk, system-wide (sync(2)).
  --- Per-file flushing is Handle:sync()/Handle:datasync() in cosmic.fd.
  sync: function()

  -- Device number utilities
  major: function(dev: integer): integer
  minor: function(dev: integer): integer

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
end

local M: FsModule = {
  -- Path manipulation (re-exported from fs_path)
  dirname = fs_path.dirname,
  basename = fs_path.basename,
  join = fs_path.join,
  home = fs_path.home,
  expanduser = fs_path.expanduser,
  exists = fs_path.exists,
  is_file = fs_path.is_file,
  is_dir = fs_path.is_dir,
  is_link = fs_path.is_link,
  is_absolute = fs_path.is_absolute,
  unsafe_entry_name = fs_path.unsafe_entry_name,
  normalize = fs_path.normalize,
  abspath = fs_path.abspath,
  relpath = fs_path.relpath,
  splitext = fs_path.splitext,
  ext = fs_path.ext,

  -- Stat operations
  stat = stat,
  lstat = lstat,
  fstat = fstat,

  -- Directory operations
  mkdir = mkdir,
  make_dirs = make_dirs,
  rmdir = rmdir,
  chdir = chdir,
  cwd = cwd,
  opendir = opendir,
  fdopendir = fdopendir,

  -- Whole-file operations (re-exported from fs_ops)
  read = fs_file.read,
  write = fs_file.write,
  truncate = fs_file.truncate,

  -- File operations (re-exported from fs_ops)
  unlink = fs_ops.unlink,
  rename = fs_ops.rename,
  copy = fs_ops.copy,
  move = fs_ops.move,
  touch = fs_ops.touch,
  write_atomic = fs_file.write_atomic,
  link = fs_ops.link,
  symlink = fs_ops.symlink,
  readlink = fs_ops.readlink,
  realpath = fs_ops.realpath,
  remove_all = fs_ops.remove_all,
  copy_tree = fs_tree.copy_tree,

  -- Permission operations (re-exported from fs_ops)
  access = fs_ops.access,
  chmod = fs_ops.chmod,
  chown = fs_ops.chown,

  -- Timestamp operations (re-exported from fs_ops)
  set_times = fs_ops.set_times,
  set_times_fd = fs_ops.set_times_fd,

  -- Temporary file operations (re-exported from fs_ops)
  temp_dir = fs_ops.temp_dir,
  temp_file = fs_ops.temp_file,
  temp_fd = fs_ops.temp_fd,

  -- Filesystem statistics (re-exported from fs_ops)
  statfs = fs_ops.statfs,
  fstatfs = fs_ops.fstatfs,
  sync = fs_ops.sync,

  -- Device number utilities (re-exported from fs_ops)
  major = fs_ops.major,
  minor = fs_ops.minor,

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
}

return M
