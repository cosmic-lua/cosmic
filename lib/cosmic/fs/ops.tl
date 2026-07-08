--- Filesystem file operations, permissions, timestamps, and temp files.
--- Internal submodule used by cosmic.fs.
local unix = require("cosmo.unix")
local cfd = require("cosmic.fd")
local types = require("cosmic.fs.types")
local errno = require("cosmic.errno")
local errstr = errno.str
local Statfs = types.Statfs
local type Handle = cfd.Handle

-- File operations

--- Remove a file or symbolic link.
--- Does not remove directories; use rmdir() or rmrf() for that.
--- @param path string Path to the file to remove
--- @return boolean True on success
--- @return string Error message if failed
local function unlink(path: string): boolean, string
  local ok, err = unix.unlink(path)
  if not ok then
    return false, errstr(err, "unlink: " .. path)
  end
  return true
end

--- Rename or move a file or directory.
--- @param oldpath string Current path
--- @param newpath string New path
--- @return boolean True on success
--- @return string Error message if failed
local function rename(oldpath: string, newpath: string): boolean, string
  local ok, err = unix.rename(oldpath, newpath, unix.AT_FDCWD, unix.AT_FDCWD)
  if not ok then
    return false, errstr(err, "rename: " .. oldpath .. " -> " .. newpath)
  end
  return true
end

--- Copy a file, preserving its permission bits.
--- Follows symlinks: copying a symlink copies the target's contents.
--- The destination is created (or truncated) and receives the source's
--- mode bits.
--- @param src string Path to the source file
--- @param dst string Path to the destination file
--- @return boolean True on success
--- @return string Error message if failed
local function copy(src: string, dst: string): boolean, string
  local srcfd, oerr = unix.open(src, unix.O_RDONLY)
  if not srcfd then
    return false, errstr(oerr, "copy: open: " .. src)
  end
  local st, serr = unix.fstat(srcfd)
  if not st then
    unix.close(srcfd)
    return false, errstr(serr, "copy: fstat: " .. src)
  end
  local mode = st:mode() & 0x1ff
  local dstfd, derr = unix.open(dst,
    unix.O_WRONLY | unix.O_CREAT | unix.O_TRUNC, mode)
  if not dstfd then
    unix.close(srcfd)
    return false, errstr(derr, "copy: open: " .. dst)
  end
  while true do
    local data, rerr = unix.read(srcfd, 65536)
    if data == nil then
      unix.close(srcfd)
      unix.close(dstfd)
      return false, errstr(rerr, "copy: read: " .. src)
    end
    if data == "" then break end
    local off: integer = 1
    while off <= #data do
      local n, werr = unix.write(dstfd, data:sub(off))
      if not n then
        unix.close(srcfd)
        unix.close(dstfd)
        return false, errstr(werr, "copy: write: " .. dst)
      end
      off = off + math.floor(n)
    end
  end
  unix.close(srcfd)
  unix.close(dstfd)
  -- open()'s mode is masked by the umask; chmod applies the exact bits.
  local ok, cerr = unix.chmod(dst, mode)
  if not ok then
    return false, errstr(cerr, "copy: chmod: " .. dst)
  end
  return true
end

--- Move (rename) a file, falling back to copy+unlink across filesystems.
--- A plain rename() fails with EXDEV when oldpath and newpath are on
--- different filesystems; in that case the file is copied (mode
--- preserved) and the original unlinked.
--- @param oldpath string Current path
--- @param newpath string New path
--- @return boolean True on success
--- @return string Error message if failed
local function move(oldpath: string, newpath: string): boolean, string
  local ok, err, eno = unix.rename(oldpath, newpath, unix.AT_FDCWD, unix.AT_FDCWD)
  if ok then
    return true
  end
  if not errno.is(eno, "EXDEV") then
    return false, errstr(err, "move: " .. oldpath .. " -> " .. newpath)
  end
  local copied, cerr = copy(oldpath, newpath)
  if not copied then
    return false, cerr
  end
  local unlinked, uerr = unix.unlink(oldpath)
  if not unlinked then
    return false, errstr(uerr, "move: unlink: " .. oldpath)
  end
  return true
