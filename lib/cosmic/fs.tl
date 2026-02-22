--- Unified filesystem module.
--- Combines path manipulation, filesystem operations, and directory walking.
local unix = require("cosmo.unix")

local record Errno
  errno: function(self: Errno): number
  winerr: function(self: Errno): number
  name: function(self: Errno): string
  call: function(self: Errno): string
  doc: function(self: Errno): string
end

-- Re-export path functions from fs_path submodule
local fs_path = require("cosmic.fs_path")

-- Re-export file operations from fs_ops submodule
local fs_ops = require("cosmic.fs_ops")

-- Raw Dir type from cosmo.unix
local record RawDir
  read: function(self: RawDir): string
  close: function(self: RawDir)
  fd: function(self: RawDir): number
  rewind: function(self: RawDir)
  tell: function(self: RawDir): number
end

--- File or directory metadata.
--- Use is_dir(), is_file(), etc. to check file type.
local record Stat
  --- Returns file size in bytes.
  size: function(self: Stat): number
  --- Returns file mode (permissions and type bits).
  mode: function(self: Stat): number
  --- Returns owner user ID.
  uid: function(self: Stat): number
  --- Returns owner group ID.
  gid: function(self: Stat): number
  --- Returns birth time as seconds, nanoseconds.
  birthtim: function(self: Stat): number, number
  --- Returns modification time as seconds, nanoseconds.
  mtim: function(self: Stat): number, number
  --- Returns access time as seconds, nanoseconds.
  atim: function(self: Stat): number, number
  --- Returns status change time as seconds, nanoseconds.
  ctim: function(self: Stat): number, number
  --- Returns number of 512-byte blocks allocated.
  blocks: function(self: Stat): number
  --- Returns number of hard links.
  nlink: function(self: Stat): number
  --- Returns device ID containing the file.
  dev: function(self: Stat): number
  --- Returns device ID for special files (0 or -1 for non-devices).
  rdev: function(self: Stat): number
end

--- Handle for reading directory entries.
--- Supports automatic cleanup with `<close>` attribute.
local record Dir
  --- Reads next directory entry. Returns nil when done.
  read: function(self: Dir): string
  --- Closes directory handle.
  close: function(self: Dir)
  --- Returns file descriptor for this directory.
  fd: function(self: Dir): number
  --- Rewinds to beginning of directory.
  rewind: function(self: Dir)
  --- Returns current position in directory stream.
  tell: function(self: Dir): number
  --- Returns true if directory handle is closed.
  closed: function(self: Dir): boolean
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
--- Follows symbolic links by default.
--- @param path string Path to the file or directory
--- @param follow_symlinks boolean Whether to follow symlinks (default true)
--- @return Stat File metadata, or nil on error
--- @return string Error message if failed
local function stat(path: string, follow_symlinks?: boolean): Stat, string
  local flags: number = nil
  if follow_symlinks == false then
    flags = unix.AT_SYMLINK_NOFOLLOW
  end
  local st = unix.stat(path, flags) as Stat
  if not st then
    return nil, "stat failed: " .. path
  end
  return st
end

--- Get file metadata from file descriptor.
--- @param fd number File descriptor
--- @return Stat File metadata, or nil on error
--- @return string Error message if failed
local function fstat(fd: number): Stat, string
  local st = unix.fstat(fd) as Stat
  if not st then
    return nil, "fstat failed"
  end
  return st
end

--- Check if mode represents a directory.
--- @param mode number File mode from stat
--- @return boolean True if directory
local function is_dir(mode: number): boolean
  return unix.S_ISDIR(mode)
end

--- Check if mode represents a regular file.
--- @param mode number File mode from stat
--- @return boolean True if regular file
local function is_file(mode: number): boolean
  return unix.S_ISREG(mode)
end

--- Check if mode represents a symbolic link.
--- @param mode number File mode from stat
--- @return boolean True if symbolic link
local function is_link(mode: number): boolean
  return unix.S_ISLNK(mode)
end

--- Check if mode represents a block device.
--- @param mode number File mode from stat
--- @return boolean True if block device
local function is_block_device(mode: number): boolean
  return unix.S_ISBLK(mode)
end

--- Check if mode represents a character device.
--- @param mode number File mode from stat
--- @return boolean True if character device
local function is_char_device(mode: number): boolean
  return unix.S_ISCHR(mode)
end

--- Check if mode represents a FIFO (named pipe).
--- @param mode number File mode from stat
--- @return boolean True if FIFO
local function is_fifo(mode: number): boolean
  return unix.S_ISFIFO(mode)
end

--- Check if mode represents a socket.
--- @param mode number File mode from stat
--- @return boolean True if socket
local function is_socket(mode: number): boolean
  return unix.S_ISSOCK(mode)
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
  local ok, err = unix.mkdir(path, mode) as(boolean, any)
  if not ok then
    if err then
      local errno = err as Errno
      if errno.doc then
        return false, "mkdir: " .. path .. ": " .. errno:doc()
      end
      return false, "mkdir: " .. path .. ": " .. tostring(err)
    end
    return false, "mkdir: " .. path
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
  local ok, err = unix.makedirs(path, mode) as(boolean, any)
  if not ok then
    if err then
      local errno = err as Errno
      if errno.doc then
        return false, "makedirs: " .. path .. ": " .. errno:doc()
      end
      return false, "makedirs: " .. path .. ": " .. tostring(err)
    end
    return false, "makedirs: " .. path
  end
  return true
