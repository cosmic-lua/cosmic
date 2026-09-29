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
--- to outlive the call that started it. A child started with a
--- `sandbox` that unveils, or one the test runner confines, starts a
--- session, and so a group, of its own whatever `process_group` says, in
--- a pid namespace of its own that ends when it does: nothing it starts
--- outlives it there.
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
---
--- A stream redirected to "stream" is the caller's to read or write
--- while the child runs, through the handle's `stdout_stream`,
--- `stderr_stream` (each a `cosmic.stream` Reader) or `stdin_stream` (a
--- Writer). While one of them waits, it services the child's other
--- streams too, so reading stdout cannot stall on a child blocked
--- writing a full stderr, nor writing stdin on one blocked writing a
--- full stdout: what arrives on a streamed output meanwhile waits in
--- memory, up to `capture_limit` unread bytes of each, after which the
--- child is left to wait until the caller reads. Nothing streamed is
--- dropped, and nothing is kept for the Result.
local sys = require("cosmic.sys")
local Stream = require("cosmic.stream")
local Time = require("cosmic.time")

-- The calls that start, feed and reap a child, and hold this process's
-- signals while it does, live in the raw process table, under the
-- reserved `cosmic.internal.` namespace -- see cosmic/store.tl for
-- why this indirection exists. It is off the public surface so that
-- nothing but a handle reaps a child a handle owns: in an adopting
-- process `collect` reaps every child with `waitpid(-1)`, and a
-- public one would take a status from under it.
local type raw_process = require("cosmic.internal.process")

local handed: any = select(2, ...)
local raw: raw_process
if type(handed) == "table" then
  raw = handed as raw_process
else
  raw = require("cosmic.internal.process")
end