end

--- Update a file's access and modification times to now, creating the
--- file (mode 0644 by default) if it does not exist.
--- @param path string Path to the file
--- @param mode number Permission bits when creating (default 0644)
--- @return boolean True on success
--- @return string Error message if failed
local function touch(path: string, mode?: number): boolean, string
  local fd, oerr = unix.open(path,
    unix.O_WRONLY | unix.O_CREAT, mode or tonumber("644", 8))
  if not fd then
    return false, errstr(oerr, "touch: " .. path)
  end
  unix.close(fd)
  local rc, terr = unix.utimensat(path,
    0, unix.UTIME_NOW, 0, unix.UTIME_NOW)
  if rc ~= 0 then
    return false, errstr(terr, "touch: " .. path)
  end
  return true
end

--- Create a hard link.
--- @param existingpath string Path to the existing file
--- @param newpath string Path for the new link
--- @return boolean True on success
--- @return string Error message if failed
local function link(existingpath: string, newpath: string): boolean, string
  local ok, err = unix.link(existingpath, newpath, 0, unix.AT_FDCWD, unix.AT_FDCWD)
  if not ok then
    return false, errstr(err, "link: " .. existingpath .. " -> " .. newpath)
  end
  return true
end

--- Create a symbolic link.
--- @param target string Content of the symlink (where it points)
--- @param linkpath string Path where the symlink will be created
--- @return boolean True on success
--- @return string Error message if failed
local function symlink(target: string, linkpath: string): boolean, string
  local ok, err = unix.symlink(target, linkpath)
  if not ok then
    return false, errstr(err, "symlink: " .. linkpath .. " -> " .. target)
  end
  return true
end

--- Read the target of a symbolic link.
--- @param path string Path to the symbolic link
--- @return string | nil The symlink target, or nil on error
--- @return string Error message if failed
local function readlink(path: string): string | nil, string
  local target, err = unix.readlink(path)
  if not target then
    return nil, errstr(err, "readlink: " .. path)
  end
  return target
end

--- Get the canonical absolute path.
--- Resolves all symbolic links and removes . and .. components.
--- @param path string Path to resolve
--- @return string | nil Canonical path, or nil on error
--- @return string Error message if failed
local function realpath(path: string): string | nil, string
  local resolved, err = unix.realpath(path)
  if not resolved then
    return nil, errstr(err, "realpath: " .. path)
  end
  return resolved
end

--- Recursively remove a directory and all its contents.
--- Use with caution.
--- @param path string Path to the directory to remove
--- @return boolean True on success
--- @return string Error message if failed
local function rmrf(path: string): boolean, string
  local ok, err = unix.rmrf(path)
  if not ok then
    return false, errstr(err, "rmrf: " .. path)
  end
  return true
end

-- Permission operations

--- Check if the current process has access to a file.
--- @param path string Path to check
--- @param mode number Access mode: F_OK (exists, the default), R_OK, W_OK, X_OK
--- @return boolean True if access is allowed
local function access(path: string, mode?: number): boolean
  -- The binding returns true or nil, err; callers get an honest boolean.
  return unix.access(path, mode or unix.F_OK) == true
end

--- Change file permissions.
--- @param path string Path to the file
--- @param mode number New permission bits (e.g., 0644)
--- @return boolean True on success
--- @return string Error message if failed
local function chmod(path: string, mode: number): boolean, string
  local ok, err = unix.chmod(path, mode)
  if not ok then
    return false, errstr(err, "chmod: " .. path)
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
  local ok, err = unix.chown(path, uid, gid)
  if not ok then
    return false, errstr(err, "chown: " .. path)
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
  local rc, err = unix.utimensat(path, atime_secs or 0, atime_nsecs or unix.UTIME_OMIT, mtime_secs or 0, mtime_nsecs or unix.UTIME_OMIT)
  if rc ~= 0 then
    return false, errstr(err, "utimensat: " .. path)
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
  local rc, err = unix.futimens(fd, atime_secs or 0, atime_nsecs or unix.UTIME_OMIT, mtime_secs or 0, mtime_nsecs or unix.UTIME_OMIT)
  if rc ~= 0 then
    return false, errstr(err, "futimens")
  end
  return true
