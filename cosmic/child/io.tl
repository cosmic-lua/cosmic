--- Low-level child-process I/O primitives.
---
--- Holds the poll-driven `pump` that concurrently feeds a child's stdin while
--- draining its stdout and stderr. Doing all three in one poll loop is what
--- keeps large I/O in any direction from deadlocking on a full pipe buffer.
--- The pump is deadline-aware and resumable: `cosmic.child` drives it through
--- a shared PumpState so a `wait(timeout_ms)` that expires can be resumed by a
--- later call, and the partial output collected so far is never lost.
local unix = require("cosmo.unix")
local cfd = require("cosmic.fd")
local poll = require("cosmic.poll")
local errno = require("cosmic.errno")
local time = require("cosmic.time")

-- Writing to a pipe whose read end has already closed raises SIGPIPE, whose
-- default action terminates the process. A library that writes to a child's
-- stdin must never let the child's early exit kill its parent. This installs
-- the ignore lazily, at the first start(), rather than at require() — an
-- eager install at require() would make merely importing the module change
-- process-wide signal state before any child exists — and only while the
-- disposition is still the default, so a handler the caller installed stays
-- theirs (their handler runs and the write still fails with EPIPE, which
-- pump handles). Children inherit SIG_IGN across exec.
local sigpipe_checked = false
local function neutralize_sigpipe()
  if sigpipe_checked then
    return
  end
  sigpipe_checked = true
  local prev = unix.sigaction(unix.SIGPIPE)
  if prev == unix.SIG_DFL then
    unix.sigaction(unix.SIGPIPE, unix.SIG_IGN)
  end
end

local CHUNK = 65536

--- Mutable state threaded through `pump`. `cosmic.child` owns one per handle.
--- Each fd field is nilled (and the fd closed) as that stream finishes, so a
--- resumed pump only watches what is still live. `out`/`err_out` accumulate
--- across calls; `stdin_off` records progress feeding `stdin_data`.
local record PumpState
  stdout_fd: integer
  stderr_fd: integer
  stdin_fd: integer
  stdin_data: string
  stdin_off: integer
  out: {string}
  err_out: {string}
  io_err: string
end

--- Raw descriptors resolved from the public spawn Options. The public
--- surface speaks fd.Handle; everything below this boundary speaks
--- raw descriptors.
local record Stdio
  stdin_data: string
  stdin_fd: integer
  stdout_fd: integer
  stderr_fd: integer
end

--- Non-Handle stdio dispositions. "inherit" hands the child this
--- process's own fd 1 / 2, so its output streams straight to wherever
--- ours goes instead of being captured and withheld until exit.
---
--- It resolves to the same "caller supplied this descriptor" path a
--- Handle takes, which spawn never closes -- so a caller never has to
--- reach for fd.wrap(1), which cosmic.fd explicitly does not model.
local enum StdioMode
  "inherit"
end

--- Resolve the caller's stdio options to raw descriptors, once, at the
--- boundary. A string stdin passes through as pump data; a Handle
--- contributes its descriptor. A closed Handle is a caller bug surfaced
--- here, not a confusing EBADF from deep inside the spawn plumbing.
--- @param stdin string | cfd.Handle | nil string to pipe, or the child's fd 0
--- @param stdout cfd.Handle | StdioMode | nil the child's fd 1
--- @param stderr cfd.Handle | StdioMode | nil the child's fd 2
--- @return Stdio | nil resolved descriptors
--- @return string error message on a closed Handle
local function resolve_stdio(stdin?: string | cfd.Handle,
    stdout?: cfd.Handle | StdioMode,
    stderr?: cfd.Handle | StdioMode): Stdio | nil, string
  -- Every start() resolves stdio exactly once, before forking, so this
  -- is the choke point where the lazy SIGPIPE install runs.
  neutralize_sigpipe()
  local s: Stdio = {}
  if stdin is string then
    s.stdin_data = stdin
  elseif stdin ~= nil then
    s.stdin_fd = stdin:fd()
    if s.stdin_fd < 0 then return nil, "start: stdin handle is closed" end
  end
  -- "inherit" resolves to our own descriptor, which then travels the
  -- identical path a caller-supplied Handle does: spawn dups it onto
  -- the child's fd and never closes our end.
  if stdout is StdioMode then
    s.stdout_fd = 1
  elseif stdout ~= nil then
    s.stdout_fd = stdout:fd()
    if s.stdout_fd < 0 then return nil, "start: stdout handle is closed" end
  end
  if stderr is StdioMode then
    s.stderr_fd = 2
  elseif stderr ~= nil then
    s.stderr_fd = stderr:fd()
    if s.stderr_fd < 0 then return nil, "start: stderr handle is closed" end
  end
  return s
