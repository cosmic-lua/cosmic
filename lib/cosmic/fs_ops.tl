--- Filesystem file operations, permissions, timestamps, and temp files.
--- Internal submodule used by cosmic.fs.
local unix = require("cosmo.unix")

local record Errno
  errno: function(self: Errno): number
  winerr: function(self: Errno): number
  name: function(self: Errno): string
  call: function(self: Errno): string
  doc: function(self: Errno): string
end

--- Filesystem statistics.
--- Returned by statfs() and fstatfs().
local record Statfs
  --- Returns filesystem type identifier.
  type: function(self: Statfs): number
  --- Returns optimal transfer block size.
  bsize: function(self: Statfs): number
  --- Returns total data blocks in filesystem.
  blocks: function(self: Statfs): number
  --- Returns free blocks in filesystem.
  bfree: function(self: Statfs): number
  --- Returns free blocks available to unprivileged user.
  bavail: function(self: Statfs): number
  --- Returns total file nodes in filesystem.
  files: function(self: Statfs): number
  --- Returns free file nodes in filesystem.
  ffree: function(self: Statfs): number
  --- Returns filesystem ID as two numbers.
  fsid: function(self: Statfs): number, number
  --- Returns maximum length of filenames.
  namelen: function(self: Statfs): number
  --- Returns fragment size.
  frsize: function(self: Statfs): number
  --- Returns mount flags.
  flags: function(self: Statfs): number
end

-- File operations

--- Remove a file or symbolic link.
--- Does not remove directories; use rmdir() or rmrf() for that.
--- @param path string Path to the file to remove
--- @return boolean True on success
--- @return string Error message if failed
local function unlink(path: string): boolean, string
  local ok = unix.unlink(path)
  if not ok then
    return false, "unlink failed: " .. path
  end
  return true
end

--- Rename or move a file or directory.
--- @param oldpath string Current path
--- @param newpath string New path
--- @return boolean True on success
--- @return string Error message if failed
local function rename(oldpath: string, newpath: string): boolean, string
  local ok = unix.rename(oldpath, newpath, unix.AT_FDCWD, unix.AT_FDCWD)
  if not ok then
    return false, "rename failed: " .. oldpath .. " -> " .. newpath
  end
  return true
end

--- Create a hard link.
--- @param existingpath string Path to the existing file
--- @param newpath string Path for the new link
--- @return boolean True on success
--- @return string Error message if failed
local function link(existingpath: string, newpath: string): boolean, string
  local ok = unix.link(existingpath, newpath, 0, unix.AT_FDCWD, unix.AT_FDCWD)
  if not ok then
    return false, "link failed: " .. existingpath .. " -> " .. newpath
  end
  return true
end

--- Create a symbolic link.
--- @param target string Content of the symlink (where it points)
--- @param linkpath string Path where the symlink will be created
--- @return boolean True on success
--- @return string Error message if failed
local function symlink(target: string, linkpath: string): boolean, string
  local ok = unix.symlink(target, linkpath)
  if not ok then
    return false, "symlink failed: " .. linkpath .. " -> " .. target
  end
  return true
end

--- Read the target of a symbolic link.
--- @param path string Path to the symbolic link
--- @return string The symlink target, or nil on error
--- @return string Error message if failed
local function readlink(path: string): string, string
  local target = unix.readlink(path)
  if not target then
    return nil, "readlink failed: " .. path
  end
  return target
end

--- Get the canonical absolute path.
--- Resolves all symbolic links and removes . and .. components.
--- @param path string Path to resolve
--- @return string Canonical path, or nil on error
--- @return string Error message if failed
local function realpath(path: string): string, string
  local resolved = unix.realpath(path)
  if not resolved then
    return nil, "realpath failed: " .. path
  end
  return resolved
end

--- Recursively remove a directory and all its contents.
--- Use with caution.
--- @param path string Path to the directory to remove
--- @return boolean True on success
--- @return string Error message if failed
local function rmrf(path: string): boolean, string
  local ok = unix.rmrf(path)
  if not ok then
    return false, "rmrf failed: " .. path
  end
  return true
end

-- Permission operations

--- Check if the current process has access to a file.
--- @param path string Path to check
--- @param mode number Access mode: F_OK (exists), R_OK, W_OK, X_OK
--- @return boolean True if access is allowed
local function access(path: string, mode: number): boolean
  return unix.access(path, mode)
end

--- Change file permissions.
--- @param path string Path to the file
--- @param mode number New permission bits (e.g., 0644)
--- @return boolean True on success
--- @return string Error message if failed
local function chmod(path: string, mode: number): boolean, string
  local ok = unix.chmod(path, mode)
  if not ok then
    return false, "chmod failed: " .. path
  end
  return true
end

