--- Filesystem operations.
--- Wraps cosmo.unix for file and directory operations: stat, mkdir, chmod, symlink, etc.
local unix = require("cosmo.unix")

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

  local mt: metatable<Dir> = {
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
  local ok = unix.mkdir(path, mode)
  if not ok then
    return false, "mkdir failed: " .. path
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
  local ok = unix.makedirs(path, mode)
  if not ok then
    return false, "makedirs failed: " .. path
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
--- Pass nil for either time to leave it unchanged.
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
--- The template must end with XXXXXX which will be replaced with random characters.
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
--- The template must end with XXXXXX which will be replaced with random characters.
--- Returns both the file descriptor and the path.
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
--- The file is automatically deleted when closed.
--- @return number File descriptor, or nil on error
--- @return string Error message if failed
local function tmpfd(): number, string
  local fd = unix.tmpfd()
  if not fd then
    return nil, "tmpfd failed"
  end
  return fd
end

-- Access mode constants
local F_OK <const> = unix.F_OK
local R_OK <const> = unix.R_OK
local W_OK <const> = unix.W_OK
local X_OK <const> = unix.X_OK

-- Example demonstrating basic fs operations
local function Example_basic()
  local fs = require("cosmic.fs")
  local path = require("cosmo.path")

  -- Create a temp directory
  local tmpdir = fs.mkdtemp("/tmp/fs_example_XXXXXX")
  if not tmpdir then
    print("failed to create temp dir")
    return
  end
  print("created temp dir:", tmpdir)

  -- Create a subdirectory
  local subdir = path.join(tmpdir, "subdir")
  local ok, err = fs.mkdir(subdir)
  if not ok then
    print("mkdir failed:", err)
    fs.rmrf(tmpdir)
    return
  end

  -- Check if it exists
  local st = fs.stat(subdir)
  if st and fs.is_dir(st:mode()) then
    print("subdir is a directory")
  end

  -- Create a symlink
  local linkpath = path.join(tmpdir, "link")
  ok, err = fs.symlink(subdir, linkpath)
  if ok then
    local target = fs.readlink(linkpath)
    print("symlink points to:", target)
  end

  -- Clean up
  fs.rmrf(tmpdir)
  print("cleaned up")

  -- Output:
  -- created temp dir:	/tmp/fs_example_XXXXXX (with random suffix)
  -- subdir is a directory
  -- symlink points to:	/tmp/fs_example_XXXXXX/subdir
  -- cleaned up
end

--- Module interface
local record FsModule
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

  -- Access mode constants
  F_OK: number
  R_OK: number
  W_OK: number
  X_OK: number
end

local M: FsModule = {
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

  -- File operations
  unlink = unlink,
  rename = rename,
  link = link,
  symlink = symlink,
  readlink = readlink,
  realpath = realpath,
  rmrf = rmrf,

  -- Permission operations
  access = access,
  chmod = chmod,
  chown = chown,

  -- Timestamp operations
  utimensat = utimensat,
  futimens = futimens,

  -- Temporary file operations
  mkdtemp = mkdtemp,
  mkstemp = mkstemp,
  tmpfd = tmpfd,

  -- Access mode constants
  F_OK = F_OK,
  R_OK = R_OK,
  W_OK = W_OK,
  X_OK = X_OK,
}

return M
