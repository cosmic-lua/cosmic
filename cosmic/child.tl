--- Bounded child-process supervision with explicit argv, environment,
--- directory and descriptors.
---
--- A child owns a new process group by default, and its Handle owns
--- that group: once a wait, a timeout, or a close has an answer, no
--- process of the group is left. Anything still running when the
--- child exits is sent SIGTERM, then SIGKILL, and on Linux this
--- process becomes a child subreaper the first time it starts a
--- group, so a descendant orphaned by the child's exit is reparented
--- here and reaped here too, even on a host whose PID 1 never reaps.
--- A descendant that leaves the group (`setsid`) leaves supervision
--- with it. Start a child with `process_group = false` for one meant
--- to outlive the call that started it.
---
--- Standard streams are inherited unless redirected: to a caller-owned
--- descriptor, to "null", or to "capture", which collects the stream in
--- memory -- the last `capture_limit` bytes of it -- into the Result.
--- `input` feeds bytes to stdin. Every captured stream and the input
--- are serviced by one `poll` loop while waiting, so neither side can
--- stall the other on a full pipe, and several handles can be waited on
--- together with `Child.wait_any`. Completion is the child's exit, never
--- end of file: a descendant that escaped the group and still holds a
--- captured pipe cannot hold up a wait.
local sys = require("cosmic.sys")
local Time = require("cosmic.time")

local record Result
  code: integer | nil
  signal: integer | nil
  ok: boolean
  timed_out: boolean
  --- Captured stdout, when stdout was "capture".
  stdout: string | nil
  --- Captured stderr, when stderr was "capture".
  stderr: string | nil
  --- Every captured stream by the child's descriptor number, stdout and
  --- stderr included.
  captured: {integer:string}
  --- Whether any captured stream lost its beginning to `capture_limit`.
  truncated: boolean
end

local record Options
  env: {string:string}
  cwd: string
  --- A descriptor, "inherit" (the default), "null", or "pipe". With
  --- "pipe" the handle's `stdin` is the writable end, the caller's to
  --- write and to close with `close_stdin`.
  stdin: integer | string
  --- Bytes fed to the child's stdin, which is then closed. Excludes a
  --- `stdin` other than "pipe".
  input: string
  --- A descriptor, "inherit" (the default), "null", or "capture".
  stdout: integer | string
  --- A descriptor, "inherit" (the default), "null", "capture", or
  --- "stdout", which shares stdout's destination, capture included.
  stderr: integer | string
  --- More descriptors the child gets, by the number it sees them as
  --- (3 to 255): a descriptor of this process, or "capture". Every other
  --- descriptor above 2 is closed in the child.
  fds: {integer:integer | string}
  --- How many bytes of each captured stream are kept, the newest ones;
  --- 16 MiB by default.
  capture_limit: integer
  process_group: boolean
  timeout_ms: integer
end

local record TryWait
  finished: boolean
  result: Result
end

--- One captured stream of one child.
local record Stream
  fd: integer
  child_fd: integer
  chunks: {string}
  size: integer
  truncated: boolean
end

local record Handle
  metamethod __close: function(Handle)
  pid: integer
  process_group: boolean
  --- The writable end of the child's stdin when `stdin` was "pipe", until
  --- `close_stdin`.
  stdin: integer | nil
  _result: Result
  _status: sys.ChildStatus
  _closed: boolean
  _guarded: boolean
  --- The signal a guarded run was asked to stop by, once a wait saw it.
  _cancelled: integer | nil
  _streams: {Stream}
  _input_fd: integer | nil
  _input: string
  _input_at: integer
  _limit: integer
  wait: function(Handle, timeout_ms?: integer): Result | nil, string
  try_wait: function(Handle): TryWait | nil, string
  stop: function(Handle, signal?: integer): boolean, string
  close_stdin: function(Handle): boolean, string
  close: function(Handle): boolean, string
end

