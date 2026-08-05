--- Filesystem file operations, permissions, timestamps, and temp files.
--- Internal submodule used by cosmic.fs.
local unix = require("cosmo.unix")
local cfd = require("cosmic.fd")
local stream = require("cosmic.stream")
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
--- mode bits. Read and write retry automatically on EINTR, matching
--- cosmic.fd's signal-safety posture.
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
  local mode = (st as unix.Stat):mode() & 0x1ff -- cast: record union after guard
  local dstfd, derr = unix.open(dst,
    unix.O_WRONLY | unix.O_CREAT | unix.O_TRUNC, mode)
  if not dstfd then
    unix.close(srcfd)
    return false, errstr(derr, "copy: open: " .. dst)
  end
  -- The pump is cosmic.stream.copy over fd Handles: one buffered-copy
  -- algorithm for the whole stdlib, EINTR retried inside fd.Handle.
  local sh = cfd.wrap(srcfd)
  local dh = cfd.wrap(dstfd)
  local copied, pump_err = stream.copy(dh, sh)
  sh:close()
  dh:close()
  if copied == nil then
    return false, "copy: " .. src .. " -> " .. dst .. ": " .. tostring(pump_err)
  end
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

--- Update a path's access and modification times to now, creating a
--- file (mode 0644 by default) if nothing is there.
---
--- Stamping first and creating only when that fails, rather than
--- opening for write unconditionally: utimensat asks for OWNERSHIP,
--- open asks for WRITE PERMISSION, and the second is the stricter
--- question. Opening first made `touch` fail on a read-only file its
--- own caller owns, and on a directory (EISDIR) -- neither of which
--- `touch(1)` refuses.
--- @param path string Path to the file
--- @param mode integer Permission bits when creating (default 0644)
--- @return boolean True on success
--- @return string Error message if failed
local function touch(path: string, mode?: integer): boolean, string
  local rc, terr = unix.utimensat(path,
    0, unix.UTIME_NOW, 0, unix.UTIME_NOW)
  if rc == 0 then
    return true
  end
  local fd, oerr = unix.open(path,
    unix.O_WRONLY | unix.O_CREAT, mode or tonumber("644", 8))
  if not fd then
    return false, errstr(oerr or terr, "touch: " .. path)
  end
  unix.close(fd)
  local again, aerr = unix.utimensat(path,
    0, unix.UTIME_NOW, 0, unix.UTIME_NOW)
  if again ~= 0 then
    return false, errstr(aerr, "touch: " .. path)
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
--- @param mode integer Access mode: F_OK (exists, the default), R_OK, W_OK, X_OK
--- @return boolean True if access is allowed
local function access(path: string, mode?: integer): boolean
  -- The binding returns true or nil, err; callers get an honest boolean.
  return unix.access(path, mode or unix.F_OK) == true
end

--- Change file permissions.
--- @param path string Path to the file
--- @param mode integer New permission bits (e.g., 0644)
--- @return boolean True on success
--- @return string Error message if failed
local function chmod(path: string, mode: integer): boolean, string
  local ok, err = unix.chmod(path, mode)
  if not ok then
    return false, errstr(err, "chmod: " .. path)
  end
  return true
end

--- Change file owner and group.
--- @param path string Path to the file
--- @param uid integer New owner user ID
--- @param gid integer New owner group ID
--- @return boolean True on success
--- @return string Error message if failed
local function chown(path: string, uid: integer, gid: integer): boolean, string
  local ok, err = unix.chown(path, uid, gid)
  if not ok then
    return false, errstr(err, "chown: " .. path)
  end
  return true
end

-- Timestamp operations

--- One timestamp for set_times: whole seconds plus optional
--- nanoseconds (default 0 — a bare secs value always means a literal
--- stamp, never "now"). nsecs may be unix.UTIME_NOW/UTIME_OMIT when a
--- caller wants that raw kernel behavior.
local record Timespec
  secs: integer
  nsecs: integer
end

--- The timestamps set_times/set_times_fd apply. Omit a field to leave
--- that timestamp exactly as it is (api-review-6: this record replaces
--- utimensat/futimens and their five positionals, whose nil meant
--- "unchanged" in one slot and "zero" in the next).
local record Times
  atime: Timespec
  mtime: Timespec
end

--- Resolve one Timespec to what the raw binding expects: nil means
--- "leave untouched" (UTIME_OMIT in the nsec slot makes the kernel
--- ignore the secs slot entirely).
local function resolve_time(t?: Timespec): integer, integer
  if t == nil then
    return 0, unix.UTIME_OMIT
  end
  return t.secs, t.nsecs or 0
end

