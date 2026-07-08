--- Low-level child-process I/O primitives.
---
--- Holds the poll-driven `pump` that concurrently feeds a child's stdin while
--- draining its stdout and stderr. Doing all three in one poll loop is what
--- keeps large I/O in any direction from deadlocking on a full pipe buffer.
--- The pump is deadline-aware and resumable: `cosmic.child` drives it through
--- a shared PumpState so a `wait(timeout_ms)` that expires can be resumed by a
--- later call, and the partial output collected so far is never lost.
local unix = require("cosmo.unix")
local poll = require("cosmic.poll")
local errno = require("cosmic.errno")
local time = require("cosmic.time")

-- Writing to a pipe whose read end has already closed raises SIGPIPE, whose
-- default action terminates the process. A library that writes to a child's
-- stdin must never let the child's early exit kill its parent, so neutralize
-- SIGPIPE process-wide; the write then fails with EPIPE, which pump handles.
unix.sigaction(unix.SIGPIPE, unix.SIG_IGN)

local CHUNK = 65536

--- Mutable state threaded through `pump`. `cosmic.child` owns one per handle.
--- Each fd field is nilled (and the fd closed) as that stream finishes, so a
--- resumed pump only watches what is still live. `out`/`err_out` accumulate
--- across calls; `stdin_off` records progress feeding `stdin_data`.
local record PumpState
  stdout_fd: number
  stderr_fd: number
  stdin_fd: number
  stdin_data: string
  stdin_off: integer
  out: {string}
  err_out: {string}
  io_err: string
end

-- Current monotonic time in milliseconds. Used only for relative deadline
-- arithmetic, so the arbitrary epoch does not matter.
local function now_ms(): number
  local secs, nanos = time.monotonic()
  return secs * 1000 + nanos / 1000000
end

-- Put a pipe write end into non-blocking mode so a stdin write in the pump
-- can never block the loop that is simultaneously draining stdout/stderr.
-- F_SETFL replaces the file-status flags, but a fresh pipe write end carries
-- none worth preserving (F_SETFL ignores the access mode), so setting
-- O_NONBLOCK outright is safe.
local function set_nonblocking(fd: number): boolean, string
  local ok = unix.fcntl(fd, unix.F_SETFL, unix.O_NONBLOCK)
  if not ok then
    return false, "fcntl F_SETFL O_NONBLOCK failed"
  end
  return true
end

--- Drive `state` forward: feed stdin while draining stdout/stderr, all in one
--- poll loop so no direction can deadlock on a full pipe buffer. Returns
--- `true` if `deadline_ms` (an absolute `now_ms()` value, or nil for no limit)
--- elapsed before every stream finished — the child may still be running and
--- the caller can resume by calling `pump` again with the same state. Returns
--- `false` once stdin is fully sent and stdout/stderr have both hit EOF; each
--- fd is closed and nilled in `state` as it completes.
--- @param state PumpState shared, mutable I/O state
--- @param deadline_ms number? absolute monotonic-ms deadline, or nil
--- @return boolean timed_out
local function pump(state: PumpState, deadline_ms: number): boolean
  local p = poll.new()
  if state.stdout_fd then p:add(state.stdout_fd, poll.POLLIN) end
  if state.stderr_fd then p:add(state.stderr_fd, poll.POLLIN) end

  -- stdin: watch for writability only while bytes remain; otherwise close it
  -- now so the child sees EOF immediately.
  if state.stdin_fd then
    if state.stdin_data and state.stdin_off < #state.stdin_data then
      local ok, serr = set_nonblocking(state.stdin_fd)
      if not ok then state.io_err = state.io_err or serr end
      p:add(state.stdin_fd, poll.POLLOUT)
    else
      unix.close(state.stdin_fd)
      state.stdin_fd = nil
    end
  end

  -- Read whatever is ready on fd into buf; on EOF, a read error, or a hangup
  -- with no pending data, drop it from the set and close/nil it in `state`.
  -- When both readable and hangup are set, data still remains, so read.
  local function read_ready(fd: number, buf: {string}, which: string)
    local ev0 = p:events(fd)
    if not ev0 then return end
    local ev = ev0 as {string: boolean}
    if ev.readable then
      local chunk, rerr = unix.read(fd, CHUNK)
      if chunk == nil then
        state.io_err = state.io_err or errno.str(rerr, "read")
        p:remove(fd); unix.close(fd)
        if which == "out" then state.stdout_fd = nil else state.stderr_fd = nil end
      elseif chunk == "" then
        p:remove(fd); unix.close(fd)
        if which == "out" then state.stdout_fd = nil else state.stderr_fd = nil end
      else
        table.insert(buf, chunk)
      end
    elseif ev.hangup or ev.error or ev.invalid then
      p:remove(fd); unix.close(fd)
      if which == "out" then state.stdout_fd = nil else state.stderr_fd = nil end
    end
  end

  while not p:empty() do
    local timeout: integer = -1
    if deadline_ms then
      local rem = deadline_ms - now_ms()
      if rem <= 0 then return true end
      -- poll wants an integer millisecond count; floor the remaining time
      -- (any sub-millisecond remainder is caught by the next deadline check).
      timeout = math.floor(rem) as integer
    end
    local ready, perr = p:poll(timeout)
    if ready == nil then
      state.io_err = state.io_err or perr
      break
    end
    if ready == 0 then
      -- poll timed out with nothing ready: the deadline expired.
      return true
    end
    if state.stdin_fd then
      local ev = p:events(state.stdin_fd) as {string: boolean}
      if ev and ev.writable then
        local slice = state.stdin_data:sub(state.stdin_off + 1, state.stdin_off + CHUNK)
        local n, werr, weno = unix.write(state.stdin_fd, slice)
        if n ~= nil then
          state.stdin_off = state.stdin_off + (n as integer)
          if state.stdin_off >= #state.stdin_data then
            p:remove(state.stdin_fd); unix.close(state.stdin_fd); state.stdin_fd = nil
          end
        elseif errno.is(weno, "EAGAIN") then
          -- Not actually writable yet; try again on the next poll.
        elseif errno.is(weno, "EPIPE") then
          -- The child stopped reading stdin; stop feeding it (not an error).
          p:remove(state.stdin_fd); unix.close(state.stdin_fd); state.stdin_fd = nil
        else
          state.io_err = state.io_err or errno.str(werr, "write stdin")
          p:remove(state.stdin_fd); unix.close(state.stdin_fd); state.stdin_fd = nil
        end
      elseif ev and (ev.error or ev.hangup or ev.invalid) then
        p:remove(state.stdin_fd); unix.close(state.stdin_fd); state.stdin_fd = nil
      end
    end
    if state.stdout_fd then read_ready(state.stdout_fd, state.out, "out") end
    if state.stderr_fd then read_ready(state.stderr_fd, state.err_out, "err") end
  end

  return false
end

local record ChildIoModule
  PumpState: PumpState
  pump: function(state: PumpState, deadline_ms: number): boolean
  now_ms: function(): number
end

local M: ChildIoModule = {
  pump = pump,
  now_ms = now_ms,
}

return M