--- Change file owner and group.
--- @param path string Path to the file
--- @param uid number New owner user ID
--- @param gid number New owner group ID
--- @return boolean True on success
--- @return string Error message if failed
local function chown(path: string, uid: number, gid: number): boolean, string
  local ok = unix.chown(path, uid, gid)
  if not ok then
    return false, "chown failed: " .. path
  end
  return true
end

-- Timestamp operations

--- Change file access and modification times.
--- @param path string Path to the file
--- @param atime_secs number Access time seconds (nil to keep current)
--- @param atime_nsecs number Access time nanoseconds
--- @param mtime_secs number Modification time seconds (nil to keep current)
--- @param mtime_nsecs number Modification time nanoseconds
--- @return boolean True on success
--- @return string Error message if failed
local function utimensat(path: string, atime_secs: number, atime_nsecs: number, mtime_secs: number, mtime_nsecs: number): boolean, string
  local rc = unix.utimensat(path, atime_secs or 0, atime_nsecs or unix.UTIME_OMIT, mtime_secs or 0, mtime_nsecs or unix.UTIME_OMIT)
  if rc ~= 0 then
    return false, "utimensat failed: " .. path
  end
  return true
end

--- Change file access and modification times on a file descriptor.
--- @param fd number File descriptor
--- @param atime_secs number Access time seconds (nil to keep current)
--- @param atime_nsecs number Access time nanoseconds
--- @param mtime_secs number Modification time seconds (nil to keep current)
--- @param mtime_nsecs number Modification time nanoseconds
--- @return boolean True on success
--- @return string Error message if failed
local function futimens(fd: number, atime_secs: number, atime_nsecs: number, mtime_secs: number, mtime_nsecs: number): boolean, string
  local rc = unix.futimens(fd, atime_secs or 0, atime_nsecs or unix.UTIME_OMIT, mtime_secs or 0, mtime_nsecs or unix.UTIME_OMIT)
  if rc ~= 0 then
    return false, "futimens failed"
  end
  return true
end

-- Temporary file operations

--- Create a temporary directory.
--- @param template string Path template ending in XXXXXX
--- @return string Path to the created directory, or nil on error
--- @return string Error message if failed
local function mkdtemp(template: string): string, string
  local path = unix.mkdtemp(template)
  if not path then
    return nil, "mkdtemp failed: " .. template
  end
  return path
end

--- Create a temporary file.
--- @param template string Path template ending in XXXXXX
--- @return number File descriptor, or nil on error
--- @return string Path to the created file, or error message
local function mkstemp(template: string): number, string
  local fd, path = unix.mkstemp(template)
  if not fd then
    return nil, "mkstemp failed: " .. template
  end
  return fd, path
end

--- Create a temporary file descriptor.
--- @return number File descriptor, or nil on error
--- @return string Error message if failed
local function tmpfd(): number, string
  local fd = unix.tmpfd()
  if not fd then
    return nil, "tmpfd failed"
  end
  return fd
end

-- Filesystem statistics

--- Get filesystem statistics for a path.
--- @param path string Path to any file on the filesystem
--- @return Statfs Filesystem statistics, or nil on error
--- @return string Error message if failed
local function statfs(path: string): Statfs, string
  local info = unix.statfs(path) as Statfs
  if not info then
    return nil, "statfs failed: " .. path
  end
  return info
end

--- Get filesystem statistics from a file descriptor.
--- @param fd number File descriptor
--- @return Statfs Filesystem statistics, or nil on error
--- @return string Error message if failed
local function fstatfs(fd: number): Statfs, string
  local info = unix.fstatfs(fd) as Statfs
  if not info then
    return nil, "fstatfs failed"
  end
  return info
end

-- Device number utilities

--- Extract major device number from a device ID.
--- @param dev number Device ID from stat
--- @return number Major device number
local function major(dev: number): number
  return unix.major(dev)
end

--- Extract minor device number from a device ID.
--- @param dev number Device ID from stat
--- @return number Minor device number
local function minor(dev: number): number
  return unix.minor(dev)
end

local record FsOpsModule
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
  statfs: function(path: string): Statfs, string
  fstatfs: function(fd: number): Statfs, string
  major: function(dev: number): number
  minor: function(dev: number): number
  F_OK: number
  R_OK: number
  W_OK: number
  X_OK: number
end

local M: FsOpsModule = {
  unlink = unlink,
  rename = rename,
  link = link,
  symlink = symlink,
  readlink = readlink,
  realpath = realpath,
  rmrf = rmrf,
  access = access,
  chmod = chmod,
  chown = chown,
  utimensat = utimensat,
  futimens = futimens,
  mkdtemp = mkdtemp,
  mkstemp = mkstemp,
  tmpfd = tmpfd,
  statfs = statfs,
  fstatfs = fstatfs,
  major = major,
  minor = minor,
  F_OK = unix.F_OK,
  R_OK = unix.R_OK,
  W_OK = unix.W_OK,
  X_OK = unix.X_OK,
}

return M