end

-- Deadlines are absolute time.monotonic_ms() values: whole-integer
-- milliseconds, so deadline arithmetic never runs in floats.
local now_ms = time.monotonic_ms

--- Read up to bufsiz bytes from fd, retrying when a signal interrupts the
--- read (the signal-safety wave). Returns unix.read's (data, err).
local function read_retry(fd: integer, bufsiz: integer): string | nil, string | nil
  local data, err, eno = unix.read(fd, bufsiz)
  while data == nil and errno.is_code(eno, "EINTR") do
    data, err, eno = unix.read(fd, bufsiz)
  end
  return data, err
end

--- Reap pid with a blocking wait, retrying when a signal interrupts it
--- (the signal-safety wave). Returns (pid, status); on a hard wait
--- failure pid is nil and the error string sits in the status slot.
local function wait_retry(pid: integer): integer | nil, integer
  local wpid, status, weno = unix.wait(pid)
  while wpid == nil and errno.is_code(weno, "EINTR") do
    wpid, status, weno = unix.wait(pid)
  end
  return wpid, status
end

-- Put a pipe write end into non-blocking mode so a stdin write in the pump
-- can never block the loop that is simultaneously draining stdout/stderr.
-- F_SETFL replaces the file-status flags, but a fresh pipe write end carries
-- none worth preserving (F_SETFL ignores the access mode), so setting
-- O_NONBLOCK outright is safe.
local function set_nonblocking(fd: integer): boolean, string
  local ok = unix.fcntl(fd, unix.F_SETFL, unix.O_NONBLOCK)
  if not ok then
    return false, "fcntl F_SETFL O_NONBLOCK failed"
  end
  return true
end

