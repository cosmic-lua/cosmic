--- File descriptor I/O operations.
--- Wraps low-level file descriptor operations from cosmo.unix.
--- Supports Lua 5.4's to-be-closed via __close metamethod on Handle and Pipe.
---
--- cosmic.fd has NO stderr, stdout, or stdin handles. For stream I/O use
--- Lua's standard library directly:
---   io.stderr:write("error: " .. msg .. "\n")
---   io.stdout:write(data)
---
--- For whole-file path-based operations use cosmic.fs: fs.read(path),
--- fs.write(path, data), fs.truncate(path).
---
--- EINTR posture: Handle read/write/seek do NOT retry automatically. When
--- a signal interrupts the call, it returns nil plus an EINTR-tagged
--- error; callers that install signal handlers detect it with
--- `errno.name_of(err) == "EINTR"` and retry themselves. (Automatic
--- retry is deferred to the signal-safety wave.)
local unix = require("cosmo.unix")
local errstr = require("cosmic.errno").str

--- File handle for I/O operations.
--- Supports Lua 5.4's to-be-closed via __close metamethod.
local record Handle
  close: function(self: Handle): boolean, string
  closed: function(self: Handle): boolean
  fd: function(self: Handle): number
  read: function(self: Handle, size?: number, offset?: number): string | nil, string
  write: function(self: Handle, data: string, offset?: number): number | nil, string
  seek: function(self: Handle, offset: number, whence?: number): number | nil, string
  truncate: function(self: Handle, length?: number): boolean, string
  sync: function(self: Handle): boolean, string
  datasync: function(self: Handle): boolean, string
  dup: function(self: Handle, newfd?: number, flags?: number, lowest?: number): Handle | nil, string
  fcntl: function(self: Handle, cmd: number, arg?: number): number | nil, string
end

local make_handle: function(fd: number): Handle