--- Change file access and modification times.
--- Sets the timestamps named in `times` and leaves the others exactly
--- as they are; like touch(1), this works on read-only files (it asks
--- for utimensat's metadata permission, not open-for-write).
--- @param path string Path to the file
--- @param times Times atime/mtime to set; an omitted field is unchanged
--- @return boolean True on success
--- @return string Error message if failed
local function set_times(path: string, times: Times): boolean, string
  local a_secs, a_nsecs = resolve_time(times.atime)
  local m_secs, m_nsecs = resolve_time(times.mtime)
  local rc, err = unix.utimensat(path, a_secs, a_nsecs, m_secs, m_nsecs)
  if rc ~= 0 then
    return false, errstr(err, "utimensat: " .. path)
  end
  return true
end

--- Change file access and modification times on a file descriptor.
--- Same semantics as set_times().
--- @param fd integer File descriptor
--- @param times Times atime/mtime to set; an omitted field is unchanged
--- @return boolean True on success
--- @return string Error message if failed
local function set_times_fd(fd: integer, times: Times): boolean, string
  local a_secs, a_nsecs = resolve_time(times.atime)
  local m_secs, m_nsecs = resolve_time(times.mtime)
  local rc, err = unix.futimens(fd, a_secs, a_nsecs, m_secs, m_nsecs)
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

--- A created temp file: the open Handle plus its path. A record so the
--- error stays in slot 2 — the old (Handle, path, err) triple put a
--- SUCCESS value where `local h, err = ...` expected the error.
local record TmpFile
  --- Open handle to the created file; the Handle owns the descriptor.
  handle: Handle
  --- Path to the created file. NOT unlinked automatically — remove it
  --- when done. For an anonymous descriptor, use tmpfd() + fd.wrap().
  path: string
end

--- Create a temporary file, returning an open fd.Handle plus its path.
--- @param template string Path template ending in XXXXXX (default: $TMPDIR/cosmic_XXXXXX)
--- @return TmpFile | nil The handle and path, or nil on error
--- @return string Error message if failed
local function tmpfile(template?: string): TmpFile | nil, string
  template = template or ((os.getenv("TMPDIR") or "/tmp") .. "/cosmic_XXXXXX")
  -- The binding returns (fd, path) on success and (nil, Errno) on failure.
  local fd, path = unix.mkstemp(template)
  if not fd then
    return nil, errstr(path, "tmpfile: " .. template)
  end
  return {handle = cfd.wrap(fd), path = path}
end

--- Create a temporary file descriptor.
--- @return integer | nil File descriptor, or nil on error
--- @return string Error message if failed
local function tmpfd(): integer | nil, string
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
  return info as Statfs -- cast: userdata boundary
end

--- Get filesystem statistics from a file descriptor.
--- @param fd integer File descriptor
--- @return Statfs | nil Filesystem statistics, or nil on error
--- @return string Error message if failed
local function fstatfs(fd: integer): Statfs | nil, string
  local info, err = unix.fstatfs(fd)
  if not info then
    return nil, errstr(err, "fstatfs")
  end
  return info as Statfs -- cast: userdata boundary
end

--- Flush all filesystem buffers to disk, system-wide (sync(2)).
--- Infallible: the syscall reports nothing. For a single file use
--- Handle:sync()/Handle:datasync() from cosmic.fd.
local function sync()
  unix.sync()
end

-- Device number utilities

--- Extract major device number from a device ID.
--- @param dev integer Device ID from stat
--- @return integer Major device number
local function major(dev: integer): integer
  return unix.major(dev)
end

--- Extract minor device number from a device ID.
--- @param dev integer Device ID from stat
--- @return integer Minor device number
local function minor(dev: integer): integer
  return unix.minor(dev)
end

local record FsOpsModule
  unlink: function(path: string): boolean, string
  rename: function(oldpath: string, newpath: string): boolean, string
  copy: function(src: string, dst: string): boolean, string
  move: function(oldpath: string, newpath: string): boolean, string
  touch: function(path: string, mode?: integer): boolean, string
  link: function(existingpath: string, newpath: string): boolean, string
  symlink: function(target: string, linkpath: string): boolean, string
  readlink: function(path: string): string | nil, string
  realpath: function(path: string): string | nil, string
  rmrf: function(path: string): boolean, string
  access: function(path: string, mode?: integer): boolean
  chmod: function(path: string, mode: integer): boolean, string
  chown: function(path: string, uid: integer, gid: integer): boolean, string
  type Timespec = Timespec
  type Times = Times
  set_times: function(path: string, times: Times): boolean, string
  set_times_fd: function(fd: integer, times: Times): boolean, string
  mkdtemp: function(template: string): string | nil, string
  type TmpFile = TmpFile
  tmpfile: function(template?: string): TmpFile | nil, string
  tmpfd: function(): integer | nil, string
  statfs: function(path: string): Statfs | nil, string
  fstatfs: function(fd: integer): Statfs | nil, string
  sync: function()
  major: function(dev: integer): integer
  minor: function(dev: integer): integer
  F_OK: integer
  R_OK: integer
  W_OK: integer
  X_OK: integer
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
  set_times = set_times,
  set_times_fd = set_times_fd,
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