end

-- Temporary file operations

--- Create a temporary directory.
--- @param template string Path template ending in XXXXXX
--- @return string | nil Path to the created directory, or nil on error
--- @return string Error message if failed
local function mkdtemp(template: string): string | nil, string
  local path, err = unix.mkdtemp(template)
  if not path then
    return nil, errstr(err, "mkdtemp: " .. template)
  end
  return path
end

--- Create a temporary file, returning an open fd.Handle plus its path.
--- The Handle owns the descriptor (h:close() releases it); the file is
--- NOT unlinked automatically — remove the path when done. For an
--- anonymous descriptor with no path, use tmpfd() + fd.wrap().
--- The second return is always the path (nil on failure); the error, if
--- any, is always in the third slot.
--- @param template string Path template ending in XXXXXX (default: $TMPDIR/cosmic_XXXXXX)
--- @return Handle | nil Open handle to the created file, or nil on error
--- @return string Path to the created file, or nil on error
--- @return string Error message if failed
local function tmpfile(template?: string): Handle | nil, string, string
  template = template or ((os.getenv("TMPDIR") or "/tmp") .. "/cosmic_XXXXXX")
  -- The binding returns (fd, path) on success and (nil, Errno) on failure.
  local fd, path = unix.mkstemp(template)
  if not fd then
    return nil, nil, errstr(path as any, "tmpfile: " .. template)
  end
  return cfd.wrap(fd), path
end

--- Create a temporary file descriptor.
--- @return number | nil File descriptor, or nil on error
--- @return string Error message if failed
local function tmpfd(): number | nil, string
  local fd, err = unix.tmpfd()
  if not fd then
    return nil, errstr(err, "tmpfd")
  end
  return fd
end

-- Filesystem statistics

--- Get filesystem statistics for a path.
--- @param path string Path to any file on the filesystem
--- @return Statfs | nil Filesystem statistics, or nil on error
--- @return string Error message if failed
local function statfs(path: string): Statfs | nil, string
  local info, err = unix.statfs(path)
  if not info then
    return nil, errstr(err, "statfs: " .. path)
  end
  return info as Statfs
end

--- Get filesystem statistics from a file descriptor.
--- @param fd number File descriptor
--- @return Statfs | nil Filesystem statistics, or nil on error
--- @return string Error message if failed
local function fstatfs(fd: number): Statfs | nil, string
  local info, err = unix.fstatfs(fd)
  if not info then
    return nil, errstr(err, "fstatfs")
  end
  return info as Statfs
end

--- Flush all filesystem buffers to disk, system-wide (sync(2)).
--- Infallible: the syscall reports nothing. For a single file use
--- Handle:sync()/Handle:datasync() from cosmic.fd.
local function sync()
  unix.sync()
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
  copy: function(src: string, dst: string): boolean, string
  move: function(oldpath: string, newpath: string): boolean, string
  touch: function(path: string, mode?: number): boolean, string
  link: function(existingpath: string, newpath: string): boolean, string
  symlink: function(target: string, linkpath: string): boolean, string
  readlink: function(path: string): string | nil, string
  realpath: function(path: string): string | nil, string
  rmrf: function(path: string): boolean, string
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
  F_OK: number
  R_OK: number
  W_OK: number
  X_OK: number
end

local M: FsOpsModule = {
  unlink = unlink,
  rename = rename,
  copy = copy,
  move = move,
  touch = touch,
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
  tmpfile = tmpfile,
  tmpfd = tmpfd,
  statfs = statfs,
  fstatfs = fstatfs,
  sync = sync,
  major = major,
  minor = minor,
  F_OK = unix.F_OK,
  R_OK = unix.R_OK,
  W_OK = unix.W_OK,
  X_OK = unix.X_OK,
}

return M
