--- Filesystem file operations, permissions, timestamps, and temp files.
--- Internal submodule used by cosmic.fs.
local unix = require("cosmo.unix")
local cfd = require("cosmic.fd")
local stream = require("cosmic.stream")
local types = require("cosmic.fs.types")
local errno = require("cosmic.errno")
local errstr = errno.format
local Statfs = types.Statfs
local type Handle = cfd.Handle

-- File operations

--- Remove a file or symbolic link (#988: was `unlink`).
--- Does not remove directories; use remove_dir() or remove_all().
--- @param path string Path to the file to remove
--- @return boolean True on success
--- @return string Error message if failed
local function remove(path: string): boolean, string
  local ok, err = unix.unlink(path)
  if not ok then
    return false, errstr(err, "remove: " .. path)
  end
  return true
end

-- A call may move fewer bytes than asked; big asks keep syscalls few.
local COPY_CHUNK_BYTES = 0x40000000

--- Drain srcfd into dstfd kernel-side via unix.copy_file_range: bytes
--- never cross into userspace, so peak memory stays flat no matter the
--- file size (whilp/cosmopolitan#240). Returns "done" at EOF,
--- "fallback" when the platform or filesystem refuses the syscall
--- before any byte moved (ENOSYS, EXDEV, EINVAL, EOPNOTSUPP), or nil
--- and the error once bytes are in flight and the failure is real.
--- @param srcfd integer Source file descriptor
--- @param dstfd integer Destination file descriptor
--- @return string | nil "done", "fallback", or nil on failure
--- @return string Error message if failed
local function kernel_copy(srcfd: integer, dstfd: integer): string | nil, string
  local moved = false
  while true do
    local n, cerr, eno = unix.copy_file_range(srcfd, dstfd, COPY_CHUNK_BYTES)
    if n then
      if n == 0 then return "done" end
      moved = true
    elseif errno.is_code(eno, "EINTR") then
      -- retry, matching cosmic.fd's signal-safety posture
    elseif not moved and (errno.is_code(eno, "ENOSYS") or errno.is_code(eno, "EXDEV")
      or errno.is_code(eno, "EINVAL") or errno.is_code(eno, "EOPNOTSUPP")) then
      return "fallback"
    else
      return nil, cerr
    end
  end
end

--- Copy a file, preserving its permission bits.
--- Follows symlinks: copying a symlink copies the target's contents.
--- The destination is created (or truncated) and receives the source's
--- mode bits. Bytes move fd-to-fd inside the kernel where the platform
--- supports copy_file_range; elsewhere the buffered stream pump takes
--- over. Read and write retry automatically on EINTR, matching
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
  local mode = st:mode() & 0x1ff
  local dstfd, derr = unix.open(dst,
    unix.O_WRONLY | unix.O_CREAT | unix.O_TRUNC, mode)
  if not dstfd then
    unix.close(srcfd)
    return false, errstr(derr, "copy: open: " .. dst)
  end
  local sh = cfd.wrap(srcfd)
  local dh = cfd.wrap(dstfd)
  -- Kernel first; when it declines, the pump is cosmic.stream.copy over
  -- fd Handles: one buffered-copy algorithm for the whole stdlib, EINTR
  -- retried inside fd.Handle.
  local verdict, verr = kernel_copy(srcfd, dstfd)
  if verdict == "fallback" then
    local copied, pump_err = stream.copy(dh, sh)
    verdict = "done"
    if copied == nil then verdict, verr = nil, tostring(pump_err) end
  end
  local sok, scerr = sh:close()
  local dok, dcerr = dh:close()
  if verdict == nil then
    return false, "copy: " .. src .. " -> " .. dst .. ": " .. tostring(verr)
  end
  -- A failed close on the destination is how ENOSPC and write-back
  -- errors surface; reporting success past it hides a truncated copy.
  if not dok then
    return false, "copy: close: " .. dst .. ": " .. tostring(dcerr)
  end
  if not sok then
    return false, "copy: close: " .. src .. ": " .. tostring(scerr)
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
  if not errno.is_code(eno, "EXDEV") then
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

--- Get the canonical absolute path (#988: was `realpath`).
--- Resolves all symbolic links and removes . and .. components.
--- @param path string Path to resolve
--- @return string | nil Canonical path, or nil on error
--- @return string Error message if failed
local function resolve(path: string): string | nil, string
  local resolved, err = unix.realpath(path)
  if not resolved then
    return nil, errstr(err, "resolve: " .. path)
  end
  return resolved
end

--- Recursively remove a directory and all its contents.
--- Use with caution. `rm -rf` semantics: a path that does not exist is
--- already removed, so ENOENT is success — the call ensures absence,
--- and cleanup stays idempotent.
--- @param path string Path to the directory to remove
--- @return boolean True on success (including an already-absent path)
--- @return string Error message if failed
local function remove_all(path: string): boolean, string
  local ok, err, eno = unix.rmrf(path)
  if not ok then
    if errno.is_code(eno, "ENOENT") then
      return true
    end
    return false, errstr(err, "remove_all: " .. path)
  end
  return true
end

-- Permission operations

--- Check if the current process may access a file the given way
--- (#988: was `access` with an optional mode — parameterless access
--- duplicated is_present, so the mode is required now).
--- @param path string Path to check
--- @param mode integer Access mode: R_OK, W_OK, X_OK (or F_OK, which is is_present)
--- @return boolean True if access is allowed
local function is_accessible(path: string, mode: integer): boolean
  -- The binding returns true or nil, err; callers get an honest boolean.
  return unix.access(path, mode) == true
end

--- Change file permissions (#988: was `chmod`).
--- @param path string Path to the file
--- @param mode integer New permission bits (e.g., 0644)
--- @return boolean True on success
--- @return string Error message if failed
local function set_mode(path: string, mode: integer): boolean, string
  local ok, err = unix.chmod(path, mode)
  if not ok then
    return false, errstr(err, "set_mode: " .. path)
  end
  return true
end

--- Set the file mode creation mask, returning the previous one
--- (#993: moved from cosmic.user — the mask governs fs creation modes
--- for open()/make_dir(), which is filesystem policy, not identity).
--- @param mask integer The new file mode creation mask
--- @return integer The previous mask
local function set_umask(mask: integer): integer
  return unix.umask(mask)
end

--- Change file owner and group (#988: was `chown`).
--- @param path string Path to the file
--- @param uid integer New owner user ID
--- @param gid integer New owner group ID
--- @return boolean True on success
--- @return string Error message if failed
local function set_owner(path: string, uid: integer, gid: integer): boolean, string
  local ok, err = unix.chown(path, uid, gid)
  if not ok then
    return false, errstr(err, "set_owner: " .. path)
  end
  return true
end

-- Timestamp operations

-- Timespec/Times live in cosmic.fs.types (#988) so Stat:times() can
-- return them; these are the same records.
local type Timespec = types.Timespec
local type Times = types.Times

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
--- @param template string Path template ending in XXXXXX (default:
---   $TMPDIR/cosmic_XXXXXX — #988: every caller was hardcoding /tmp)
--- @return string | nil Path to the created directory, or nil on error
--- @return string Error message if failed
local function temp_dir(template?: string): string | nil, string
  template = template or ((os.getenv("TMPDIR") or "/tmp") .. "/cosmic_XXXXXX")
  local path, err = unix.mkdtemp(template)
  if not path then
    return nil, errstr(err, "temp_dir: " .. template)
  end
  return path
end

--- A created temp file: the open Handle plus its path. A record so the
--- error stays in slot 2 — the old (Handle, path, err) triple put a
--- SUCCESS value where `local h, err = ...` expected the error.
--- (#988: was `TmpFile` — rule 1 spells words out.)
local record TempFile
  --- Open handle to the created file; the Handle owns the descriptor.
  handle: Handle
  --- Path to the created file. NOT unlinked automatically — remove it
  --- when done. For an anonymous file with no path at all, use temp_fd().
  path: string
end

--- Create a temporary file, returning an open fd.Handle plus its path.
--- @param template string Path template ending in XXXXXX (default: $TMPDIR/cosmic_XXXXXX)
--- @return TempFile | nil The handle and path, or nil on error
--- @return string Error message if failed
local function temp_file(template?: string): TempFile | nil, string
  template = template or ((os.getenv("TMPDIR") or "/tmp") .. "/cosmic_XXXXXX")
  -- The binding returns (fd, path) on success and (nil, Errno) on failure.
  local fd, path = unix.mkstemp(template)
  if not fd then
    return nil, errstr(path, "temp_file: " .. template)
  end
  return {handle = cfd.wrap(fd), path = path}
end

--- Create an anonymous temporary file, returned as an open fd.Handle
--- (#988: was a bare descriptor, with matching wrap-it-yourself docs
--- here and in cosmic.fd).
--- @return Handle | nil Open handle, or nil on error
--- @return string Error message if failed
local function temp_fd(): Handle | nil, string
  local fd, err = unix.tmpfd()
  if not fd then
    return nil, errstr(err, "temp_fd")
  end
  return cfd.wrap(fd)
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
  -- cast: userdata boundary (wrap installs the spelled methods)
  return types.wrap_statfs(info as any)
end

--- Get filesystem statistics from a file descriptor (#988: was
--- `fstatfs` — fd variants standardize on the `_fd` suffix).
--- @param fd integer File descriptor
--- @return Statfs | nil Filesystem statistics, or nil on error
--- @return string Error message if failed
local function statfs_fd(fd: integer): Statfs | nil, string
  local info, err = unix.fstatfs(fd)
  if not info then
    return nil, errstr(err, "statfs_fd")
  end
  -- cast: userdata boundary (wrap installs the spelled methods)
  return types.wrap_statfs(info as any)
end

--- Flush all filesystem buffers to disk, system-wide (sync(2)) —
--- #988: was `sync`, ambiguous beside Handle:sync's one-file flush.
--- Infallible: the syscall reports nothing. For a single file use
--- Handle:sync()/Handle:datasync() from cosmic.fd.
local function sync_all()
  unix.sync()
end

local record FsOpsModule
  remove: function(path: string): boolean, string
  copy: function(src: string, dst: string): boolean, string
  move: function(oldpath: string, newpath: string): boolean, string
  touch: function(path: string, mode?: integer): boolean, string
  link: function(existingpath: string, newpath: string): boolean, string
  symlink: function(target: string, linkpath: string): boolean, string
  readlink: function(path: string): string | nil, string
  resolve: function(path: string): string | nil, string
  remove_all: function(path: string): boolean, string
  is_accessible: function(path: string, mode: integer): boolean
  set_mode: function(path: string, mode: integer): boolean, string
  set_umask: function(mask: integer): integer
  set_owner: function(path: string, uid: integer, gid: integer): boolean, string
  type Timespec = Timespec
  type Times = Times
  set_times: function(path: string, times: Times): boolean, string
  set_times_fd: function(fd: integer, times: Times): boolean, string
  temp_dir: function(template?: string): string | nil, string
  type TempFile = TempFile
  temp_file: function(template?: string): TempFile | nil, string
  temp_fd: function(): Handle | nil, string
  statfs: function(path: string): Statfs | nil, string
  statfs_fd: function(fd: integer): Statfs | nil, string
  sync_all: function()
  F_OK: integer
  R_OK: integer
  W_OK: integer
  X_OK: integer

end

local M: FsOpsModule = {
  remove = remove,
  copy = copy,
  move = move,
  touch = touch,
  link = link,
  symlink = symlink,
  readlink = readlink,
  resolve = resolve,
  remove_all = remove_all,
  is_accessible = is_accessible,
  set_mode = set_mode,
  set_umask = set_umask,
  set_owner = set_owner,
  set_times = set_times,
  set_times_fd = set_times_fd,
  temp_dir = temp_dir,
  temp_file = temp_file,
  temp_fd = temp_fd,
  statfs = statfs,
  statfs_fd = statfs_fd,
  sync_all = sync_all,
  F_OK = unix.F_OK,
  R_OK = unix.R_OK,
  W_OK = unix.W_OK,
  X_OK = unix.X_OK,

}

return M
