--- File descriptor I/O operations.
--- Wraps low-level file descriptor operations from cosmo.unix.
local cosmo = require("cosmo")

--- Result from a pipe operation.
local record PipeResult
  reader: number
  writer: number
end

-- Internal record with proper error return signatures for cosmo.unix functions
-- The actual cosmo.unix returns Errno objects on failure, but the .d.tl types
-- don't reflect this. We cast to our own type with correct signatures.
local record UnixIO
  open: function(path: string, flags: number, mode?: number, dirfd?: number): number, any
  close: function(fd: number): boolean, any
  read: function(fd: number, bufsiz?: number, offset?: number): string, any
  write: function(fd: number, data: string, offset?: number): number, any
  lseek: function(fd: number, offset: number, whence?: number): number, any
  truncate: function(path: string, length?: number): boolean, any
  ftruncate: function(fd: number, length?: number): boolean, any
  dup: function(oldfd: number, newfd?: number, flags?: number, lowest?: number): number, any
  pipe: function(flags?: number): number, number | any
  fcntl: function(fd: number, cmd: number, ...: any): any
  sync: function()
  fsync: function(fd: number): boolean, any
  fdatasync: function(fd: number): boolean, any

  -- Constants
  O_RDONLY: number
  O_WRONLY: number
  O_RDWR: number
  O_CREAT: number
  O_TRUNC: number
  O_APPEND: number
  O_EXCL: number
  O_CLOEXEC: number
  O_NONBLOCK: number
  O_DIRECT: number
  O_DIRECTORY: number
  O_NOFOLLOW: number
  SEEK_SET: number
  SEEK_CUR: number
  SEEK_END: number
  F_GETFD: number
  F_SETFD: number
  F_GETFL: number
  F_SETFL: number
  F_SETLK: number
  F_SETLKW: number
  F_RDLCK: number
  F_WRLCK: number
  F_UNLCK: number
  FD_CLOEXEC: number
  AT_FDCWD: number
end

local unix = require("cosmo.unix") as UnixIO

--- Opens a file and returns a file descriptor.
--- @param path string The path to the file
--- @param flags number Bitwise OR of O_* flags (e.g., O_RDONLY, O_WRONLY | O_CREAT)
--- @param mode number Optional file mode for creation (e.g., 0644)
--- @param dirfd number Optional directory file descriptor for relative paths
--- @return number File descriptor on success
--- @return string Error message on failure
local function open(path: string, flags: number, mode?: number, dirfd?: number): number, string
  local fd, err = unix.open(path, flags, mode, dirfd)
  if not fd then
    return nil, tostring(err)
  end
  return fd
end

--- Closes a file descriptor.
--- @param fd number The file descriptor to close
--- @return boolean True on success
--- @return string Error message on failure
local function close(fd: number): boolean, string
  local ok, err = unix.close(fd)
  if not ok then
    return false, tostring(err)
  end
  return true
end

--- Reads from a file descriptor.
--- Returns empty string on end of file.
--- @param fd number The file descriptor to read from
--- @param size number Optional maximum bytes to read (default: BUFSIZ)
--- @param offset number Optional offset for pread behavior
--- @return string Data read on success
--- @return string Error message on failure
local function read(fd: number, size?: number, offset?: number): string, string
  local data, err = unix.read(fd, size, offset)
  if data == nil and err then
    return nil, tostring(err)
  end
  return data or ""
end

--- Writes to a file descriptor.
--- @param fd number The file descriptor to write to
--- @param data string The data to write
--- @param offset number Optional offset for pwrite behavior
--- @return number Number of bytes written on success
--- @return string Error message on failure
local function write(fd: number, data: string, offset?: number): number, string
  local n, err = unix.write(fd, data, offset)
  if not n then
    return nil, tostring(err)
  end
  return n
end

--- Seeks to a position in a file.
--- @param fd number The file descriptor
--- @param offset number The offset to seek to
--- @param whence number Optional seek mode: SEEK_SET (default), SEEK_CUR, or SEEK_END
--- @return number New position from start of file
--- @return string Error message on failure
local function lseek(fd: number, offset: number, whence?: number): number, string
  local pos, err = unix.lseek(fd, offset, whence)
  if not pos then
    return nil, tostring(err)
  end
  return pos
end

--- Truncates a file to a specified length.
--- @param path string The path to the file
--- @param length number Optional new length (default: 0)
--- @return boolean True on success
--- @return string Error message on failure
local function truncate(path: string, length?: number): boolean, string
  local ok, err = unix.truncate(path, length)
  if not ok then
    return false, tostring(err)
  end
  return true
end

--- Truncates an open file to a specified length.
--- @param fd number The file descriptor
--- @param length number Optional new length (default: 0)
--- @return boolean True on success
--- @return string Error message on failure
local function ftruncate(fd: number, length?: number): boolean, string
  local ok, err = unix.ftruncate(fd, length)
  if not ok then
    return false, tostring(err)
  end
  return true
end

--- Duplicates a file descriptor.
--- @param oldfd number The file descriptor to duplicate
--- @param newfd number Optional specific fd number to use
--- @param flags number Optional flags (e.g., O_CLOEXEC)
--- @param lowest number Optional lowest acceptable fd number
--- @return number New file descriptor on success
--- @return string Error message on failure
local function dup(oldfd: number, newfd?: number, flags?: number, lowest?: number): number, string
  local fd, err = unix.dup(oldfd, newfd, flags, lowest)
  if not fd then
    return nil, tostring(err)
  end
  return fd
end

--- Creates a pipe for inter-process communication.
--- @param flags number Optional flags (O_CLOEXEC, O_NONBLOCK, O_DIRECT)
--- @return PipeResult Table with reader and writer file descriptors
--- @return string Error message on failure
local function pipe(flags?: number): PipeResult, string
  local reader, writer = unix.pipe(flags)
  if not reader then
    return nil, tostring(writer)
  end
  return { reader = reader, writer = writer as number }
