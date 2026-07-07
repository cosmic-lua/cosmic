--- Unified filesystem module.
--- Combines path manipulation, filesystem operations, and directory walking.
local unix = require("cosmo.unix")
local types = require("cosmic.fs_types")
local errstr = require("cosmic.errno").str
local Stat = types.Stat
local Dir = types.Dir
local Statfs = types.Statfs
local type WalkStat = types.WalkStat
local FileInfo = types.FileInfo

-- Re-export path functions from fs_path submodule
local fs_path = require("cosmic.fs_path")

-- Re-export file operations from fs_ops / fs_file submodules
local fs_ops = require("cosmic.fs_ops")
local fs_file = require("cosmic.fs_file")

-- Raw Dir type from cosmo.unix
local record RawDir
  read: function(self: RawDir): string
  close: function(self: RawDir)
  fd: function(self: RawDir): number
  rewind: function(self: RawDir)
  tell: function(self: RawDir): number
end

-- Wrap a raw cosmo Dir with __close support
local function make_dir(raw: RawDir): Dir
  local is_closed = false

  local dir: Dir = {
    read = function(_self: Dir): string
      if is_closed then return nil end
      return raw:read()
    end,
    close = function(_self: Dir)
      if not is_closed then
        raw:close()
        is_closed = true
      end
    end,
    fd = function(_self: Dir): number
      if is_closed then return -1 end
      return raw:fd()
    end,
    rewind = function(_self: Dir)
      if not is_closed then raw:rewind() end
    end,
    tell = function(_self: Dir): number
      if is_closed then return -1 end
      return raw:tell()
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
--- @param fd number File descriptor
--- @return Stat | nil File metadata, or nil on error
--- @return string Error message if failed
local function fstat(fd: number): Stat | nil, string
  local st, err = unix.fstat(fd)
  if not st then
    return nil, errstr(err, "fstat")
  end
  return types.wrap(st)
end

-- Directory operations

--- Create a directory.
--- Parent directories must exist. Use makedirs() to create parents.
--- @param path string Path to the directory to create
--- @param mode number Permission bits (default 0755)
--- @return boolean True on success
--- @return string Error message if failed
local function mkdir(path: string, mode?: number): boolean, string
  mode = mode or tonumber("755", 8)
  local ok, err = unix.mkdir(path, mode)
  if not ok then
    return false, errstr(err, "mkdir: " .. path)
  end
  return true
end

--- Create a directory and any missing parent directories.
--- @param path string Path to the directory to create
--- @param mode number Permission bits (default 0755)
--- @return boolean True on success
--- @return string Error message if failed
local function makedirs(path: string, mode?: number): boolean, string
  mode = mode or tonumber("755", 8)
  local ok, err = unix.makedirs(path, mode)
  if not ok then
    return false, errstr(err, "makedirs: " .. path)
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
local function getcwd(): string | nil, string
  local cwd, err = unix.getcwd()
  if not cwd then
    return nil, errstr(err, "getcwd")
  end
  return cwd
end

--- Open a directory for reading.
--- Call dir:read() to iterate entries, dir:close() when done.
--- Supports automatic cleanup with `<close>` attribute.
--- @param path string Path to the directory
--- @return Dir | nil Directory handle, or nil on error
--- @return string Error message if failed
local function opendir(path: string): Dir | nil, string
  local raw, err = unix.opendir(path)
  if not raw then
    return nil, errstr(err, "opendir: " .. path)
  end
  return make_dir(raw as RawDir)
end

--- Open a directory from a file descriptor.
--- Supports automatic cleanup with `<close>` attribute.
--- @param fd number File descriptor for an open directory
--- @return Dir | nil Directory handle, or nil on error
--- @return string Error message if failed
local function fdopendir(fd: number): Dir | nil, string
  local raw, err = unix.fdopendir(fd)
  if not raw then
    return nil, errstr(err, "fdopendir")
  end
  return make_dir(raw as RawDir)
end

-- Re-export walk functions from fs_walk submodule
local fs_walk = require("cosmic.fs_walk")

--- Iterator over file paths, as returned by files().
local type FileIter = fs_walk.FileIter

--- Module interface
local record FsModule
  -- Path manipulation
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

  -- Stat operations
  stat: function(path: string): Stat | nil, string
  lstat: function(path: string): Stat | nil, string
  fstat: function(fd: number): Stat | nil, string

  -- Directory operations
  mkdir: function(path: string, mode?: number): boolean, string
  makedirs: function(path: string, mode?: number): boolean, string
  rmdir: function(path: string): boolean, string
  chdir: function(path: string): boolean, string
  getcwd: function(): string | nil, string
  opendir: function(path: string): Dir | nil, string
  fdopendir: function(fd: number): Dir | nil, string

  -- Whole-file operations
  read: function(path: string): string | nil, string
  write: function(path: string, data: string, mode?: number): boolean, string
  truncate: function(path: string, length?: number): boolean, string

  -- File operations
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

  -- Permission operations
  access: function(path: string, mode: number): boolean
  chmod: function(path: string, mode: number): boolean, string
  chown: function(path: string, uid: number, gid: number): boolean, string

  -- Timestamp operations
  utimensat: function(path: string, atime_secs: number, atime_nsecs: number, mtime_secs: number, mtime_nsecs: number): boolean, string
  futimens: function(fd: number, atime_secs: number, atime_nsecs: number, mtime_secs: number, mtime_nsecs: number): boolean, string

  -- Temporary file operations
  mkdtemp: function(template: string): string | nil, string
  mkstemp: function(template: string): number | nil, string, string
  tmpfd: function(): number | nil, string

  -- Filesystem statistics
  statfs: function(path: string): Statfs | nil, string
  fstatfs: function(fd: number): Statfs | nil, string

  -- Device number utilities
  major: function(dev: number): number
  minor: function(dev: number): number

  -- Directory walking.
  -- walk visitor signature: visitor(path, name, st, ctx)
  --   path = full path to the entry (e.g. "dir/sub/file.txt") — do NOT join with name.
  --   name = basename of the entry (e.g. "file.txt").
  --   st   = WalkStat (import: local types = require("cosmic.fs_types"); types.WalkStat).
  -- Root open failure returns nil, err; subtree failures return the first
  -- error alongside the results.
  walk: function < T > (dir: string, visitor: function(string, string, WalkStat, T), ctx?: T): T | nil, string
  collect: function(dir: string, pattern: string): {string} | nil, string
  collect_all: function(dir: string): {string: FileInfo} | nil, string
  files: function(dir: string, pattern?: string): FileIter, string, any, any

  -- Access mode constants
  F_OK: number
  R_OK: number
  W_OK: number
  X_OK: number
end

local M: FsModule = {
  -- Path manipulation (re-exported from fs_path)
  dirname = fs_path.dirname,
  basename = fs_path.basename,
  join = fs_path.join,
  exists = fs_path.exists,
  isfile = fs_path.isfile,
  isdir = fs_path.isdir,
  islink = fs_path.islink,
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
  makedirs = makedirs,
  rmdir = rmdir,
  chdir = chdir,
  getcwd = getcwd,
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
  rmrf = fs_ops.rmrf,

  -- Permission operations (re-exported from fs_ops)
  access = fs_ops.access,
  chmod = fs_ops.chmod,
  chown = fs_ops.chown,

  -- Timestamp operations (re-exported from fs_ops)
  utimensat = fs_ops.utimensat,
  futimens = fs_ops.futimens,

  -- Temporary file operations (re-exported from fs_ops)
  mkdtemp = fs_ops.mkdtemp,
  mkstemp = fs_ops.mkstemp,
  tmpfd = fs_ops.tmpfd,

  -- Filesystem statistics (re-exported from fs_ops)
  statfs = fs_ops.statfs,
  fstatfs = fs_ops.fstatfs,

  -- Device number utilities (re-exported from fs_ops)
  major = fs_ops.major,
  minor = fs_ops.minor,

  -- Directory walking
  walk = fs_walk.walk,
  collect = fs_walk.collect,
  collect_all = fs_walk.collect_all,
  files = fs_walk.files,

  -- Access mode constants (re-exported from fs_ops)
  F_OK = fs_ops.F_OK,
  R_OK = fs_ops.R_OK,
  W_OK = fs_ops.W_OK,
  X_OK = fs_ops.X_OK,
}

return M