end

--- Remove an empty directory.
--- @param path string Path to the directory to remove
--- @return boolean True on success
--- @return string Error message if failed
local function rmdir(path: string): boolean, string
  local ok = unix.rmdir(path)
  if not ok then
    return false, "rmdir failed: " .. path
  end
  return true
end

--- Change current working directory.
--- @param path string Path to the new working directory
--- @return boolean True on success
--- @return string Error message if failed
local function chdir(path: string): boolean, string
  local ok = unix.chdir(path)
  if not ok then
    return false, "chdir failed: " .. path
  end
  return true
end

--- Get current working directory.
--- @return string Current working directory path
--- @return string Error message if failed
local function getcwd(): string, string
  local cwd = unix.getcwd()
  if not cwd then
    return nil, "getcwd failed"
  end
  return cwd
end

--- Open a directory for reading.
--- Call dir:read() to iterate entries, dir:close() when done.
--- Supports automatic cleanup with `<close>` attribute.
--- @param path string Path to the directory
--- @return Dir Directory handle, or nil on error
--- @return string Error message if failed
local function opendir(path: string): Dir, string
  local raw = unix.opendir(path) as RawDir
  if not raw then
    return nil, "opendir failed: " .. path
  end
  return make_dir(raw)
end

--- Open a directory from a file descriptor.
--- Supports automatic cleanup with `<close>` attribute.
--- @param fd number File descriptor for an open directory
--- @return Dir Directory handle, or nil on error
--- @return string Error message if failed
local function fdopendir(fd: number): Dir, string
  local _, raw = unix.fdopendir(fd)
  if not raw then
    return nil, "fdopendir failed"
  end
  return make_dir(raw as RawDir)
end

-- Re-export walk functions from fs_walk submodule
local fs_walk = require("cosmic.fs_walk")

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
    stat: function(path: string, follow_symlinks?: boolean): Stat, string
    fstat: function(fd: number): Stat, string
    is_dir: function(mode: number): boolean
    is_file: function(mode: number): boolean
    is_link: function(mode: number): boolean
    is_block_device: function(mode: number): boolean
    is_char_device: function(mode: number): boolean
    is_fifo: function(mode: number): boolean
    is_socket: function(mode: number): boolean

    -- Directory operations
    mkdir: function(path: string, mode?: number): boolean, string
    makedirs: function(path: string, mode?: number): boolean, string
    rmdir: function(path: string): boolean, string
    chdir: function(path: string): boolean, string
    getcwd: function(): string, string
    opendir: function(path: string): Dir, string
    fdopendir: function(fd: number): Dir, string

    -- File operations
    unlink: function(path: string): boolean, string
    rename: function(oldpath: string, newpath: string): boolean, string
    link: function(existingpath: string, newpath: string): boolean, string
    symlink: function(target: string, linkpath: string): boolean, string
    readlink: function(path: string): string, string
    realpath: function(path: string): string, string
    rmrf: function(path: string): boolean, string

    -- Permission operations
    access: function(path: string, mode: number): boolean
    chmod: function(path: string, mode: number): boolean, string
    chown: function(path: string, uid: number, gid: number): boolean, string

    -- Timestamp operations
    utimensat: function(path: string, atime_secs: number, atime_nsecs: number, mtime_secs: number, mtime_nsecs: number): boolean, string
    futimens: function(fd: number, atime_secs: number, atime_nsecs: number, mtime_secs: number, mtime_nsecs: number): boolean, string

    -- Temporary file operations
    mkdtemp: function(template: string): string, string
    mkstemp: function(template: string): number, string
    tmpfd: function(): number, string

    -- Filesystem statistics
    statfs: function(path: string): any, string
    fstatfs: function(fd: number): any, string

    -- Device number utilities
    major: function(dev: number): number
    minor: function(dev: number): number

    -- Directory walking
    walk: function<T>(dir: string, visitor: any, ctx?: T): T
    collect: function(dir: string, pattern: string): {string}
    collect_all: function(dir: string): {string: {string: number}}
    files: function(dir: string, pattern?: string): function(): string

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
    fstat = fstat,
    is_dir = is_dir,
    is_file = is_file,
    is_link = is_link,
    is_block_device = is_block_device,
    is_char_device = is_char_device,
    is_fifo = is_fifo,
    is_socket = is_socket,

    -- Directory operations
    mkdir = mkdir,
    makedirs = makedirs,
    rmdir = rmdir,
    chdir = chdir,
    getcwd = getcwd,
    opendir = opendir,
    fdopendir = fdopendir,

    -- File operations (re-exported from fs_ops)
    unlink = fs_ops.unlink,
    rename = fs_ops.rename,
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