local POLL_MS <const> = 10
local POLL_NS <const> = POLL_MS * 1000 * 1000
local TERM_GRACE_NS <const> = 250 * 1000 * 1000
local KILL_REAP_NS <const> = 1000 * 1000 * 1000
local INT_MAX <const> = 2147483647
local CHUNK <const> = 65536
local DEFAULT_CAPTURE_LIMIT <const> = 16 * 1024 * 1024

--- Every pid a handle owns until the handle has settled it. Pids, not
--- handles, so a dropped handle still reaches its finalizer.
local owned: {integer:boolean} = {}

--- Exit statuses an adopting process collected for an owned pid before
--- its handle asked; the handle takes its own out.
local reaped: {integer:sys.ChildStatus} = {}

--- Whether this process adopts orphaned descendants: nil until the
--- first grouped start asks.
local adopting: boolean

local function now(): integer
  return Time.monotonic_ns()
end

local function target(self: Handle): integer
  return self.process_group and -self.pid or self.pid
end

--- In an adopting process, reaps every child that has exited: an owned
--- pid's status is filed for its handle, and an adopted orphan is simply
--- gone. A process that does not adopt reaps only by pid, handle by
--- handle, and never touches a child it does not own.
local function collect()
  if not adopting then return end
  while true do
    local status, _ = sys.waitpid(-1, true)
    if status == nil or status.pid == 0 then return end
    if owned[status.pid] then reaped[status.pid] = status end
  end
end

--- Files a status with its handle.
local function claim(self: Handle, status: sys.ChildStatus): sys.ChildStatus
  self._status = status
  reaped[self.pid] = nil
  owned[self.pid] = nil
  return status
end

--- This handle's child's exit status, once it has one. With `block`,
--- waits for it.
local function exited(self: Handle, block?: boolean): sys.ChildStatus | nil, string
  if self._status then return self._status, "" end
  collect()
  if reaped[self.pid] then return claim(self, reaped[self.pid]), "" end
  local status, trouble = sys.waitpid(self.pid, not block)
  if not status then return nil, trouble end
  if status.pid == 0 then return nil, "" end
  return claim(self, status), ""
end

local function close_fd(fd: integer)
  if fd ~= nil then local _, _ = sys.close(fd) end
end