--- Drive `state` forward: feed stdin while draining stdout/stderr, all in one
--- poll loop so no direction can deadlock on a full pipe buffer. Returns
--- `true` if `deadline_ms` (an absolute `time.monotonic_ms()` value, or nil
--- for no limit) elapsed before every stream finished — the child may still
--- be running and the caller can resume by calling `pump` again with the same
--- state. Returns
--- `false` once stdin is fully sent and stdout/stderr have both hit EOF; each
--- fd is closed and nilled in `state` as it completes.
--- @param state PumpState shared, mutable I/O state
--- @param deadline_ms number? absolute monotonic-ms deadline, or nil
--- @return boolean timed_out
local function pump(state: PumpState, deadline_ms: number): boolean
  local p = poll.new()
  if state.stdout_fd then local _ok, _err = p:add(state.stdout_fd, poll.POLLIN) end
  if state.stderr_fd then local _ok, _err = p:add(state.stderr_fd, poll.POLLIN) end

  -- stdin: watch for writability only while bytes remain; otherwise close it
  -- now so the child sees EOF immediately.
  if state.stdin_fd then
    if state.stdin_data and state.stdin_off < #state.stdin_data then
      local ok, serr = set_nonblocking(state.stdin_fd)
      if not ok then state.io_err = state.io_err or serr end
      local _ok, _err = p:add(state.stdin_fd, poll.POLLOUT)
    else
      unix.close(state.stdin_fd)
      state.stdin_fd = nil
    end
  end

  -- Read whatever is ready on fd into buf; on EOF, a read error, or a hangup
  -- with no pending data, drop it from the set and close/nil it in `state`.
  -- When both readable and hangup are set, data still remains, so read.
  local function read_ready(ready: {integer: poll.Events}, fd: integer, buf: {string}, which: string)
    local ev = ready[fd]
    if not ev then return end
    if ev.readable then
      local chunk, rerr, reno = unix.read(fd, CHUNK)
      if chunk == nil then
        -- Interrupted by a signal: leave the fd registered; the next poll
        -- round retries (the signal-safety wave).
        if errno.is_code(reno, "EINTR") then return end
        state.io_err = state.io_err or errno.format(rerr, "read")
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

  while not p:is_empty() do
    local wait_ms: integer = nil
    if deadline_ms then
      local rem = deadline_ms - now_ms()
      if rem <= 0 then return true end
      -- poll wants an integer millisecond count; floor the remaining time
      -- (any sub-millisecond remainder is caught by the next deadline check).
      wait_ms = math.floor(rem)
    end
    local ready, perr = p:wait(wait_ms)
    -- The POSITIVE branch is what narrows `ready` past nil (a `== nil`
    -- guard before a `break` does not survive the loop's flow join).
    if ready ~= nil then
      if next(ready) == nil then
        -- wait timed out with nothing ready: the deadline expired.
        return true
      end
      if state.stdin_fd then
        local ev = ready[state.stdin_fd]
        if ev and ev.writable then
          local slice = state.stdin_data:sub(state.stdin_off + 1, state.stdin_off + CHUNK)
          local n, werr, weno = unix.write(state.stdin_fd, slice)
          if n ~= nil then
            state.stdin_off = state.stdin_off + (n)
            if state.stdin_off >= #state.stdin_data then
              p:remove(state.stdin_fd); unix.close(state.stdin_fd); state.stdin_fd = nil
            end
          elseif errno.is_code(weno, "EAGAIN") or errno.is_code(weno, "EINTR") then
            -- Not actually writable yet (EAGAIN), or a signal interrupted the
            -- write EINTR: try again on the next poll.
          elseif errno.is_code(weno, "EPIPE") then
            -- The child stopped reading stdin; stop feeding it (not an error).
            p:remove(state.stdin_fd); unix.close(state.stdin_fd); state.stdin_fd = nil
          else
            state.io_err = state.io_err or errno.format(werr, "write stdin")
            p:remove(state.stdin_fd); unix.close(state.stdin_fd); state.stdin_fd = nil
          end
        elseif ev and (ev.error or ev.hangup or ev.invalid) then
          p:remove(state.stdin_fd); unix.close(state.stdin_fd); state.stdin_fd = nil
        end
      end
      if state.stdout_fd then read_ready(ready, state.stdout_fd, state.out, "out") end
      if state.stderr_fd then read_ready(ready, state.stderr_fd, state.err_out, "err") end
    else
      state.io_err = state.io_err or perr
      break
    end
  end

  return false
end

--- Read from `target`/`alt` (whichever `is_fd` selects) unless it names a
--- DIFFERENT std fd (0/1/2) than `own` -- a fork child wiring 0/1/2 in
--- fixed order can otherwise dup2 over a std fd BEFORE a later stream
--- reads it as its own source (a full stdout<->stderr swap, say), which
--- silently misroutes that stream. In that case dup the untouched
--- original to a CLOEXEC copy first, so the result stays readable no
--- matter what order the caller then wires 0/1/2 in.
--- @param is_fd boolean whether `target` (not `alt`) is the source
--- @param target integer caller-supplied fd, used when is_fd
--- @param alt integer this stream's own pipe fd, used when not is_fd
--- @param own integer the std fd (0, 1, or 2) this stream will wire onto
--- @return integer a source fd safe to dup2 from regardless of wiring order
local function pin_source(is_fd: boolean, target: integer, alt: integer,
    own: integer): integer
  local src = is_fd and target or alt
  if src >= 0 and src <= 2 and src ~= own then
    local copy = unix.dup(src, nil, unix.O_CLOEXEC, 10)
    if copy then return copy end
  end
  return src
end

local record ChildIoModule
  type StdioMode = StdioMode
  type PumpState = PumpState
  type Stdio = Stdio
  pump: function(state: PumpState, deadline_ms: number): boolean
  now_ms: function(): integer
  read_retry: function(fd: integer, bufsiz: integer): string | nil, string | nil
  wait_retry: function(pid: integer): integer | nil, integer
  resolve_stdio: function(stdin?: string | cfd.Handle,
  stdout?: cfd.Handle | StdioMode,
  stderr?: cfd.Handle | StdioMode): Stdio | nil, string
  pin_source: function(is_fd: boolean, target: integer, alt: integer,
  own: integer): integer
end

local M: ChildIoModule = {
  pump = pump,
  now_ms = now_ms,
  read_retry = read_retry,
  wait_retry = wait_retry,
  resolve_stdio = resolve_stdio,
  pin_source = pin_source,
}

return M