end

--- Performs file control operations.
--- @param fd number The file descriptor
--- @param cmd number The command (F_GETFD, F_SETFD, F_GETFL, F_SETFL, etc.)
--- @param ... any Command-specific arguments
--- @return any Command-specific return value
local function fcntl(fd: number, cmd: number, ...: any): any
  return unix.fcntl(fd, cmd, ...)
end

--- Flushes all file system buffers to disk.
local function sync()
  unix.sync()
end

--- Flushes file data and metadata to disk.
--- @param fd number The file descriptor
--- @return boolean True on success
--- @return string Error message on failure
local function fsync(fd: number): boolean, string
  local ok, err = unix.fsync(fd)
  if not ok then
    return false, tostring(err)
  end
  return true
end

--- Flushes file data to disk (but not necessarily metadata).
--- @param fd number The file descriptor
--- @return boolean True on success
--- @return string Error message on failure
local function fdatasync(fd: number): boolean, string
  local ok, err = unix.fdatasync(fd)
  if not ok then
    return false, tostring(err)
  end
  return true
end

--- Reads entire file contents.
--- @param path string The path to the file
--- @return string File contents on success
--- @return string Error message on failure (nil contents)
local function slurp(path: string): string, string
  local data = cosmo.Slurp(path)
  if not data then
    return nil, "failed to read file: " .. path
  end
  return data
end

--- Writes data to a file, creating or overwriting it.
--- @param path string The path to the file
--- @param data string The data to write
--- @param mode number Optional file mode (e.g., 0644)
--- @return boolean True on success
--- @return string Error message on failure
local function barf(path: string, data: string, mode?: number): boolean, string
  local ok = cosmo.Barf(path, data, mode)
  if not ok then
    return false, "failed to write file: " .. path
  end
  return true
end

local record IoModule
  -- High-level file operations
  slurp: function(path: string): string, string
  barf: function(path: string, data: string, mode?: number): boolean, string

  -- Core operations
  open: function(path: string, flags: number, mode?: number, dirfd?: number): number, string
  close: function(fd: number): boolean, string
  read: function(fd: number, size?: number, offset?: number): string, string
  write: function(fd: number, data: string, offset?: number): number, string

  -- Positioning
  lseek: function(fd: number, offset: number, whence?: number): number, string
  truncate: function(path: string, length?: number): boolean, string
  ftruncate: function(fd: number, length?: number): boolean, string

  -- Duplication
  dup: function(oldfd: number, newfd?: number, flags?: number, lowest?: number): number, string
  pipe: function(flags?: number): PipeResult, string

  -- Control
  fcntl: function(fd: number, cmd: number, ...: any): any

  -- Sync
  sync: function()
  fsync: function(fd: number): boolean, string
  fdatasync: function(fd: number): boolean, string

  -- Open flags
  O_RDONLY: number
  O_WRONLY: number
  O_RDWR: number
  O_CREAT: number
  O_TRUNC: number
  O_APPEND: number
  O_EXCL: number
  O_CLOEXEC: number
  O_NONBLOCK: number
  O_DIRECT: number
  O_DIRECTORY: number
  O_NOFOLLOW: number

  -- Seek positions
  SEEK_SET: number
  SEEK_CUR: number
  SEEK_END: number

  -- fcntl commands
  F_GETFD: number
  F_SETFD: number
  F_GETFL: number
  F_SETFL: number
  F_SETLK: number
  F_SETLKW: number
  F_RDLCK: number
  F_WRLCK: number
  F_UNLCK: number
  FD_CLOEXEC: number

  -- Special directory fd
  AT_FDCWD: number
end

local M: IoModule = {
  -- High-level file operations
  slurp = slurp,
  barf = barf,

  -- Core operations
  open = open,
  close = close,
  read = read,
  write = write,

  -- Positioning
  lseek = lseek,
  truncate = truncate,
  ftruncate = ftruncate,

  -- Duplication
  dup = dup,
  pipe = pipe,

  -- Control
  fcntl = fcntl,

  -- Sync
  sync = sync,
  fsync = fsync,
  fdatasync = fdatasync,

  -- Open flags
  O_RDONLY = unix.O_RDONLY,
  O_WRONLY = unix.O_WRONLY,
  O_RDWR = unix.O_RDWR,
  O_CREAT = unix.O_CREAT,
  O_TRUNC = unix.O_TRUNC,
  O_APPEND = unix.O_APPEND,
  O_EXCL = unix.O_EXCL,
  O_CLOEXEC = unix.O_CLOEXEC,
  O_NONBLOCK = unix.O_NONBLOCK,
  O_DIRECT = unix.O_DIRECT,
  O_DIRECTORY = unix.O_DIRECTORY,
  O_NOFOLLOW = unix.O_NOFOLLOW,

  -- Seek positions
  SEEK_SET = unix.SEEK_SET,
  SEEK_CUR = unix.SEEK_CUR,
  SEEK_END = unix.SEEK_END,

  -- fcntl commands
  F_GETFD = unix.F_GETFD,
  F_SETFD = unix.F_SETFD,
  F_GETFL = unix.F_GETFL,
  F_SETFL = unix.F_SETFL,
  F_SETLK = unix.F_SETLK,
  F_SETLKW = unix.F_SETLKW,
  F_RDLCK = unix.F_RDLCK,
  F_WRLCK = unix.F_WRLCK,
  F_UNLCK = unix.F_UNLCK,
  FD_CLOEXEC = unix.FD_CLOEXEC,

  -- Special directory fd
  AT_FDCWD = unix.AT_FDCWD,
}

return M