--- Appends one chunk to a stream, dropping its oldest bytes past the
--- limit. Chunks are joined only when the kept size doubles, so a long
--- stream costs amortized linear time.
local function keep(self: Handle, stream: Stream, data: string)
  stream.chunks[#stream.chunks + 1] = data
  stream.size = stream.size + #data
  if stream.size > 2 * self._limit then
    local whole = table.concat(stream.chunks)
    stream.chunks = { whole:sub(-self._limit) }
    stream.size = self._limit
    stream.truncated = true
  end
end

local function text_of(self: Handle, stream: Stream): string
  local whole = table.concat(stream.chunks)
  if #whole > self._limit then
    stream.truncated = true
    return whole:sub(-self._limit)
  end
  return whole
end

local function end_stream(self: Handle, index: integer)
  local stream = self._streams[index]
  if stream.fd ~= nil then
    local _, _ = sys.close(stream.fd)
    stream.fd = nil
  end
end

local function end_input(self: Handle)
  close_fd(self._input_fd)
  self._input_fd = nil
end

--- Services every open stream and pending input of `handles` once:
--- waits up to `timeout_ms` for any of them to be ready, then reads
--- what is there and writes what fits. Returns whether anything moved.
local function pump(handles: {Handle}, timeout_ms: integer): boolean
  local fds: {integer} = {}
  local events: {integer} = {}
  local owners: {Handle} = {}
  local which: {integer} = {}
  for _, h in ipairs(handles) do
    if h._streams then
      for index, stream in ipairs(h._streams) do
        if stream.fd ~= nil then
          fds[#fds + 1] = stream.fd
          events[#events + 1] = sys.POLLIN
          owners[#owners + 1] = h
          which[#which + 1] = index
        end
      end
    end
    if h._input_fd ~= nil then
      fds[#fds + 1] = h._input_fd
      events[#events + 1] = sys.POLLOUT
      owners[#owners + 1] = h
      which[#which + 1] = 0
    end
  end
  if #fds == 0 then
    if timeout_ms > 0 then local _, _ = sys.nanosleep(timeout_ms * 1000 * 1000) end
    return false
  end
  local revents, _ = sys.poll(fds, events, timeout_ms)
  if revents == nil then
    -- A descriptor that went bad under us cannot be serviced; close
    -- every stream rather than spin on it.
    for i = 1, #fds do
      if which[i] == 0 then end_input(owners[i]) else end_stream(owners[i], which[i]) end
    end
    return true
  end
  local moved = false
  for i, happened in ipairs(revents) do
    if happened ~= 0 then
      moved = true
      local h = owners[i]
      if which[i] == 0 then
        local offset = h._input_at
        local written, _, errno = sys.write(h._input_fd,
          h._input:sub(offset + 1, offset + CHUNK))
        if written ~= nil then
          h._input_at = offset + written
          if h._input_at >= #h._input then end_input(h) end
        elseif errno ~= sys.EAGAIN and errno ~= sys.EINTR then
          -- EPIPE included: a child that stopped reading has said so.
          end_input(h)
        end
      else
        local stream = h._streams[which[i]]
        local data, _, errno = sys.read(stream.fd, CHUNK)
        if data == nil then
          if errno ~= sys.EAGAIN and errno ~= sys.EINTR then end_stream(h, which[i]) end
        elseif data == "" then
          end_stream(h, which[i])
        else
          keep(h, stream, data)
        end
      end
    end
  end
  return moved
end

--- Waits for a group to have no members left, collecting whatever this
--- process adopted from it meanwhile. False when it did not empty.
local function group_gone(self: Handle, until_ns: integer): boolean
  while true do
    local alive, _, errno = sys.kill(-self.pid, 0)
    if not alive and errno == sys.ESRCH then return true end
    if now() >= until_ns then return false end
    collect()
    pump({ self }, POLL_MS)
  end
end

--- Ends whatever is left of the group once its leader is gone: SIGTERM,
--- a grace period, then SIGKILL, until the group is empty.
local function clear_group(self: Handle, already_killed: boolean): boolean
  if not self.process_group then return true end
  if not already_killed then
    local alive, _, errno = sys.kill(-self.pid, 0)
    if not alive and errno == sys.ESRCH then return true end
    local _, _ = sys.kill(-self.pid, sys.SIGTERM)
    if group_gone(self, now() + TERM_GRACE_NS) then return true end
  end
  local _, _ = sys.kill(-self.pid, sys.SIGKILL)
  return group_gone(self, now() + KILL_REAP_NS)
end

--- Turns a reaped handle into its Result: the group is cleared, what
--- is still readable is drained, and every descriptor is closed.
local function settle(self: Handle, timed_out: boolean, killed?: boolean): Result, string
  local status = self._status
  local r: Result = {
    ok = status.code == 0 and not timed_out,
    timed_out = timed_out,
    captured = {},
    truncated = false,
  }
  if status.code >= 0 then r.code = status.code end
  if status.signal >= 0 then r.signal = status.signal end
  local cleared = clear_group(self, killed or false)
  end_input(self)
  close_fd(self.stdin)
  self.stdin = nil
  if self._streams then
    -- Anything still buffered in a pipe is there for the taking now;
    -- a writer that escaped the group can keep it open, so stop at the
    -- first round that finds nothing rather than wait for end of file.
    while pump({ self }, 0) do end
    for index, stream in ipairs(self._streams) do
      end_stream(self, index)
      local text = text_of(self, stream)
      r.captured[stream.child_fd] = text
      if stream.truncated then r.truncated = true end
    end
    r.stdout = r.captured[1]
    r.stderr = r.captured[2]
  end
  self._result, self._closed = r, true
  if not cleared then
    return r, "process group " .. tostring(self.pid) .. " still has members after SIGKILL"
  end
  return r, ""
end

--- `settle`, as a wait answers it: a group that would not empty is a
--- failure, though the Result is kept for a later wait to return.
local function settled(self: Handle, timed_out: boolean, killed?: boolean): Result | nil, string
  local r, trouble = settle(self, timed_out, killed)
  if trouble ~= "" then return nil, trouble end
  return r, ""
end

--- Waits for the child to exit until `deadline`, servicing its streams,
--- and settles it when it does. Nil and "" at the deadline: no answer
--- yet, and no failure. When a guarded run is asked to stop, keeps the
--- signal in `_cancelled` and fails.
local function poll_until(self: Handle, deadline?: integer,
    timed_out?: boolean, ignore_cancel?: boolean, killed?: boolean): Result | nil, string
  while true do
    if not ignore_cancel then
      local cancelled, cancel_trouble = sys.cancelled_child_signal()
      if cancelled == nil then return nil, cancel_trouble end
      if cancelled ~= 0 then
        self._cancelled = cancelled
        return nil, "cancelled by signal " .. tostring(cancelled)
      end
    end
    local status, trouble = exited(self)
    if status ~= nil then return settled(self, timed_out or false, killed) end
    if trouble ~= "" then return nil, trouble end
    local left = POLL_MS
    if deadline then
      local remaining = deadline - now()
      if remaining <= 0 then return nil, "" end
      left = math.max(0, math.min(POLL_MS, remaining // (1000 * 1000)))
    end
    pump({ self }, left)
  end
end

local function terminate(self: Handle): Result | nil, string
  local ok, trouble = sys.kill(target(self), sys.SIGTERM)
  if not ok then
    -- The child may have exited between the last poll and this signal.
    local status, _ = exited(self)
    if status ~= nil then return settled(self, true) end
    return nil, trouble
  end
  local deadline = now() + TERM_GRACE_NS
  while now() < deadline do
    local status, _ = exited(self)
    if status ~= nil then return settled(self, true) end
    pump({ self }, POLL_MS)
  end
  -- Even when the direct child honored TERM, a descendant may have ignored
  -- it. The process group remains addressable until its final member exits.
  -- A group already gone refuses the signal; the reap below answers.
  local _, _ = sys.kill(target(self), sys.SIGKILL)
  local final, reap_trouble = poll_until(self, now() + KILL_REAP_NS, true, true, true)
  if final == nil then
    if reap_trouble == "" then return nil, "child did not reap after SIGKILL" end
    return nil, reap_trouble
  end
  return final, ""
end

local function emergency_cleanup(self: Handle)
  local _, _ = sys.kill(target(self), sys.SIGKILL)
  for _ = 1, 100 do
    local status, _ = exited(self)
    if status ~= nil then
      settle(self, true, true)
      return
    end
    local _, _ = sys.nanosleep(POLL_NS)
  end
end

local handle_mt: metatable<Handle> = {
  __close = function(self: Handle)
    if not self._closed then local _, _ = terminate(self) end
  end,
  __gc = function(self: Handle)
    if not self._closed then local _, _ = terminate(self) end
  end,
}

local function make_handle(pid: integer, process_group: boolean): Handle
  local h: Handle = { pid = pid, process_group = process_group }

  function h:try_wait(): TryWait | nil, string
    if self._result then return { finished = true, result = self._result }, "" end
    pump({ self }, 0)
    local status, trouble = exited(self)
    if status == nil then
      if trouble ~= "" then return nil, trouble end
      return { finished = false }, ""
    end
    local r, settle_trouble = settled(self, false)
    if r == nil then return nil, settle_trouble end
    return { finished = true, result = r }, ""
  end

  function h:stop(signal?: integer): boolean, string
    if self._closed then return false, "process already reaped" end
    local ok, trouble = sys.kill(target(self), signal or sys.SIGTERM)
    if not ok then return false, trouble end
    return true, ""
  end

  function h:close_stdin(): boolean, string
    if self.stdin == nil then return false, "stdin is not a pipe, or already closed" end
    local ok, trouble = sys.close(self.stdin)
    self.stdin = nil
    if not ok then return false, trouble end
    return true, ""
  end

  function h:wait(timeout_ms?: integer): Result | nil, string
    if self._result then return self._result, "" end
    if timeout_ms == nil and not self._guarded and not self._streams and
        not self._input_fd then
      local status, trouble = exited(self, true)
      if not status then return nil, trouble end
      return settled(self, false)
    end
    if timeout_ms == nil then return poll_until(self) end
    if timeout_ms < 0 then return nil, "timeout is negative" end
    local r, trouble = poll_until(self, now() + timeout_ms * 1000000)
    if r then return r, "" end
    if trouble ~= "" then return nil, trouble end
    return terminate(self)
  end

  function h:close(): boolean, string
    if self._closed then return true, "" end
    local r, trouble = terminate(self)
    if not r then return false, trouble end
    return true, ""
  end

  owned[pid] = true
  return setmetatable(h, handle_mt)
end

local record Child
  type Result = Result
  type Options = Options
  type TryWait = TryWait
  type Handle = Handle
end

local function descriptor(value: integer | string, name: string, words: {string:boolean}):
    integer | string
  if value == nil then return "inherit" end
  if value is string and words[value] then return value end
  if value is integer and value >= 0 and value <= INT_MAX then return value end
  local allowed: {string} = {}
  for word in pairs(words) do allowed[#allowed + 1] = "'" .. word .. "'" end
  table.sort(allowed)
  error(name .. " must be a file descriptor or one of " .. table.concat(allowed, ", "), 3)
end

local STDIN_WORDS <const> = { inherit = true, null = true, pipe = true }
local STDOUT_WORDS <const> = { inherit = true, null = true, capture = true }
local STDERR_WORDS <const> = { inherit = true, null = true, capture = true, stdout = true }
local FD_WORDS <const> = { capture = true }

local function without_nul(value: string, name: string)
  if value:find("\0", 1, true) then error(name .. " contains a NUL byte", 3) end
end

local function validate(argv: {string}, opts: Options): boolean
  if #argv == 0 then error("argv is empty", 3) end
  for i, value in ipairs(argv) do
    if type(value) ~= "string" then error("argv[" .. tostring(i) .. "] must be a string", 3) end
    without_nul(value, "argv[" .. tostring(i) .. "]")
  end
  if opts.cwd ~= nil then without_nul(opts.cwd, "cwd") end
  if opts.env ~= nil then
    for name, value in pairs(opts.env) do
      if type(name) ~= "string" or name == "" or name:find("=", 1, true) then
        error("environment name is empty, non-string, or contains '='", 3)
      end
      if type(value) ~= "string" then error("environment value must be a string", 3) end
      without_nul(name, "environment name")
      without_nul(value, "environment value")
    end
  end
  local stdin = descriptor(opts.stdin, "stdin", STDIN_WORDS)
  descriptor(opts.stdout, "stdout", STDOUT_WORDS)
  descriptor(opts.stderr, "stderr", STDERR_WORDS)
  if opts.input ~= nil then
    if type(opts.input) ~= "string" then error("input must be a string", 3) end
    if stdin ~= "inherit" and stdin ~= "pipe" then
      error("input and a stdin other than 'pipe' exclude each other", 3)
    end
  end
  if opts.fds ~= nil then
    for number, value in pairs(opts.fds) do
      if not (number is integer) or number < 3 or number > 255 then
        error("fds keys are child descriptors from 3 to 255", 3)
      end
      descriptor(value, "fds[" .. tostring(number) .. "]", FD_WORDS)
    end
  end
  if opts.capture_limit ~= nil and (opts.capture_limit < 1 or opts.capture_limit > INT_MAX) then
    error("capture_limit is out of range", 3)
  end
  if opts.timeout_ms ~= nil and (opts.timeout_ms < 0 or opts.timeout_ms > INT_MAX) then
    error("timeout is out of range", 3)
  end
  return true
end

--- Descriptors this process opened for one start, closed together
--- whatever happens: the child's ends always, ours only on failure.
local record Wiring
  child_ends: {integer}
  ours: {integer}
  streams: {Stream}
  input_fd: integer | nil
  stdin_fd: integer | nil
end

local function unwire(wiring: Wiring, keep_ours: boolean)
  for _, fd in ipairs(wiring.child_ends) do local _, _ = sys.close(fd) end
  if not keep_ours then
    for _, fd in ipairs(wiring.ours) do local _, _ = sys.close(fd) end
  end
end

--- A pipe whose read end is ours and whose write end the child gets
--- as `child_fd`; the stream records it.
local function capture(wiring: Wiring, child_fd: integer): integer | nil, string
  local ends, trouble = sys.pipe()
  if ends == nil then return nil, trouble end
  wiring.child_ends[#wiring.child_ends + 1] = ends.writer
  wiring.ours[#wiring.ours + 1] = ends.reader
  local nonblocking, nonblocking_trouble = sys.set_nonblocking(ends.reader, true)
  if not nonblocking then return nil, nonblocking_trouble end
  wiring.streams[#wiring.streams + 1] = {
    fd = ends.reader, child_fd = child_fd, chunks = {}, size = 0, truncated = false,
  }
  return ends.writer, ""
end

local function null(wiring: Wiring, flags: integer): integer | nil, string
  local fd, trouble = sys.open("/dev/null", flags)
  if fd == nil then return nil, trouble end
  wiring.child_ends[#wiring.child_ends + 1] = fd
  return fd, ""
end

--- Resolves the options into the descriptor each child slot copies:
--- nil to inherit, or a descriptor number.
local function wire(opts: Options, wiring: Wiring): {integer:integer} | nil, string
  local slots: {integer:integer} = {}
  local stdin = descriptor(opts.stdin, "stdin", STDIN_WORDS)
  if opts.input ~= nil or stdin == "pipe" then
    local ends, trouble = sys.pipe()
    if ends == nil then return nil, trouble end
    wiring.child_ends[#wiring.child_ends + 1] = ends.reader
    wiring.ours[#wiring.ours + 1] = ends.writer
    slots[0] = ends.reader
    if opts.input ~= nil then
      local ignored, ignore_trouble = sys.ignore_sigpipe()
      if not ignored then return nil, ignore_trouble end
      local nonblocking, nonblocking_trouble = sys.set_nonblocking(ends.writer, true)
      if not nonblocking then return nil, nonblocking_trouble end
      wiring.input_fd = ends.writer
    else
      wiring.stdin_fd = ends.writer
    end
  elseif stdin == "null" then
    local fd, trouble = null(wiring, sys.O_RDONLY)
    if fd == nil then return nil, trouble end
    slots[0] = fd
  elseif stdin is integer then
    slots[0] = stdin
  end
  local stdout = descriptor(opts.stdout, "stdout", STDOUT_WORDS)
  if stdout == "capture" then
    local fd, trouble = capture(wiring, 1)
    if fd == nil then return nil, trouble end
    slots[1] = fd
  elseif stdout == "null" then
    local fd, trouble = null(wiring, sys.O_WRONLY)
    if fd == nil then return nil, trouble end
    slots[1] = fd
  elseif stdout is integer then
    slots[1] = stdout
  end
  local stderr = descriptor(opts.stderr, "stderr", STDERR_WORDS)
  if stderr == "stdout" then
    slots[2] = slots[1] or 1
  elseif stderr == "capture" then
    local fd, trouble = capture(wiring, 2)
    if fd == nil then return nil, trouble end
    slots[2] = fd
  elseif stderr == "null" then
    local fd, trouble = null(wiring, sys.O_WRONLY)
    if fd == nil then return nil, trouble end
    slots[2] = fd
  elseif stderr is integer then
    slots[2] = stderr
  end
  if opts.fds ~= nil then
    local numbers: {integer} = {}
    for number in pairs(opts.fds) do numbers[#numbers + 1] = number end
    table.sort(numbers)
    for _, number in ipairs(numbers) do
      local value = opts.fds[number]
      if value == "capture" then
        local fd, trouble = capture(wiring, number)
        if fd == nil then return nil, trouble end
        slots[number] = fd
      else
        slots[number] = value as integer
      end
    end
  end
  return slots, ""
end

--- Starts one executable and returns an owning handle. argv[1] is an exact
--- path, without PATH lookup. Drop/close of an unfinished handle performs
--- bounded process-group termination; wait(timeout) does the same on expiry.
function Child.start(argv: {string}, opts?: Options): Handle | nil, string
  opts = opts or {}
  validate(argv, opts)
  local grouped = opts.process_group
  if grouped == nil then grouped = true end
  if grouped and adopting == nil then
    local subreaper, _ = sys.subreaper()
    adopting = subreaper
  end
  local wiring: Wiring = { child_ends = {}, ours = {}, streams = {} }
  local slots, wire_trouble = wire(opts, wiring)
  if slots == nil then
    unwire(wiring, false)
    return nil, "start: " .. wire_trouble
  end
  local extra: {integer:integer}
  for number, fd in pairs(slots) do
    if number > 2 then
      extra = extra or {}
      extra[number] = fd
    end
  end
  local pid, trouble = sys.spawn(argv[1], argv, opts.env, opts.cwd,
    slots[0], slots[1], slots[2], grouped, extra)
  unwire(wiring, pid ~= nil)
  if not pid then return nil, "start: " .. trouble end
  local h = make_handle(pid, grouped)
  h._limit = opts.capture_limit or DEFAULT_CAPTURE_LIMIT
  if #wiring.streams > 0 then h._streams = wiring.streams end
  if wiring.input_fd ~= nil then
    h._input_fd, h._input, h._input_at = wiring.input_fd, opts.input, 0
    if #opts.input == 0 then end_input(h) end
  end
  h.stdin = wiring.stdin_fd
  return h, ""
end

--- Waits for the first of several handles to finish, servicing every
--- one's streams meanwhile, and returns it settled: its `wait()` answers
--- at once. Nil and "" when `timeout_ms` passes first -- no handle
--- finished, and nothing failed -- and the handles are left running.
-- TODO: carry a settled group's lingering members on Child.Result, a
-- field beside the exit status, and answer the handle with "" here:
-- build/test.tl reads the trouble beside the handle's result today, and
-- build.contracts exempts this pair from the error-slot rules until then.
function Child.wait_any(handles: {Handle}, timeout_ms?: integer): Handle | nil, string
  if #handles == 0 then error("no handles to wait for", 2) end
  if timeout_ms ~= nil and timeout_ms < 0 then return nil, "timeout is negative" end
  local deadline = timeout_ms ~= nil and now() + timeout_ms * 1000000 or nil
  while true do
    for _, h in ipairs(handles) do
      if h._result then return h, "" end
      local status, trouble = exited(h)
      if status ~= nil then
        local _, settle_trouble = settle(h, false)
        return h, settle_trouble
      end
      if trouble ~= "" then return nil, trouble end
    end
    local left = POLL_MS
    if deadline then
      local remaining = deadline - now()
      if remaining <= 0 then return nil, "" end
      left = math.max(0, math.min(POLL_MS, remaining // (1000 * 1000)))
    end
    pump(handles, left)
  end
end

--- The children of this process that no handle owns, from Linux's
--- per-thread `children` list; nil where there is no such list.
local function strays(): {integer} | nil
  local path = "/proc/self/task/" .. tostring(sys.getpid()) .. "/children"
  local fd, _ = sys.open(path, sys.O_RDONLY)
  if fd == nil then return nil end
  local parts: {string} = {}
  while true do
    local data, _ = sys.read(fd, CHUNK)
    if data == nil or data == "" then break end
    parts[#parts + 1] = data
  end
  local _, _ = sys.close(fd)
  local found: {integer} = {}
  for number in table.concat(parts):gmatch("%d+") do
    local pid = math.tointeger(tonumber(number))
    if pid ~= nil and not owned[pid] then found[#found + 1] = pid end
  end
  return found
end

--- Ends and reaps every child of this process that no handle owns:
--- what a supervised child left behind when it died without ending
--- its own descendants -- a process group it started, say, which its
--- own group's SIGKILL never reached -- and that this process adopted
--- as their subreaper. Each is sent SIGKILL, with its group when it
--- leads one, until none is left or a second has passed. Returns how
--- many were ended. Only a Linux process that adopts orphans can find
--- them; elsewhere this returns 0 and they are init's.
function Child.end_strays(): integer
  if not adopting then return 0 end
  local ended = 0
  local seen: {integer:boolean} = {}
  local deadline = now() + KILL_REAP_NS
  while true do
    collect()
    local found = strays()
    if found == nil or #found == 0 or now() >= deadline then return ended end
    for _, pid in ipairs(found) do
      local _, _ = sys.kill(-pid, sys.SIGKILL)
      local _, _ = sys.kill(pid, sys.SIGKILL)
      if not seen[pid] then
        seen[pid] = true
        ended = ended + 1
      end
    end
    local _, _ = sys.nanosleep(POLL_NS // 10)
  end
end

--- Runs one executable path to completion. argv[1] is used exactly as given:
--- there is no PATH search. A nil environment inherits this process's
--- environment; a table replaces it exactly. Standard streams inherit by
--- default, or accept caller-owned descriptors (which remain open here),
--- "null", or "capture". Children own a new process group by default so
--- timeout cleanup includes descendants. start returns that ownership as a
--- Handle; run additionally forwards SIGINT/SIGTERM, performs bounded group
--- cleanup, restores the caller's dispositions, and then re-delivers
--- cancellation.
function Child.run(argv: {string}, opts?: Options): Result | nil, string
  opts = opts or {}
  validate(argv, opts)
  local guarded, guard_trouble = sys.guard_child_signals()
  if not guarded then return nil, "signal guard: " .. guard_trouble end
  local h: Handle
  local function supervised(): Result | nil, string
    local started, trouble = Child.start(argv, opts)
    if not started then return nil, trouble end
    h = started
    h._guarded = true
    return h:wait(opts.timeout_ms)
  end
  local called, r, wait_trouble = pcall(supervised)
  local cancellation: integer
  if called and h then cancellation = h._cancelled end
  local cleanup_trouble: string
  if h and not h._closed and (not called or cancellation or not r) then
    local cleaned, answer, failure = pcall(terminate, h)
    if not cleaned then
      cleanup_trouble = tostring(answer)
      emergency_cleanup(h)
    elseif failure ~= "" then
      cleanup_trouble = failure
    end
  end
  local late_signal, restore_trouble = sys.unguard_child_signals()
  if late_signal == nil then
    if not called then error(r, 0) end
    return nil, "signal restore: " .. restore_trouble
  end
  cancellation = cancellation or (late_signal ~= 0 and late_signal or nil)
  if cancellation then
    -- Re-deliver after cleanup with the caller's original disposition.
    local _, _ = sys.kill(sys.getpid(), cancellation)
    return nil, cleanup_trouble or wait_trouble or "cancelled"
  end
  if not called then error(r, 0) end
  if cleanup_trouble then return nil, cleanup_trouble end
  if r then return r, "" end
  return nil, wait_trouble
end

return Child