local record Result
  --- The child's exit status, or nil when a signal ended it.
  code: integer | nil
  --- The number of the signal that ended the child, or nil when it
  --- exited by itself.
  signal: integer | nil
  --- Whether the child exited with status 0 and was not ended for
  --- running past its timeout.
  ok: boolean
  --- Whether the child ran past the timeout (`Child.run`'s
  --- `timeout_ms`, or `Handle.wait`'s) and was ended for it.
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

--- The paths a sandbox gives a child (`Sandbox.unveil`), each
--- absolute; at most 256 in all.
local record Unveil
  --- The files and directories the child has, read-only.
  reads: {string}
  --- The ones it has to change too.
  writes: {string}
  --- For a path of `reads` or `writes`, by that path as given, the
  --- absolute name it is bound at in the child's root instead of its
  --- own: not /, and no link to it is made there. Nil for none.
  at: {string:string}
end

--- What a child, and every process it starts, is held to from its exec
--- on: Linux, where unprivileged user namespaces are allowed. Elsewhere,
--- or where the kernel refuses one, the start fails, with no fallback.
local record Sandbox
  --- What alone of the filesystem the child has: a root of its own
  --- holding these paths, each at the name it resolves to or the one
  --- `at` gives it, a /proc of its own pid namespace where /proc is
  --- given and the kernel allows one, and a /tmp of its own unless one
  --- is given -- and nothing else. The child is pid 2 of a pid namespace
  --- of its own, whose init ends when it does, ending whatever it left
  --- running there; and it leads a session, and so a process group, of
  --- its own whatever `process_group` says.
  unveil: Unveil
  --- A network namespace of its own, with nothing but a loopback.
  offline: boolean
end

local record Options
  --- The child's whole environment, by name: it replaces this process's
  --- rather than adding to it. Nil inherits this process's.
  env: {string:string}
  --- The directory the child starts in. Nil inherits this process's.
  cwd: string
  --- A descriptor, "inherit" (the default), "null", or "pipe". With
  --- "pipe" the handle's `stdin` is the writable end, the caller's to
  --- write and to close with `close_stdin`. A pipe to stdin, this one
  --- or `input`'s, makes this process ignore SIGPIPE from then on, so a
  --- write to a child that has gone fails with EPIPE instead of ending
  --- it. With "stream" the handle's `stdin_stream` is a Writer to it,
  --- which ignores SIGPIPE the same way.
  stdin: integer | string
  --- Bytes fed to the child's stdin, which is then closed. Excludes a
  --- `stdin` other than "pipe".
  input: string
  --- A descriptor, "inherit" (the default), "null", "capture", or
  --- "stream", which the handle's `stdout_stream` reads.
  stdout: integer | string
  --- A descriptor, "inherit" (the default), "null", "capture", "stream"
  --- (read by the handle's `stderr_stream`), or "stdout", which shares
  --- stdout's destination, capture or stream included.
  stderr: integer | string
  --- More descriptors the child gets, by the number it sees them as
  --- (3 to 255): a descriptor of this process, or "capture". Every other
  --- descriptor above 2 is closed in the child.
  fds: {integer:integer | string}
  --- How many bytes of each captured stream are kept, the newest ones,
  --- and how many unread bytes of each streamed one are held before the
  --- child is left to wait for the caller to read; 16 MiB by default.
  capture_limit: integer
  --- Whether the child leads a new process group that its handle owns
  --- and ends with it; true by default. False for a child meant to
  --- outlive the call that started it.
  process_group: boolean
  --- How long `Child.run` lets the child run before ending it, as
  --- `Handle.wait` does with its own timeout. `Child.start` refuses it:
  --- a started child's time is the caller's to bound, by `h:wait(ms)`.
  timeout_ms: integer
  --- What the child is held to (see `Sandbox`); nil for nothing.
  sandbox: Sandbox
end

--- What `Handle.try_wait` answers.
local record TryWait
  --- Whether the child has exited.
  finished: boolean
  --- Its outcome, once `finished`.
  result: Result
end

--- One captured or streamed output of one child.
local record Pipe
  fd: integer
  child_fd: integer
  chunks: {string}
  size: integer
  truncated: boolean
  --- A stream the caller reads, not one kept for the Result: `chunks`
  --- is then a queue, read from `head` and written at `tail`, and
  --- `size` is how much of it is unread.
  streamed: boolean
  head: integer
  tail: integer
end

local record Handle
  metamethod __close: function(Handle)
  --- The child's process id.
  pid: integer
  --- Whether the child leads a process group of its own that this
  --- handle owns (`Options.process_group`).
  process_group: boolean
  --- The writable end of the child's stdin when `stdin` was "pipe", until
  --- `close_stdin`.
  stdin: integer | nil
  --- Readers of stdout and stderr, when each was "stream". Each reads
  --- until the child's end of the pipe closes, or until the child has
  --- exited and nothing more is waiting: a descendant that escaped the
  --- group still holding it cannot hold a read up. A wait leaves them
  --- to read on; `close` ends them once what is queued is read. While
  --- the open guard has caught a signal, a read or a write fails with
  --- "cancelled by signal N", as a wait does.
  stdout_stream: Stream.Reader | nil
  stderr_stream: Stream.Reader | nil
  --- A Writer to stdin, when it was "stream"; its `close` (or `abort`)
  --- closes the child's stdin. A write fails once the child has closed
  --- its stdin, or has exited and nothing else holds it, and after a
  --- wait. A write the child does not read waits for it, however long:
  --- a child that stops reading until its streamed stdout is read,
  --- which sits unread at `capture_limit`, waits forever -- read the
  --- outputs as the input goes in, or bound the child with a timeout.
  stdin_stream: Stream.Writer | nil
  _feed_fd: integer | nil
  _result: Result
  _status: raw_process.ChildStatus
  _closed: boolean
  _streams: {Pipe}
  _input_fd: integer | nil
  _input: string
  _input_at: integer
  _limit: integer
  --- Waits for the child to exit and answers its Result. With
  --- `timeout_ms`, a child still running when it passes is ended --
  --- SIGTERM, a grace period, then SIGKILL, its group included -- and
  --- the Result says `timed_out`; `Child.wait_any`'s timeout instead
  --- leaves every child running. While a `Child.guard` is open, a
  --- SIGINT or SIGTERM it catches ends the wait, timed or not, the same
  --- way: a child that has not exited is ended and the wait answers nil
  --- and "cancelled by signal N"; the guard keeps the signal, and a
  --- later wait answers the ended child's Result.
  wait: function(Handle, timeout_ms?: integer): Result | nil, string
  --- Whether the child has exited, without waiting: `finished` is false
  --- while it runs, and true with its `result` once it has exited and its
  --- group is cleared, as `wait` would answer. It services the child's
  --- captured and streamed outputs and input meanwhile. Nil and why when
  --- settling the child fails.
  try_wait: function(Handle): TryWait | nil, string
  --- Sends `signal` (SIGTERM by default) to the child, or to its whole
  --- group when `process_group` is true. It does not wait. False and why when the child
  --- has been reaped already or the signal cannot be sent.
  stop: function(Handle, signal?: integer): boolean, string
  --- Closes the writable end of the child's stdin, `Handle.stdin`, so the
  --- child reads end of file. False and why when `stdin` was not "pipe"
  --- or is closed already.
  close_stdin: function(Handle): boolean, string
  --- Ends the child if it is still running, as an expired `wait` does,
  --- reaps it and closes its stdin, and ends its streamed outputs so
  --- their readers read what is queued and stop. Closing a settled
  --- handle only ends the streamed outputs. False and why when the
  --- child or its group cannot be ended.
  close: function(Handle): boolean, string
end

-- TODO: a child's exit is seen only at the next poll, up to POLL_MS after
-- it happens: `Child.run` of /bin/true takes about 10 ms in all though its
-- spawn takes 0.2 ms. Wait on the exit itself -- a pidfd in the poll set
-- on Linux, kqueue's EVFILT_PROC on Darwin -- once core/process.h carries
-- pidfd_open and a kqueue binding.
local POLL_MS <const> = 10
local POLL_NS <const> = POLL_MS * 1000 * 1000
local TERM_GRACE_NS <const> = 250 * 1000 * 1000
local KILL_REAP_NS <const> = 1000 * 1000 * 1000
local INT_MAX <const> = 2147483647
local CHUNK <const> = 65536
local DEFAULT_CAPTURE_LIMIT <const> = 16 * 1024 * 1024

--- SIGINT and SIGTERM held for this process while children are
--- supervised; see `Child.guard`.
local record Guard
  metamethod __close: function(Guard)
  --- The signal delivered last, 0 until one is.
  _signal: integer
  --- The signal delivered last since the last take, 0 when none was.
  _fresh: integer
  _closed: boolean
  --- Why the dispositions could not be restored, "" when they were.
  _trouble: string
  --- The last SIGINT or SIGTERM caught, or 0 until one is. It is kept
  --- after the guard closes.
  cancelled: function(Guard): integer
  --- The last signal caught since the previous take, or 0, and clears
  --- it: the way to pass each signal on to a child.
  take: function(Guard): integer
  --- Restores the dispositions the process had and delivers the last
  --- signal caught again. False and why when they cannot be restored,
  --- and again on every later close.
  close: function(Guard): boolean, string
  --- Restores the dispositions but keeps the last signal caught instead
  --- of delivering it, and answers that signal, or 0. Nil and why when
  --- they cannot be restored.
  release: function(Guard): integer | nil, string
end

--- The open guard, if any: at most one is, process-wide.
local active: Guard | nil

-- TODO: use sys.EBUSY once cosmic.sys carries it; 16 is EBUSY on Linux
-- and macOS alike.
local EBUSY <const> = 16

--- Why no guard could be taken, from the core's `trouble` and `errno`
--- for it. The core answers EBUSY only while a guard is open, and this
--- names it; any other failure keeps the core's own words.
local function busy(trouble: string, errno: integer): string
  if errno == EBUSY then
    return "a guard (Child.guard or another Child.run) is already open (" ..
      trouble .. "): close it first"
  end
  return trouble
end

--- The message a wait or a run cancelled by `signal` answers.
local function cancelled_by(signal: integer): string
  return "cancelled by signal " .. tostring(signal)
end

--- Every pid a handle owns until the handle has settled it. Pids, not
--- handles, so a dropped handle still reaches its finalizer.
local owned: {integer:boolean} = {}

--- Exit statuses an adopting process collected for an owned pid before
--- its handle asked; the handle takes its own out.
local reaped: {integer:raw_process.ChildStatus} = {}

--- Whether this process adopts orphaned descendants: nil until the
--- first grouped start asks.
local adopting: boolean

local function now(): integer
  return Time.monotonic_ns()
end

--- How long the next poll may wait, in milliseconds: POLL_MS, or less
--- as `deadline` nears; nil once it has passed.
local function slice(deadline: integer): integer
  if deadline == nil then return POLL_MS end
  local remaining = deadline - now()
  if remaining <= 0 then return nil end
  return math.min(POLL_MS, remaining // (1000 * 1000))
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
    local status, _ = raw.waitpid(-1, true)
    if status == nil or status.pid == 0 then return end
    if owned[status.pid] then reaped[status.pid] = status end
  end
end

--- Files a status with its handle.
local function claim(self: Handle, status: raw_process.ChildStatus): raw_process.ChildStatus
  self._status = status
  reaped[self.pid] = nil
  owned[self.pid] = nil
  return status
end

--- This handle's child's exit status, once it has one. With `block`,
--- waits for it.
local function exited(self: Handle, block?: boolean): raw_process.ChildStatus | nil, string
  if self._status then return self._status, "" end
  collect()
  if reaped[self.pid] then return claim(self, reaped[self.pid]), "" end
  local status, trouble = raw.waitpid(self.pid, not block)
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
local function keep(self: Handle, stream: Pipe, data: string)
  if stream.streamed then
    stream.tail = stream.tail + 1
    stream.chunks[stream.tail] = data
    stream.size = stream.size + #data
    return
  end
  stream.chunks[#stream.chunks + 1] = data
  stream.size = stream.size + #data
  if stream.size > 2 * self._limit then
    local whole = table.concat(stream.chunks)
    stream.chunks = { whole:sub(-self._limit) }
    stream.size = self._limit
    stream.truncated = true
  end
end

local function text_of(self: Handle, stream: Pipe): string
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
--- A streamed output holding `_limit` unread bytes is left alone.
--- `writable`, a stdin stream's descriptor, is waited on for room too,
--- only to end the wait; its writer does the writing.
local function pump(handles: {Handle}, timeout_ms: integer, writable?: integer): boolean
  local fds: {integer} = {}
  local events: {integer} = {}
  local owners: {Handle} = {}
  local which: {integer} = {}
  if writable ~= nil then
    fds[1], events[1], owners[1], which[1] = writable, raw.POLLOUT, handles[1], -1
  end
  for _, h in ipairs(handles) do
    if h._streams then
      for index, stream in ipairs(h._streams) do
        if stream.fd ~= nil and (not stream.streamed or stream.size < h._limit) then
          fds[#fds + 1] = stream.fd
          events[#events + 1] = raw.POLLIN
          owners[#owners + 1] = h
          which[#which + 1] = index
        end
      end
    end
    if h._input_fd ~= nil then
      fds[#fds + 1] = h._input_fd
      events[#events + 1] = raw.POLLOUT
      owners[#owners + 1] = h
      which[#which + 1] = 0
    end
  end
  if #fds == 0 then
    if timeout_ms > 0 then local _, _ = sys.nanosleep(timeout_ms * 1000 * 1000) end
    return false
  end
  local revents, _ = raw.poll(fds, events, timeout_ms)
  if revents == nil then
    -- A descriptor that went bad under us cannot be serviced; close
    -- every stream rather than spin on it.
    for i = 1, #fds do
      if which[i] == 0 then
        end_input(owners[i])
      elseif which[i] > 0 then
        end_stream(owners[i], which[i])
      end
    end
    return true
  end
  local moved = false
  for i, happened in ipairs(revents) do
    if happened ~= 0 then
      moved = true
      local h = owners[i]
      if which[i] < 0 then
        -- The stdin stream has room: its writer, waiting on this, writes.
      elseif which[i] == 0 then
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
        -- A streamed output takes no more than its limit leaves room for.
        local want = CHUNK
        if stream.streamed and h._limit - stream.size < want then want = h._limit - stream.size end
        local data, _, errno = sys.read(stream.fd, want)
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
  close_fd(self._feed_fd)
  self._feed_fd = nil
  if self._streams then
    -- Anything still buffered in a pipe is there for the taking now;
    -- a writer that escaped the group can keep it open, so stop at the
    -- first round that finds nothing rather than wait for end of file.
    -- A streamed output is left open, and no fuller than its limit: its
    -- reader reads on from the pipe, and ends it (see `pipe_reader`).
    while pump({ self }, 0) do end
    for index, stream in ipairs(self._streams) do
      if not stream.streamed then
        end_stream(self, index)
        local text = text_of(self, stream)
        r.captured[stream.child_fd] = text
        if stream.truncated then r.truncated = true end
      end
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
--- yet, and no failure. When the open guard has caught a signal and the
--- child has not exited, fails with it; the guard keeps it.
local function poll_until(self: Handle, deadline?: integer,
    timed_out?: boolean, ignore_cancel?: boolean, killed?: boolean): Result | nil, string
  while true do
    local status, trouble = exited(self)
    if status ~= nil then return settled(self, timed_out or false, killed) end
    if trouble ~= "" then return nil, trouble end
    if not ignore_cancel and active ~= nil then
      local cancelled = active:cancelled()
      if cancelled ~= 0 then return nil, cancelled_by(cancelled) end
    end
    local left = slice(deadline)
    if left == nil then return nil, "" end
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

local closed_message <const> = "stream: already closed"

--- Why a stream's wait should stop now, beyond its own data: the open
--- guard caught a signal, or the child could not be asked about.
local function interrupted(self: Handle): string
  if active ~= nil then
    local cancelled = active:cancelled()
    if cancelled ~= 0 then return cancelled_by(cancelled) end
  end
  local _, trouble = exited(self)
  return trouble
end

--- The Reader of `self`'s streamed output at `index`: it takes what
--- `pump` queued, pumping every stream of the child while it waits.
local function pipe_reader(self: Handle, index: integer): Stream.Reader
  local pipe = self._streams[index]
  local closed = false
  local failed: string
  local r: Stream.Reader = {}
  r.read = function(_self: Stream.Reader, max?: integer): string | nil, string
    if max ~= nil and max < 1 then error("stream: a read needs a max of at least 1", 2) end
    if failed then return nil, failed end
    if closed then return nil, closed_message end
    while pipe.size == 0 do
      if pipe.fd == nil then return nil, "" end
      local why = interrupted(self)
      if why ~= "" then
        failed = why
        return nil, failed
      end
      if self._status ~= nil then
        -- The child is gone: what it wrote is in the pipe already, and
        -- a round that finds nothing ready means only an escaped
        -- descendant holds it open, which this read does not wait for.
        pump({ self }, 0)
        if pipe.size == 0 and pipe.fd ~= nil then end_stream(self, index) end
      else
        pump({ self }, POLL_MS)
      end
    end
    local want = max or CHUNK
    local chunk = pipe.chunks[pipe.head]
    if #chunk <= want then
      pipe.chunks[pipe.head] = nil
      pipe.head = pipe.head + 1
      pipe.size = pipe.size - #chunk
      return chunk, ""
    end
    pipe.chunks[pipe.head] = chunk:sub(want + 1)
    pipe.size = pipe.size - want
    return chunk:sub(1, want), ""
  end
  r.close = function(_self: Stream.Reader): boolean, string
    if closed then return true, "" end
    closed = true
    -- The child's next write to it fails, as it would into `head`.
    end_stream(self, index)
    pipe.chunks, pipe.head, pipe.tail, pipe.size = {}, 1, 0, 0
    return true, ""
  end
  return r
end

--- The Writer of `self`'s stdin stream: each write goes out whole,
--- pumping the child's streams while its stdin is full.
local function feed_writer(self: Handle): Stream.Writer
  local failed: string
  local closed = false
  local w: Stream.Writer = {}
  w.write = function(_self: Stream.Writer, data: string): boolean, string
    if failed then return false, failed end
    if closed then return false, closed_message end
    local fd = self._feed_fd
    -- Only a settled child's stdin is closed from under its writer.
    if fd == nil then return false, "the child has exited" end
    local at = 0
    while at < #data do
      local written, trouble, errno = sys.write(fd, data:sub(at + 1, at + CHUNK))
      if written ~= nil then
        at = at + written
      elseif errno == sys.EAGAIN or errno == sys.EINTR then
        local why = interrupted(self)
        if why == "" and self._status ~= nil then why = "the child has exited" end
        if why ~= "" then
          failed = why
          return false, failed
        end
        pump({ self }, POLL_MS, fd)
      else
        -- EPIPE included: the child closed its stdin, or exited.
        failed = trouble
        return false, failed
      end
    end
    return true, ""
  end
  w.close = function(_self: Stream.Writer): boolean, string
    closed = true
    local fd = self._feed_fd
    if fd == nil then return true, "" end
    self._feed_fd = nil
    local ok, trouble = sys.close(fd)
    if not ok then return false, trouble end
    return true, ""
  end
  w.abort = w.close
  return w
end

--- Closes every streamed output a settle left open for its reader,
--- which then reads what is queued and ends.
local function end_streamed(self: Handle)
  if not self._streams then return end
  for index, stream in ipairs(self._streams) do
    if stream.streamed then end_stream(self, index) end
  end
end

local handle_mt: metatable<Handle> = {
  __close = function(self: Handle)
    if not self._closed then local _, _ = terminate(self) end
    end_streamed(self)
  end,
  __gc = function(self: Handle)
    if not self._closed then local _, _ = terminate(self) end
    end_streamed(self)
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
    if timeout_ms == nil and active == nil and not self._streams and
        not self._input_fd then
      local status, trouble = exited(self, true)
      if not status then return nil, trouble end
      return settled(self, false)
    end
    -- TODO: raise on a negative timeout, as `validate` does for Child.run's
    -- `timeout_ms` and as `Child.wait_any` should too: a wrong shape is a
    -- mistake, not a failure to report.
    if timeout_ms ~= nil and timeout_ms < 0 then return nil, "timeout is negative" end
    local deadline: integer
    if timeout_ms ~= nil then deadline = now() + timeout_ms * 1000000 end
    local r, trouble = poll_until(self, deadline)
    if r then return r, "" end
    local cancelled = active ~= nil and active:cancelled() or 0
    if cancelled ~= 0 then
      -- A wait the guard's signal ended leaves no child running. The
      -- signal may have landed after the deadline, so say so here.
      local why = trouble ~= "" and trouble or cancelled_by(cancelled)
      local _, ended_trouble = terminate(self)
      if ended_trouble ~= "" then return nil, why .. "; " .. ended_trouble end
      return nil, why
    end
    if trouble ~= "" then return nil, trouble end
    return terminate(self)
  end

  function h:close(): boolean, string
    if not self._closed then
      local r, trouble = terminate(self)
      if not r then return false, trouble end
    end
    end_streamed(self)
    return true, ""
  end

  owned[pid] = true
  return setmetatable(h, handle_mt)
end

local guard_mt: metatable<Guard> = {
  __close = function(self: Guard)
    local _, _ = self:close()
  end,
}

--- The guard for signals `raw.guard_child_signals` has just begun to
--- hold, made the open one.
local function make_guard(): Guard
  local g: Guard = { _signal = 0, _fresh = 0, _closed = false, _trouble = "" }

  --- Moves the signal the core has held since its last read, if any,
  --- into both what `cancelled` and what `take` answer, so neither
  --- steals the other's.
  local function read(self: Guard)
    if self._closed then return end
    -- The core keeps the last signal delivered since its last read.
    -- Only a sigprocmask refused its own valid arguments could fail
    -- this; it is read as no new signal.
    local signal, _ = raw.cancelled_child_signal()
    if signal ~= nil and signal ~= 0 then
      self._signal, self._fresh = signal, signal
    end
  end

  function g:cancelled(): integer
    read(self)
    return self._signal
  end

  function g:take(): integer
    read(self)
    local signal = self._fresh
    self._fresh = 0
    return signal
  end

  --- Restores the caller's dispositions, once, and keeps the last
  --- signal delivered up to then: false and why when they could not be
  --- restored, kept for every later close or release to answer again.
  local function restore(self: Guard): boolean, string
    self._closed = true
    if active == self then active = nil end
    local late, trouble = raw.unguard_child_signals()
    if late == nil then
      self._trouble = trouble
      return false, trouble
    end
    if late ~= 0 then self._signal, self._fresh = late, late end
    return true, ""
  end

  function g:close(): boolean, string
    if self._closed then
      if self._trouble ~= "" then return false, self._trouble end
      return true, ""
    end
    local restored, trouble = restore(self)
    if not restored then return false, trouble end
    if self._signal ~= 0 then
      -- The caller's own dispositions are back: deliver it as it came.
      local _, _ = sys.kill(sys.getpid(), self._signal)
    end
    return true, ""
  end

  function g:release(): integer | nil, string
    if self._closed then
      if self._trouble ~= "" then return nil, self._trouble end
      return self._signal, ""
    end
    local restored, trouble = restore(self)
    if not restored then return nil, trouble end
    return self._signal, ""
  end

  active = g
  return setmetatable(g, guard_mt)
end

local record Child
  type Result = Result
  type Options = Options
  type Sandbox = Sandbox
  type Unveil = Unveil
  type TryWait = TryWait
  type Handle = Handle
  type Guard = Guard
end

--- Holds SIGINT and SIGTERM for this process while it supervises
--- children, so it can end them before it is ended itself. Until the
--- guard closes, either signal is caught rather than acted on:
--- `g:cancelled()` answers the last one delivered, 0 until one is.
--- Only `h:wait` reads the guard -- it ends its child and answers
--- "cancelled by signal N" once a signal is caught -- and a stream's
--- read or write, which fails with the same message and leaves the
--- child running; `Child.wait_any` and `h:try_wait` do not, so a loop
--- over them asks `g:cancelled()` each round. `g:take()` answers the
--- last signal delivered since the previous take, or 0, and clears it,
--- so a caller that passes signals on to its child passes each one on,
--- a repeat included; signals
--- delivered between two takes answer as the last of them. A signal
--- this process ignores stays ignored.
--- Closing the guard -- `g:close()`, or leaving the scope of a
--- `local g <close> = assert(Child.guard())` -- restores the
--- dispositions the process had and delivers the last signal caught
--- again, so a process that would have died of it dies of it then,
--- its children already ended. One guard is open at a time,
--- `Child.run`'s included: another answers nil and why, naming the
--- open guard ("a guard ... is already open"). `close`
--- answers false and why when the dispositions could not be restored,
--- and again on every later close; the signal is not delivered then.
--- A guard never closed holds the signals for the rest of the
--- process's life: hold it in a `<close>` variable.
--- `g:release()` restores the dispositions as closing does but keeps
--- the last signal caught rather than delivering it, and answers it,
--- or 0: a caller that passed signals on to its child re-raises one
--- only if the child died of it, or never got it. It answers nil and
--- why when the dispositions could not be restored, and again on every
--- later release. A released guard is closed: closing it again, or
--- releasing it again, does nothing, and a release after a close
--- answers the signal the close delivered.
function Child.guard(): Guard | nil, string
  local guarded, trouble, errno = raw.guard_child_signals()
  if not guarded then return nil, busy(trouble, errno) end
  return make_guard(), ""
end

--- Raises at level 4, the caller of `Child.start` or `Child.run`: it and
--- `without_nul` run under `validate`, which runs under either one.
local function descriptor(value: integer | string, name: string, words: {string:boolean}):
    integer | string
  if value == nil then return "inherit" end
  if value is string and words[value] then return value end
  if value is integer and value >= 0 and value <= INT_MAX then return value end
  local allowed: {string} = {}
  for word in pairs(words) do allowed[#allowed + 1] = "'" .. word .. "'" end
  table.sort(allowed)
  error(name .. " must be a file descriptor or one of " .. table.concat(allowed, ", "), 4)
end

local STDIN_WORDS <const> = { inherit = true, null = true, pipe = true, stream = true }
local STDOUT_WORDS <const> = { inherit = true, null = true, capture = true, stream = true }
local STDERR_WORDS <const> = {
  inherit = true, null = true, capture = true, stdout = true, stream = true,
}
local FD_WORDS <const> = { capture = true }

local function without_nul(value: string, name: string)
  if value:find("\0", 1, true) then error(name .. " contains a NUL byte", 4) end
end

local function validate(argv: {string}, opts: Options)
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
    error("timeout_ms is out of range", 3)
  end
  if opts.sandbox ~= nil and opts.sandbox.unveil ~= nil then
    local unveil = opts.sandbox.unveil
    for _, list in ipairs({ unveil.reads or {}, unveil.writes or {} }) do
      for _, path in ipairs(list) do
        without_nul(path, "an unveiled path")
        if path:sub(1, 1) ~= "/" then error("an unveiled path must be absolute", 3) end
      end
    end
  end
end

--- Descriptors this process opened for one start, closed together
--- whatever happens: the child's ends always, ours only on failure.
local record Wiring
  child_ends: {integer}
  ours: {integer}
  streams: {Pipe}
  input_fd: integer | nil
  stdin_fd: integer | nil
  feed_fd: integer | nil
end

local function unwire(wiring: Wiring, keep_ours: boolean)
  for _, fd in ipairs(wiring.child_ends) do local _, _ = sys.close(fd) end
  if not keep_ours then
    for _, fd in ipairs(wiring.ours) do local _, _ = sys.close(fd) end
  end
end

--- A pipe whose read end is ours and whose write end the child gets
--- as `child_fd`; the stream records it, as the caller's to read when
--- `streamed`.
local function capture(wiring: Wiring, child_fd: integer, streamed?: boolean): integer | nil, string
  local ends, trouble = raw.pipe()
  if ends == nil then return nil, trouble end
  wiring.child_ends[#wiring.child_ends + 1] = ends.writer
  wiring.ours[#wiring.ours + 1] = ends.reader
  local nonblocking, nonblocking_trouble = raw.set_nonblocking(ends.reader, true)
  if not nonblocking then return nil, nonblocking_trouble end
  wiring.streams[#wiring.streams + 1] = {
    fd = ends.reader, child_fd = child_fd, chunks = {}, size = 0, truncated = false,
    streamed = streamed or false, head = 1, tail = 0,
  }
  return ends.writer, ""
end

local function null(wiring: Wiring, flags: integer): integer | nil, string
  local fd, trouble = sys.open("/dev/null", flags)
  if fd == nil then return nil, trouble end
  wiring.child_ends[#wiring.child_ends + 1] = fd
  return fd, ""
end

--- The descriptor the child's output `child_fd` goes to, as `how` asks:
--- a pipe to capture or stream, /dev/null, or a descriptor given; nil
--- and "" to inherit this process's, and nil and why when it fails.
local function wire_output(wiring: Wiring, child_fd: integer,
                           how: integer | string): integer | nil, string
  if how == "capture" or how == "stream" then
    return capture(wiring, child_fd, how == "stream")
  elseif how == "null" then
    return null(wiring, sys.O_WRONLY)
  elseif how is integer then
    return how, ""
  end
  return nil, ""
end

--- Resolves the options into the descriptor each child slot copies:
--- nil to inherit, or a descriptor number.
local function wire(opts: Options, wiring: Wiring): {integer:integer} | nil, string
  local slots: {integer:integer} = {}
  local stdin = descriptor(opts.stdin, "stdin", STDIN_WORDS)
  if opts.input ~= nil or stdin == "pipe" or stdin == "stream" then
    local ends, trouble = raw.pipe()
    if ends == nil then return nil, trouble end
    wiring.child_ends[#wiring.child_ends + 1] = ends.reader
    wiring.ours[#wiring.ours + 1] = ends.writer
    slots[0] = ends.reader
    -- A write to a child that has gone fails with EPIPE rather than
    -- ending this process, whoever writes it: this module feeding
    -- `input`, or the caller writing to `h.stdin`.
    local ignored, ignore_trouble = raw.ignore_sigpipe()
    if not ignored then return nil, ignore_trouble end
    if opts.input ~= nil or stdin == "stream" then
      local nonblocking, nonblocking_trouble = raw.set_nonblocking(ends.writer, true)
      if not nonblocking then return nil, nonblocking_trouble end
      if opts.input ~= nil then
        wiring.input_fd = ends.writer
      else
        wiring.feed_fd = ends.writer
      end
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
  local out, out_trouble = wire_output(wiring, 1, descriptor(opts.stdout, "stdout", STDOUT_WORDS))
  if out_trouble ~= "" then return nil, out_trouble end
  slots[1] = out
  local stderr = descriptor(opts.stderr, "stderr", STDERR_WORDS)
  if stderr == "stdout" then
    slots[2] = slots[1] or 1
  else
    local err, err_trouble = wire_output(wiring, 2, stderr)
    if err_trouble ~= "" then return nil, err_trouble end
    slots[2] = err
  end
  if opts.fds ~= nil then
    local numbers: {integer} = {}
    for number in pairs(opts.fds) do numbers[#numbers + 1] = number end
    table.sort(numbers)
    for _, number in ipairs(numbers) do
      local value = opts.fds[number]
      if value is integer then
        slots[number] = value
      else
        local fd, trouble = capture(wiring, number)
        if fd == nil then return nil, trouble end
        slots[number] = fd
      end
    end
  end
  return slots, ""
end

--- Whether `name` is a bare name -- no slash -- that is not there in
--- `cwd` (this process's own when nil), which does exist: most often a
--- program meant to be found on PATH. Not when the directory is what
--- is missing, nor when the file is there and its `#!` interpreter is
--- not: those fail with the same ENOENT.
local function unfound_name(name: string, cwd?: string): boolean
  if name == "" or name:find("/", 1, true) ~= nil then return false end
  local dir = cwd or "."
  local there, _ = sys.stat(dir)
  if there == nil then return false end
  local found, _ = sys.lstat(dir .. "/" .. name)
  return found == nil
end

--- `Child.start` on options already validated.
local function start(argv: {string}, opts: Options): Handle | nil, string
  local grouped = opts.process_group
  if grouped == nil then grouped = true end
  if grouped and adopting == nil then
    local subreaper, _ = raw.subreaper()
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
  -- TODO: offer the rest of spawn's `sandbox` -- a ruleset from
  -- raw.landlock_ruleset, a pledge -- once a caller wants a child held
  -- to one: build/sandbox_probe.tl, which reaches the raw table for them.
  local sandbox: raw_process.Sandbox = nil
  if opts.sandbox ~= nil then
    local given = opts.sandbox.unveil
    sandbox = { offline = opts.sandbox.offline == true }
    if given ~= nil then
      sandbox.unveil = { reads = given.reads or {}, writes = given.writes or {}, at = given.at }
    end
  end
  local pid, trouble, errno = raw.spawn(argv[1], argv, opts.env, opts.cwd,
    slots[0], slots[1], slots[2], grouped, extra, sandbox)
  unwire(wiring, pid ~= nil)
  if not pid then
    if errno == sys.ENOENT and unfound_name(argv[1], opts.cwd) then
      trouble = trouble .. ": " .. string.format("%q", argv[1]) ..
        " is run as a path, with no PATH search; Proc.find(" ..
        string.format("%q", argv[1]) .. ") answers where a shell would find it"
    end
    return nil, "start: " .. trouble
  end
  local h = make_handle(pid, grouped)
  h._limit = opts.capture_limit or DEFAULT_CAPTURE_LIMIT
  if #wiring.streams > 0 then h._streams = wiring.streams end
  if wiring.input_fd ~= nil then
    h._input_fd, h._input, h._input_at = wiring.input_fd, opts.input, 0
    if #opts.input == 0 then end_input(h) end
  end
  h.stdin = wiring.stdin_fd
  if wiring.feed_fd ~= nil then
    h._feed_fd = wiring.feed_fd
    h.stdin_stream = feed_writer(h)
  end
  for index, stream in ipairs(wiring.streams) do
    if stream.streamed then
      local reader = pipe_reader(h, index)
      if stream.child_fd == 1 then h.stdout_stream = reader else h.stderr_stream = reader end
    end
  end
  return h, ""
end

--- Starts one executable and returns an owning handle. argv[1] is an exact
--- path, without PATH lookup: `Proc.find` finds a program by
--- name. Dropping or closing a handle whose child is unfinished ends the
--- child and its group; `wait(timeout)` does the same on expiry.
--- `timeout_ms` is refused: bound the child with `h:wait(timeout_ms)`.
function Child.start(argv: {string}, opts?: Options): Handle | nil, string
  opts = opts or {}
  if opts.timeout_ms ~= nil then
    error("timeout_ms is Child.run's; bound a started child with h:wait(timeout_ms)", 2)
  end
  validate(argv, opts)
  return start(argv, opts)
end

--- Waits for the first of several handles to finish, servicing every
--- one's streams meanwhile, and returns it settled: its `wait()` answers
--- at once. Nil and "" when `timeout_ms` passes first -- no handle
--- finished, and nothing failed -- and the handles are left running:
--- a timeout is `done == nil and trouble == ""`, so test `done` itself.
--- `assert` on this answer raises at a timeout, with an empty message.
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
    local left = slice(deadline)
    if left == nil then return nil, "" end
    pump(handles, left)
  end
end

--- The children of this process that no handle owns, from Linux's
--- per-thread `children` list -- this thread's, which is the one that
--- starts every child, named /proc/thread-self rather than by
--- `getpid()`, which in a sandbox whose /proc is the host's names
--- another process -- but for the sandboxes' inits the process table
--- started (`sandbox_inits`), each of which ends with the child it was
--- started for; nil where there is no such list.
local function strays(): {integer} | nil
  local fd, _ = sys.open("/proc/thread-self/children", sys.O_RDONLY)
  if fd == nil then return nil end
  local parts: {string} = {}
  while true do
    local data, _ = sys.read(fd, CHUNK)
    if data == nil or data == "" then break end
    parts[#parts + 1] = data
  end
  local _, _ = sys.close(fd)
  local inits: {integer:boolean} = {}
  for _, pid in ipairs(raw.sandbox_inits()) do inits[pid] = true end
  local found: {integer} = {}
  for number in table.concat(parts):gmatch("%d+") do
    local pid = math.tointeger(tonumber(number))
    if pid ~= nil and not owned[pid] and not inits[pid] then found[#found + 1] = pid end
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

--- Runs a program to completion: executes one executable path as a command
--- and answers its `Result`. A child that exits nonzero, or is ended by a signal or its timeout, is
--- still a `Result`, with `ok` false. `argv[1]` is used exactly as given:
--- there is no PATH search, and `Proc.find` finds a program by name. A nil
--- environment inherits this process's environment; a table replaces it
--- exactly. Standard streams inherit by default, or accept caller-owned
--- descriptors (which remain open here), "null", or "capture"; "stream"
--- is refused, as nothing could read or write it before the run returns.
--- The child owns a new process group by default, so timeout cleanup
--- includes descendants.
---
--- While the child runs, SIGINT and SIGTERM are held in a `Child.guard`:
--- either one ends the child and its group, then the caller's
--- dispositions are restored and the signal delivered again. The run
--- then answers nil and "cancelled by signal N". Because one guard is
--- open at a time, a run made while the caller holds a `Child.guard`
--- answers nil and "signal guard: a guard ... is already open ...";
--- close the caller's guard first, or supervise with `Child.start`. It
--- also answers nil and why when the child cannot be started.
function Child.run(argv: {string}, opts?: Options): Result | nil, string
  opts = opts or {}
  validate(argv, opts)
  if opts.stdin == "stream" or opts.stdout == "stream" or opts.stderr == "stream" then
    error("a \"stream\" is read or written while the child runs: use Child.start", 2)
  end
  local guarded, guard_trouble, guard_errno = raw.guard_child_signals()
  if not guarded then return nil, "signal guard: " .. busy(guard_trouble, guard_errno) end
  local guard = make_guard()
  local h: Handle
  local function supervised(): Result | nil, string
    local started, trouble = start(argv, opts)
    if not started then return nil, trouble end
    h = started
    return h:wait(opts.timeout_ms)
  end
  local called, r, wait_trouble = pcall(supervised)
  local cleanup_trouble: string
  if h and not h._closed and (not called or guard:cancelled() ~= 0 or not r) then
    local cleaned, answer, failure = pcall(terminate, h)
    if not cleaned then
      cleanup_trouble = tostring(answer)
      emergency_cleanup(h)
    elseif failure ~= "" then
      cleanup_trouble = failure
    end
  end
  -- Closing re-delivers a caught signal, after the cleanup above.
  local restored, restore_trouble = guard:close()
  if not restored then
    if not called then error(r, 0) end
    return nil, "signal restore: " .. restore_trouble
  end
  local cancellation = guard:cancelled()
  if cancellation ~= 0 then
    return nil, cleanup_trouble or wait_trouble or cancelled_by(cancellation)
  end
  if not called then error(r, 0) end
  if cleanup_trouble then return nil, cleanup_trouble end
  if r then return r, "" end
  return nil, wait_trouble
end

return Child
