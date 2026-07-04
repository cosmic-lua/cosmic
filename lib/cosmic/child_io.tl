--- Low-level child-process I/O primitives.
---
--- Holds the pipe wrapper shared by cosmic.child and a poll-driven `pump`
--- that concurrently feeds a child's stdin while draining its stdout and
--- stderr. Doing all three in one poll loop is what keeps large I/O in any
--- direction from deadlocking on a full pipe buffer.
local unix = require("cosmo.unix")
local poll = require("cosmic.poll")
local errno = require("cosmic.errno")

-- Writing to a pipe whose read end has already closed raises SIGPIPE, whose
-- default action terminates the process. A library that writes to a child's
-- stdin must never let the child's early exit kill its parent, so neutralize
-- SIGPIPE process-wide; the write then fails with EPIPE, which pump handles.
unix.sigaction(unix.SIGPIPE, unix.SIG_IGN)

local CHUNK = 65536

--- A pipe endpoint. `fd` is a plain field (not a method like io.Handle:fd()).
local record Pipe
  fd: number
  write: function(self: Pipe, data: string): number, string
  read: function(self: Pipe, size?: number): string, string
  close: function(self: Pipe)
end

--- Wrap a raw pipe fd in a Pipe. Returns nil when fd is nil.
--- read()/write() return `nil, err` on a real I/O error; read() returns ""
--- only on genuine end-of-file, so an error is never mistaken for EOF.
--- @param fd number Raw file descriptor, or nil
--- @return Pipe wrapper, or nil when fd is nil
local function make_pipe(fd: number): Pipe
  if not fd then
    return nil
  end
  local pipe: Pipe = {fd = fd}

  function pipe:write(data: string): number, string
    local n, err = unix.write(self.fd, data)
    if n == nil then
      return nil, errno.str(err, "write")
    end
    return n
  end

  function pipe:read(size?: number): string, string
    if size then
      local chunk, err = unix.read(self.fd, size)
      if chunk == nil then
        return nil, errno.str(err, "read")
      end
      return chunk
    end
    local chunks: {string} = {}
    while true do
      local chunk, err = unix.read(self.fd, CHUNK)
      if chunk == nil then
        return nil, errno.str(err, "read")
      end
      if chunk == "" then
        break
      end
      table.insert(chunks, chunk)
    end
    return table.concat(chunks)
  end

  pipe.close = function(self: Pipe)
    if self.fd then
      local _ = unix.close(self.fd)
      self.fd = nil
    end
  end

  return pipe
end

-- Put a pipe write end into non-blocking mode so a stdin write in the pump
-- can never block the loop that is simultaneously draining stdout/stderr.
-- F_SETFL replaces the file-status flags, but a fresh pipe write end carries
-- none worth preserving (F_SETFL ignores the access mode), so setting
-- O_NONBLOCK outright is safe — and F_GETFL is not usable here anyway (the
-- runtime returns a boolean for it rather than the flag bits).
local function set_nonblocking(fd: number): boolean, string
  local ok = unix.fcntl(fd, unix.F_SETFL, unix.O_NONBLOCK)
  if not ok then
    return false, "fcntl F_SETFL O_NONBLOCK failed"
  end
  return true
end

--- Concurrently write `stdin_data` to `stdin_fd` while draining `stdout_fd`
--- and `stderr_fd` to end-of-file, all in one poll loop so no direction can
--- deadlock on a full pipe buffer. `stdin_fd` is closed when the write
--- finishes or the child hangs up (EPIPE); stdout/stderr fds are left open
--- for the caller to close. A read/write error stops that stream and is
--- reported; EPIPE on stdin (the child stopped reading) is not an error.
--- @param stdout_fd number stdout read end, or nil
--- @param stderr_fd number stderr read end, or nil
--- @param stdin_fd number stdin write end, or nil
--- @param stdin_data string bytes to send to stdin, or nil
--- @return string collected stdout
--- @return string collected stderr
--- @return string? first I/O error, or nil when clean
local function pump(stdout_fd: number, stderr_fd: number, stdin_fd: number, stdin_data: string): string, string, string
  local out: {string} = {}
  local err_out: {string} = {}
  local io_err: string = nil
  local p = poll.new()
  if stdout_fd then p:add(stdout_fd, poll.POLLIN) end
  if stderr_fd then p:add(stderr_fd, poll.POLLIN) end

  local w_off = 0
  if stdin_fd then
    if stdin_data and #stdin_data > 0 then
      local ok, serr = set_nonblocking(stdin_fd)
      if not ok then io_err = io_err or serr end
      p:add(stdin_fd, poll.POLLOUT)
    else
      unix.close(stdin_fd)
      stdin_fd = nil
    end
  end

  -- Read whatever is ready on fd into buf; drop it from the set on EOF, a
  -- read error, or a hangup with no pending data. When both readable and
  -- hangup are set, data still remains, so read rather than drop.
  local function read_ready(fd: number, buf: {string})
    local ev = p:events(fd)
    if not ev then return end
    if ev.readable then
      local chunk, rerr = unix.read(fd, CHUNK)
      if chunk == nil then
        io_err = io_err or errno.str(rerr, "read")
        p:remove(fd)
      elseif chunk == "" then
        p:remove(fd)
      else
        table.insert(buf, chunk)
      end
    elseif ev.hangup or ev.error or ev.invalid then
      p:remove(fd)
    end
  end

  while not p:empty() do
    local ready, perr = p:poll(-1)
    if ready == nil then
      io_err = io_err or perr
      break
    end
    if stdin_fd then
      local ev = p:events(stdin_fd)
      if ev and ev.writable then
        local n, werr = unix.write(stdin_fd, stdin_data:sub(w_off + 1, w_off + CHUNK))
        if n ~= nil then
          w_off = w_off + (n as integer)
          if w_off >= #stdin_data then
            p:remove(stdin_fd); unix.close(stdin_fd); stdin_fd = nil
          end
        elseif errno.is(werr, "EAGAIN") then
          -- Not actually writable yet; try again on the next poll.
        elseif errno.is(werr, "EPIPE") then
          -- The child stopped reading stdin; stop feeding it (not an error).
          p:remove(stdin_fd); unix.close(stdin_fd); stdin_fd = nil
        else
          io_err = io_err or errno.str(werr, "write stdin")
          p:remove(stdin_fd); unix.close(stdin_fd); stdin_fd = nil
        end
      elseif ev and (ev.error or ev.hangup or ev.invalid) then
        p:remove(stdin_fd); unix.close(stdin_fd); stdin_fd = nil
      end
    end
    if stdout_fd then read_ready(stdout_fd, out) end
    if stderr_fd then read_ready(stderr_fd, err_out) end
  end

  if stdin_fd then unix.close(stdin_fd) end
  return table.concat(out), table.concat(err_out), io_err
end

local record ChildIoModule
  Pipe: Pipe
  make_pipe: function(fd: number): Pipe
  pump: function(stdout_fd: number, stderr_fd: number, stdin_fd: number, stdin_data: string): string, string, string
end

local M: ChildIoModule = {
  make_pipe = make_pipe,
  pump = pump,
}

return M