make_handle = function(fd: number): Handle
  local handle_fd: number = fd
  local handle: Handle = {}

  --- Close the handle. Idempotent.
  --- Returns false + error message if unix.close() fails; true on success.
  --- A second call on an already-closed handle always returns true.
  function handle:close(): boolean, string
    if handle_fd then
      local ok, err = unix.close(handle_fd)
      handle_fd = nil
      if not ok then
        return false, errstr(err, "close")
      end
    end
    return true
  end

  --- Returns true if closed.
  function handle:closed(): boolean
    return handle_fd == nil
  end

  --- Returns the underlying file descriptor, or -1 if closed.
  function handle:fd(): number
    return handle_fd or -1
  end

  --- Read up to size bytes. Returns nil with NO error on EOF (Lua
  --- convention: `while true do local chunk = h:read(n); if not chunk
  --- then break end ... end`), and nil WITH an error on failure —
  --- including EAGAIN on a nonblocking fd with no data, and EINTR when
  --- a signal interrupts the read (see the module header; not retried).
  --- If offset is provided, reads at that position (pread behavior).
  function handle:read(size?: number, offset?: number): string | nil, string
    if not handle_fd then
      return nil, "handle closed"
    end
    local data, err = unix.read(handle_fd, size, offset)
    if data == nil and err then
      return nil, errstr(err, "read")
    end
    if data == nil or data == "" then
      return nil -- EOF: nil with no error
    end
    return data
  end

  --- Write data. Returns number of bytes written (which may be fewer
  --- than #data — callers writing everything must loop). On failure
  --- returns nil plus an error; EINTR is not retried (see module header).
  --- If offset is provided, writes at that position (pwrite behavior).
  function handle:write(data: string, offset?: number): number | nil, string
    if not handle_fd then
      return nil, "handle closed"
    end
    local n, err = unix.write(handle_fd, data, offset)
    if not n then
      return nil, errstr(err, "write")
    end
    return n
  end

  --- Seek to position. whence: SEEK_SET (default), SEEK_CUR, SEEK_END.
  --- On failure returns nil plus an error; EINTR is not retried.
  function handle:seek(offset: number, whence?: number): number | nil, string
    if not handle_fd then
      return nil, "handle closed"
    end
    local pos, err = unix.lseek(handle_fd, offset, whence)
    if not pos then
      return nil, errstr(err, "lseek")
    end
    return pos
  end

  --- Truncate to length (default 0).
  function handle:truncate(length?: number): boolean, string
    if not handle_fd then
      return false, "handle closed"
    end
    local ok, err = unix.ftruncate(handle_fd, length)
    if not ok then
      return false, errstr(err, "ftruncate")
    end
    return true
  end

  --- Flush data and metadata to disk.
  function handle:sync(): boolean, string
    if not handle_fd then
      return false, "handle closed"
    end
    local ok, err = unix.fsync(handle_fd)
    if not ok then
      return false, errstr(err, "fsync")
    end
    return true
  end

  --- Flush data to disk (but not necessarily metadata).
  function handle:datasync(): boolean, string
    if not handle_fd then
      return false, "handle closed"
    end
    local ok, err = unix.fdatasync(handle_fd)
    if not ok then
      return false, errstr(err, "fdatasync")
    end
    return true
  end

  --- Duplicate the handle.
  --- If newfd is provided, duplicates to that specific fd (dup2 behavior).
  --- flags can include O_CLOEXEC. lowest specifies minimum acceptable fd.
  function handle:dup(newfd?: number, flags?: number, lowest?: number): Handle | nil, string
    if not handle_fd then
      return nil, "handle closed"
    end
    local dupfd, err = unix.dup(handle_fd, newfd, flags, lowest)
    if not dupfd then
      return nil, errstr(err, "dup")
    end
    return make_handle(dupfd)
  end

  --- File control operations. cmd: F_GETFD, F_SETFD, F_GETFL, F_SETFL, F_SETLK, etc.
  function handle:fcntl(cmd: number, arg?: number): number | nil, string
    if not handle_fd then
      return nil, "handle closed"
    end
    local result, err = unix.fcntl(handle_fd, cmd, arg)
    if result == nil then
      return nil, errstr(err, "fcntl")
    end
    return result as number
  end

  return setmetatable(handle, {
      __close = function(self: Handle) self:close() end
    }) as Handle
end

--- Pipe for inter-process communication.
--- Supports Lua 5.4's to-be-closed via __close metamethod.
local record Pipe
  reader: Handle
  writer: Handle
  close: function(self: Pipe): boolean
  closed: function(self: Pipe): boolean
end

local function make_pipe(reader: Handle, writer: Handle): Pipe
  local p: Pipe = {
    reader = reader,
    writer = writer,
  }

  function p:close(): boolean
    self.reader:close()
    self.writer:close()
    return true
  end

  function p:closed(): boolean
    return self.reader:closed() and self.writer:closed()
  end

  return setmetatable(p, {
      __close = function(self: Pipe) self:close() end
    }) as Pipe
end

--- Open a file. flags: O_RDONLY, O_WRONLY, O_RDWR, combined with O_CREAT, O_TRUNC, etc.
--- If dirfd is provided, path is relative to that directory (openat behavior).
local function open(path: string, flags: number, mode?: number, dirfd?: number): Handle | nil, string
  local fd, err = unix.open(path, flags, mode, dirfd)
  if not fd then
    return nil, errstr(err, "open: " .. path)
  end
  return make_handle(fd)
end

--- Create a pipe. flags: O_CLOEXEC, O_NONBLOCK.
local function pipe(flags?: number): Pipe | nil, string
  local reader_fd, writer_fd = unix.pipe(flags)
  if not reader_fd then
    -- On failure the binding returns (nil, err, errno): the error string
    -- arrives in the second slot, where the writer fd would have been.
    return nil, errstr(writer_fd, "pipe")
  end
  return make_pipe(make_handle(reader_fd), make_handle(writer_fd))
end

--- Wrap an already-open raw file descriptor in a Handle.
--- Lets fds from fs.tmpfd() (or any other source) enter the
--- Handle world: h:read()/h:write()/h:close(), plus automatic cleanup
--- via the __close metamethod. The Handle takes ownership: closing it
--- closes the fd.
local function wrap(rawfd: number): Handle
  return make_handle(rawfd)
end

local record FdModule
  -- Exported so callers can name/cast the fallible open/pipe results.
  type Handle = Handle
  type Pipe = Pipe

  open: function(path: string, flags: number, mode?: number, dirfd?: number): Handle | nil, string
  wrap: function(rawfd: number): Handle
  pipe: function(flags?: number): Pipe | nil, string

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
  F_GETLK: number
  F_RDLCK: number
  F_WRLCK: number
  F_UNLCK: number
  FD_CLOEXEC: number

  AT_FDCWD: number
end

local M: FdModule = {
  open = open,
  wrap = wrap,
  pipe = pipe,

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

  SEEK_SET = unix.SEEK_SET,
  SEEK_CUR = unix.SEEK_CUR,
  SEEK_END = unix.SEEK_END,

  F_GETFD = unix.F_GETFD,
  F_SETFD = unix.F_SETFD,
  F_GETFL = unix.F_GETFL,
  F_SETFL = unix.F_SETFL,
  F_SETLK = unix.F_SETLK,
  F_SETLKW = unix.F_SETLKW,
  F_GETLK = unix.F_GETLK,
  F_RDLCK = unix.F_RDLCK,
  F_WRLCK = unix.F_WRLCK,
  F_UNLCK = unix.F_UNLCK,
  FD_CLOEXEC = unix.FD_CLOEXEC,

  AT_FDCWD = unix.AT_FDCWD,
}

return M
