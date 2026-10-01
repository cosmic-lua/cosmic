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
--- together with [`Child.wait_any`]. Completion is the child's exit, never
--- end of file: a descendant that escaped the group and still holds a
--- captured pipe cannot hold up a wait.
---
--- In a task of [`Poll.run`], every wait here -- a handle's, a stream's,
--- [`Child.run`]'s, [`Child.wait_any`]'s, [`Child.end_strays`]'s -- waits
--- through the run, and the other tasks run meanwhile; elsewhere it
--- holds the thread. A child's exit wakes a wait once the kernel says
--- it has exited, where the platform gives a descriptor for that (a
--- pidfd on Linux, a kqueue on Darwin) -- a moment after the child's
--- last act, which its teardown and a busy host's scheduling lengthen
--- -- and is looked for every 10 ms elsewhere. A wait whose task is cancelled
--- answers nil (or false) and [`Poll.CANCELLED`], as [`cosmic.net`]'s
--- do, and leaves the child running, for its handle to end. Ending a
--- child in a cancelled task -- [`Child.run`]'s, a close, a timeout --
--- waits through the run all the same ([`Poll.shielded`]) until it is
--- done: a second or so for each child that ignores SIGTERM, most of it
--- waiting for its group to empty.
---
--- A stream redirected to "stream" is the caller's to read or write
--- while the child runs, through the handle's `stdout_stream`,
--- `stderr_stream` (each a [`cosmic.stream`] Reader) or `stdin_stream` (a
--- Writer). While one of them waits, it services the child's other
--- streams too, so reading stdout cannot stall on a child blocked
--- writing a full stderr, nor writing stdin on one blocked writing a
--- full stdout: what arrives on a streamed output meanwhile waits in
--- memory, up to `capture_limit` unread bytes of each, after which the
--- child is left to wait until the caller reads. Nothing streamed is
--- dropped, and nothing is kept for the Result.
local Poll = require("cosmic.poll")
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
  --- Whether the child ran past the timeout ([`Child.run`]'s
  --- `timeout_ns`, or [`Handle.wait`]'s) and was ended for it.
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

--- The paths a sandbox gives a child ([`Sandbox.unveil`]), each
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
  --- With `unveil` and `group`, the user the child runs as in place of
  --- this process's root, as an unprivileged caller's child runs, and
  --- so confines one of its own at any depth: this process must hold
  --- CAP_SETUID, CAP_SETGID and CAP_SETFCAP where it and `group` are
  --- mapped, and the start fails EPERM where it does not. Nil runs the
  --- child as this process's own user. Not 0.
  user: integer
  --- The group the child runs as with `user`, which each needs the
  --- other, with no supplementary group. Not 0.
  group: integer
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
  --- How long [`Child.run`] lets the child run before ending it, as
  --- [`Handle.wait`] does with its own timeout. [`Child.start`] refuses it:
  --- a started child's time is the caller's to bound, by `h:wait(ns)`.
  timeout_ns: integer
  --- What the child is held to (see [`Sandbox`]); nil for nothing.
  sandbox: Sandbox
end

--- What [`Handle.try_wait`] answers.
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
  --- handle owns ([`Options.process_group`]).
  process_group: boolean
  --- The writable end of the child's stdin when `stdin` was "pipe", until
  --- `close_stdin`.
  stdin: integer | nil
  --- Readers of stdout and stderr, when each was "stream". Each reads
  --- until the child's end of the pipe closes, or until the child has
  --- exited and nothing more is waiting: a descendant that escaped the
  --- group still holding it cannot hold a read up. A wait leaves them
  --- to read on; `close` ends them once what is queued is read. While
  --- the innermost open guard has caught a signal, a read or a write
  --- fails with "cancelled by signal N", as a wait does.
  stdout_stream: Stream.Reader | nil
  --- See `stdout_stream`.
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
  --- A descriptor readable once the child has exited (`exit_watch`),
  --- until its status is claimed; -1 where there is none, so that
  --- setting it makes no new field, which could fail to allocate with
  --- the descriptor in hand.
  _exit_fd: integer
  _result: Result
  _status: raw_process.ChildStatus
  _closed: boolean
  _streams: {Pipe}
  _input_fd: integer | nil
  _input: string
  _input_at: integer
  _limit: integer
  --- Waits for the child to exit and answers its Result. With
  --- `timeout_ns`, a child still running when it passes is ended --
  --- SIGTERM, a grace period, then SIGKILL, its group included -- and
  --- the Result says `timed_out`; [`Child.wait_any`]'s timeout instead
  --- leaves every child running. While a [`Child.guard`] is open, a
  --- SIGINT or SIGTERM it catches ends the wait, timed or not, the same
  --- way: a child that has not exited is ended and the wait answers nil
  --- and "cancelled by signal N"; the guard keeps the signal, and a
  --- later wait answers the ended child's Result. In a task of
  --- [`Poll.run`] that is cancelled, it answers nil and
  --- [`Poll.CANCELLED`], and leaves the child running. A `timeout_ns`
  --- below 0 or past [`Poll.MOST_NS`] raises.
  wait: function(Handle, timeout_ns?: integer): Result | nil, string
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
  --- Closes the writable end of the child's stdin, [`Handle.stdin`], so the
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

--- How often a wait looks for what no descriptor tells it of: the exit
--- of a child with no `_exit_fd` (a Linux before pidfd_open, a filter
--- refusing it), a group's last member gone.
local POLL_NS <const> = Time.ms(10)
--- How often a wait of an adopting process wakes, at the least, to reap
--- the orphans it adopted, which no descriptor announces: often enough
--- that a long wait leaves none a zombie for long.
local REAP_NS <const> = Time.seconds(1)
local TERM_GRACE_NS <const> = Time.ms(250)
local KILL_REAP_NS <const> = Time.seconds(1)
--- One millisecond, which [`sys.poll`] counts its waits in.
local MS <const> = Time.ms(1)
local INT_MAX <const> = 2147483647
local CHUNK <const> = 65536
local DEFAULT_CAPTURE_LIMIT <const> = 16 * 1024 * 1024

--- SIGINT and SIGTERM held for this process while children are
--- supervised; see [`Child.guard`].
local record Guard
  metamethod __close: function(Guard)
  --- The stamp the guard last read: a signal moves it.
  _read: integer
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
  --- Closes the guard. The last guard open to close restores the
  --- dispositions the process had and delivers the last signal caught
  --- again; another leaves it to the guards still open. False and why
  --- when they cannot be restored, and again on every later close.
  close: function(Guard): boolean, string
  --- Closes the guard as `close` does, but keeps the last signal caught
  --- instead of delivering it, and answers that signal, or 0. Nil and
  --- why when the dispositions cannot be restored.
  release: function(Guard): integer | nil, string
  --- In a task of [`Poll.run`], waits for a signal to take, and takes
  --- it; 0 and why once `timeout_ns` passes or the task is cancelled
  --- first, or the guard is closed.
  wait: function(Guard, timeout_ns?: integer): integer, string
end

--- The open guards, the innermost last.
local open_guards: {Guard} = {}

--- The innermost open guard, if any: the one a wait reads.
local active: Guard | nil

--- The stamp of the latest signal a guard caught and then closed on
--- while another stayed open, 0 when none: the last guard to close
--- delivers it, where that guard opened after it and so never saw it.
local owed = 0

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

--- Whether a wait on `handles` is woken by each one's exit: every one
--- not yet reaped has an `_exit_fd`.
local function exits_seen(handles: {Handle}): boolean
  for _, h in ipairs(handles) do
    if h._status == nil and h._exit_fd < 0 then return false end
  end
  return true
end

--- How long the next [`pump`] of `handles` may wait, in nanoseconds, -1
--- for no limit: until `deadline` where each one's exit wakes the wait,
--- but no longer than REAP_NS in an adopting process, and POLL_NS where
--- an exit must be looked for; less as `deadline` nears, and nil once it
--- has passed. A signal needs no bound: a wait that it ends watches the
--- guards' wake pipe while a guard is open. One that began with none
--- open is not ended by a guard another task of the run opens after:
--- a wait reads the guards open as it waits, and a guard opened
--- meanwhile guards the waits that come after it.
local function slice(deadline: integer, handles: {Handle}): integer
  local most = POLL_NS
  if exits_seen(handles) then most = adopting and REAP_NS or -1 end
  if deadline == nil then return most end
  local remaining = deadline - now()
  if remaining <= 0 then return nil end
  if most < 0 then return math.min(remaining, Poll.MOST_NS) end
  return math.min(most, remaining)
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

--- Closes the handle's exit watch, once it has no more to say.
local function unwatch(self: Handle)
  local watch = self._exit_fd
  if watch >= 0 then
    self._exit_fd = -1
    -- Another task may be waiting on it, for this child among others.
    Poll.closing(watch)
    local _, _ = sys.close(watch)
  end
end

--- Files a status with its handle.
local function claim(self: Handle, status: raw_process.ChildStatus): raw_process.ChildStatus
  self._status = status
  reaped[self.pid] = nil
  owned[self.pid] = nil
  unwatch(self)
  return status
end

--- This handle's child's exit status, once it has one. With `block`,
--- waits for it.
local function exited(self: Handle, block?: boolean): raw_process.ChildStatus | nil, string
  if self._status then return self._status, "" end
  collect()
  if reaped[self.pid] then return claim(self, reaped[self.pid]), "" end
  local status, trouble = raw.waitpid(self.pid, not block)
  if not status then
    -- A pid that cannot be waited for (ECHILD: reaped past this module)
    -- has a watch readable for good, which would end every wait at once.
    unwatch(self)
    return nil, trouble
  end
  if status.pid == 0 then return nil, "" end
  return claim(self, status), ""
end

local function close_fd(fd: integer)
  if fd ~= nil then
    Poll.closing(fd)
    local _, _ = sys.close(fd)
  end
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
    close_fd(stream.fd)
    stream.fd = nil
  end
end

local function end_input(self: Handle)
  close_fd(self._input_fd)
  self._input_fd = nil
end

--- Empties the wake pipe, which is readable while any byte a signal
--- wrote there is left.
local function drain_wake()
  local fd = raw.child_signal_fd()
  while true do
    local bytes, _ = sys.read(fd, 512)
    if bytes == nil or #bytes < 512 then return end
  end
end

--- What a [`pump`]'s entry is for, beside a stream's index.
local FEED <const> = -1
local INPUT <const> = 0
local EXIT <const> = -2
local WAKE <const> = -3

--- Whether a wait here goes through [`Poll.run`]: in one of its tasks,
--- where the task can yield -- not in a finalizer, say, which a handle's
--- `__gc` runs in, and which waits on its own.
local function through_run(): boolean
  return Poll.in_task() and coroutine.isyieldable()
end

--- Services every open stream and pending input of `handles` once:
--- waits up to `timeout_ns` (-1 for no limit) for any of them to be
--- ready, or for a child of them not yet reaped to exit, then reads
--- what is there and writes what fits. Returns whether anything moved.
--- A streamed output holding `_limit` unread bytes is left alone.
--- `writable`, a stdin stream's descriptor, is waited on for room too,
--- only to end the wait; its writer does the writing. With `signalled`,
--- a signal an open guard catches ends the wait too, the guards' wake
--- pipe drained for the caller to read the guard.
---
--- In a task of [`Poll.run`], the wait goes through the run, the other
--- tasks running meanwhile. Once the task is cancelled, a `cancellable`
--- pump answers false and [`Poll.CANCELLED`] at once; any other waits
--- shielded from the cancel ([`Poll.shielded`]), as the cleanup it
--- serves -- ending a child, emptying its pipes -- must finish.
local function pump(handles: {Handle}, timeout_ns: integer, writable?: integer,
    cancellable?: boolean, signalled?: boolean): boolean, string
  -- TODO: wait through Poll.delay and Poll.ready alone, here and in
  -- Child.end_strays's sleep, once it is decided how they answer where
  -- no task can wait. (a) They go on, holding the thread, outside a run
  -- and in the `<close>` handler of a task being killed, as Poll.wait
  -- does outside a run: this module's cleanup, which must wait there,
  -- loses its thread-held branches, and poll_test's
  -- test_waiting_outside_a_task_raises and
  -- test_kill_raises_what_a_close_handler_raises and net_serve_test's
  -- test_a_killed_protocols_close_cannot_wait, which hold those waits
  -- to raising, break with it. (b) They stay task-only, and the
  -- branches here stay.
  local fds: {integer} = {}
  local events: {integer} = {}
  local owners: {Handle} = {}
  local which: {integer} = {}
  if writable ~= nil then
    fds[1], events[1], owners[1], which[1] = writable, sys.POLLOUT, handles[1], FEED
  end
  for _, h in ipairs(handles) do
    if h._streams then
      for index, stream in ipairs(h._streams) do
        if stream.fd ~= nil and (not stream.streamed or stream.size < h._limit) then
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
      which[#which + 1] = INPUT
    end
    if h._status == nil and h._exit_fd >= 0 then
      fds[#fds + 1] = h._exit_fd
      events[#events + 1] = sys.POLLIN
      owners[#owners + 1] = h
      which[#which + 1] = EXIT
    end
  end
  -- A wait that yields never, as one with no time to wait does, is
  -- no wait of the run's: it looks and goes on.
  local in_run = timeout_ns ~= 0 and through_run()
  -- Drained only by a wait of the run's, or with no task about: a wait
  -- holding the thread in a task, draining it, would take the wake from
  -- a task waiting on it (`g:wait`) before the run could tell it.
  if signalled and active ~= nil and (in_run or not Poll.in_task()) then
    fds[#fds + 1] = raw.child_signal_fd()
    events[#events + 1] = sys.POLLIN
    owners[#owners + 1] = handles[1]
    which[#which + 1] = WAKE
  end
  if #fds == 0 then
    -- Nothing here could end a wait with no limit: it waits a slice.
    if timeout_ns < 0 then timeout_ns = POLL_NS end
    if in_run then
      local paused, cancelled: boolean, string
      local function pause()
        paused, cancelled = Poll.delay(timeout_ns)
      end
      if cancellable then pause() else Poll.shielded(pause) end
      if paused then return false, "" end
      return false, cancelled
    end
    if timeout_ns > 0 then local _, _ = sys.nanosleep(timeout_ns) end
    return false, ""
  end
  local revents: {integer}
  if in_run then
    local answers, why: {integer}, string
    local function look()
      answers, why = Poll.ready(fds, events, timeout_ns >= 0 and timeout_ns or nil)
    end
    if cancellable then look() else Poll.shielded(look) end
    -- A wait that ran out of time found nothing: no stream moved.
    if answers == nil and why == Poll.TIMEOUT then return false, "" end
    if answers == nil then return false, why end
    revents = answers
  else
    -- Rounded up: a wait with time left polls for at least a millisecond.
    local polled, _ = sys.poll(fds, events, timeout_ns >= 0 and Time.ceil(timeout_ns, MS) or -1)
    revents = polled
  end
  if revents == nil then
    -- A descriptor that went bad under us cannot be serviced; close
    -- every stream rather than spin on it.
    for i = 1, #fds do
      if which[i] == INPUT then
        end_input(owners[i])
      elseif which[i] > 0 then
        end_stream(owners[i], which[i])
      end
    end
    return true, ""
  end
  local moved = false
  for i, happened in ipairs(revents) do
    local h = owners[i]
    -- In a run, another task may have ended what this waited on
    -- meanwhile ([`Poll.closing`]): an entry no longer its own is passed
    -- by.
    local current: integer = fds[i]
    if which[i] == FEED then
      current = h._feed_fd
    elseif which[i] == WAKE then
      current = raw.child_signal_fd()
    elseif which[i] == INPUT then
      current = h._input_fd
    elseif which[i] == EXIT then
      current = h._exit_fd
    elseif which[i] > 0 then
      current = h._streams[which[i]].fd
    end
    if happened ~= 0 and current == fds[i] then
      moved = true
      if which[i] == FEED or which[i] == EXIT then
        -- The stdin stream has room, and its writer, waiting on this,
        -- writes; or the child has exited, and the caller reaps it.
      elseif which[i] == WAKE then
        drain_wake()
      elseif which[i] == INPUT then
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
  return moved, ""
end

--- Waits for a group to have no members left, collecting whatever this
--- process adopted from it meanwhile. False when it did not empty.
local function group_gone(self: Handle, until_ns: integer): boolean
  while true do
    local alive, _, errno = sys.kill(-self.pid, 0)
    if not alive and errno == sys.ESRCH then return true end
    if now() >= until_ns then return false end
    collect()
    local _, _ = pump({ self }, POLL_NS)
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
  -- Clearing the group waits, through the run in a task, where another
  -- task may settle this handle meanwhile: its Result is the one.
  if self._result ~= nil then return self._result, "" end
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
    -- reader reads on from the pipe, and ends it (see [`pipe_reader`]).
    while true do
      local moved, _ = pump({ self }, 0)
      if not moved then break end
    end
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
--- yet, and no failure. When the innermost open guard has caught a
--- signal and the child has not exited, fails with it; the guard keeps
--- it.
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
    local left = slice(deadline, { self })
    if left == nil then return nil, "" end
    local _, why = pump({ self }, left, nil, not ignore_cancel, not ignore_cancel)
    if why ~= "" then return nil, why end
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
  while true do
    local status, _ = exited(self)
    if status ~= nil then return settled(self, true) end
    local left = slice(deadline, { self })
    if left == nil then break end
    local _, _ = pump({ self }, left)
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

--- It holds the thread, in a task of [`Poll.run`] too: it runs only
--- once a cleanup has raised, and must finish.
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
        local _, _ = pump({ self }, 0)
        if pipe.size == 0 and pipe.fd ~= nil then end_stream(self, index) end
      else
        local _, cancelled = pump({ self }, slice(nil, { self }), nil, true, true)
        -- Not kept as `failed`: the task's end, not the stream's.
        if cancelled ~= "" then return nil, cancelled end
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
        local _, cancelled = pump({ self }, slice(nil, { self }), fd, true, true)
        if cancelled ~= "" then return false, cancelled end
        -- Another task may have closed it meanwhile, by this writer's
        -- close or a settle, and its number be another file's by now.
        if self._feed_fd ~= fd then
          failed = closed and closed_message or "the child has exited"
          return false, failed
        end
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
    Poll.closing(fd)
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
  local h: Handle = { pid = pid, process_group = process_group, _exit_fd = -1 }

  function h:try_wait(): TryWait | nil, string
    if self._result then return { finished = true, result = self._result }, "" end
    local _, _ = pump({ self }, 0)
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
    Poll.closing(self.stdin)
    local ok, trouble = sys.close(self.stdin)
    self.stdin = nil
    if not ok then return false, trouble end
    return true, ""
  end

  function h:wait(timeout_ns?: integer): Result | nil, string
    Poll.checked_ns(timeout_ns, "timeout_ns", 2)
    if self._result then return self._result, "" end
    if timeout_ns == nil and active == nil and not self._streams and
        not self._input_fd and not through_run() then
      local status, trouble = exited(self, true)
      if not status then return nil, trouble end
      return settled(self, false)
    end
    local deadline: integer
    if timeout_ns ~= nil then deadline = now() + timeout_ns end
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

--- Takes `stamp`, a stamp the core answered, as what `g` has read: a
--- stamp that moved since the last is a signal caught, for both what
--- `cancelled` and what `take` answer.
local function noted(g: Guard, stamp: integer)
  if stamp ~= g._read then
    local signal = stamp % raw.SIGNAL_STAMP_UNIT
    g._signal, g._fresh, g._read = signal, signal, stamp
  end
end

--- A guard not yet open: [`opened`] opens it.
local function make_guard(): Guard
  local g: Guard = {
    _read = 0, _signal = 0, _fresh = 0, _closed = false, _trouble = "",
  }

  local function read(self: Guard)
    if self._closed then return end
    noted(self, raw.child_signal_read(self == active))
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

  function g:wait(timeout_ns?: integer): integer, string
    if not Poll.in_task() then error("g:wait waits in a task of Poll.run", 2) end
    Poll.checked_ns(timeout_ns, "timeout_ns", 2)
    local deadline: integer
    if timeout_ns ~= nil then deadline = now() + timeout_ns end
    while true do
      -- Asked before each wait and after each wake, never from the
      -- pipe's bytes: another task waiting on it may have drained it.
      local signal = self:take()
      if signal ~= 0 then return signal, "" end
      if self._closed then return 0, "the guard is closed" end
      local left: integer
      if deadline ~= nil then left = math.max(deadline - now(), 0) end
      local woken, why = Poll.readable(raw.child_signal_fd(), left)
      if not woken then return 0, why end
      -- The last close wakes this wait having closed the pipe.
      if not self._closed then drain_wake() end
    end
  end

  --- Closes the guard in the core, once: the last open restores the
  --- caller's dispositions. Answers "" or why they could not be
  --- restored, kept for every later close or release to answer again;
  --- whether this was the last; and, for the last, the signal owed it.
  local function restore(self: Guard): string, boolean, integer
    self._closed = true
    for i = #open_guards, 1, -1 do
      if open_guards[i] == self then
        table.remove(open_guards, i)
        break
      end
    end
    active = open_guards[#open_guards]
    local last = active == nil
    local owing = 0
    if last then owing, owed = owed % raw.SIGNAL_STAMP_UNIT, 0 end
    local fd = raw.child_signal_fd()
    local stamp, trouble = raw.unguard_child_signals(active ~= nil and active._read or 0)
    -- Every task waiting on the pipe looks again: one waiting on this
    -- guard finds it closed and returns, and one waiting on a guard
    -- still open finds its stamp unmoved and waits again.
    Poll.closing(fd)
    if stamp == nil then
      self._trouble = trouble
      return trouble, last, owing
    end
    noted(self, stamp)
    return "", last, owing
  end

  function g:close(): boolean, string
    if self._closed then
      if self._trouble ~= "" then return false, self._trouble end
      return true, ""
    end
    local trouble, last, owing = restore(self)
    if trouble ~= "" then return false, trouble end
    if not last then
      -- The caller's dispositions are not back yet: the guards still
      -- open have seen the signal, if they opened before it, and the
      -- last to close delivers it.
      if self._signal ~= 0 and self._read > owed then owed = self._read end
      return true, ""
    end
    local signal = self._signal ~= 0 and self._signal or owing
    if signal ~= 0 then
      -- The caller's own dispositions are back: deliver it as it came.
      local _, _ = sys.kill(sys.getpid(), signal)
    end
    return true, ""
  end

  function g:release(): integer | nil, string
    if self._closed then
      if self._trouble ~= "" then return nil, self._trouble end
      return self._signal, ""
    end
    local trouble, last, owing = restore(self)
    if trouble ~= "" then return nil, trouble end
    if last and self._signal == 0 and owing ~= 0 then
      local _, _ = sys.kill(sys.getpid(), owing)
    end
    return self._signal, ""
  end

  return setmetatable(g, guard_mt)
end

--- Opens a guard, the innermost of those open. The guard is made, and
--- given its place, before the core opens it, so nothing between that
--- and the answer allocates.
local function opened(): Guard | nil, string
  local g = make_guard()
  open_guards[#open_guards + 1] = g
  local stamp, trouble = raw.guard_child_signals()
  if stamp == nil then
    open_guards[#open_guards] = nil
    return nil, trouble
  end
  g._read = stamp
  active = g
  return g, ""
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
--- child running; [`Child.wait_any`] and `h:try_wait` do not, so a loop
--- over them asks `g:cancelled()` each round. `g:take()` answers the
--- last signal delivered since the previous take, or 0, and clears it,
--- so a caller that passes signals on to its child passes each one on,
--- a repeat included; signals
--- delivered between two takes answer as the last of them. In a task
--- of [`Poll.run`], `g:wait(timeout_ns)` waits for the next signal to
--- take while the other tasks run, and takes it: the signal, or 0 and
--- why once `timeout_ns` passes, the task is cancelled, or the guard
--- closes. A signal this process ignores stays ignored.
---
--- Guards nest: one opened while another is open -- a [`Child.run`]'s
--- too -- is the innermost until it closes, and the waits (`h:wait`,
--- a stream's, [`cosmic.http`]'s) read the innermost. Each guard sees
--- the signals delivered since it opened, and none before: a guard
--- opened after a signal, to run a child during a shutdown, runs it.
--- What an inner guard sees and takes, the outer ones still see.
---
--- Closing the guard -- `g:close()`, or leaving the scope of a
--- `local g <close> = assert(Child.guard())` -- restores the
--- dispositions the process had and delivers the last signal caught
--- again, so a process that would have died of it dies of it then,
--- its children already ended. Only the last guard to close restores
--- and delivers: one closed while another is open leaves the signal to
--- the guards still open, and the last to close delivers it though it
--- opened after it. `close`
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
--- answers the signal the close delivered. The first guard fails, nil
--- and why, where the process has no descriptor left for the pipe
--- `g:wait` waits on. In [`Poll.run`], a wait another task began while no
--- guard was open is not ended by the signals of one opened after it.
function Child.guard(): Guard | nil, string
  return opened()
end

--- Raises at level 4, the caller of [`Child.start`] or [`Child.run`]: it and
--- [`without_nul`] run under `validate`, which runs under either one.
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
  Poll.checked_ns(opts.timeout_ns, "timeout_ns", 3)
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
  local nonblocking, nonblocking_trouble = sys.set_nonblocking(ends.reader, true)
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
      local nonblocking, nonblocking_trouble = sys.set_nonblocking(ends.writer, true)
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

--- Why a start that failed with EINVAL or EMFILE may have failed: the
--- descriptors it places above the highest it hands the child are
--- refused past RLIMIT_NOFILE's soft limit, which a process raises at
--- its start but no further than the hard one. "" where the limit
--- leaves them room.
local function descriptor_limit_hint(slots: {integer:integer}): string
  local top, count = 2, 0
  for number in pairs(slots) do
    count = count + 1
    if number > top then top = number end
  end
  local limits, _ = sys.getrlimit(sys.RLIMIT_NOFILE)
  -- The child's status end takes top + 1; above it, a copy of each
  -- descriptor handed and what spawn places besides.
  if limits == nil or limits.soft > top + 1 + count + raw.SPAWN_PLACED_ABOVE then return "" end
  local remedy = limits.soft < limits.hard and "sys.setrlimit raises it as far as the hard one" or
    "only a higher hard limit makes room"
  return ": the child is handed descriptor " .. tostring(top) .. ", and the start " ..
    "places descriptors above it, past RLIMIT_NOFILE's soft limit of " ..
    tostring(limits.soft) .. " (hard " .. tostring(limits.hard) .. "): " .. remedy
end

--- [`Child.start`] on options already validated.
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
    sandbox = { offline = opts.sandbox.offline == true, user = opts.sandbox.user,
      group = opts.sandbox.group }
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
    elseif errno == sys.EINVAL or errno == sys.EMFILE then
      trouble = trouble .. descriptor_limit_hint(slots)
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
  -- Opened last, once the handle is whole, so nothing that allocates
  -- comes between it and the handle taking it; and before anything
  -- reaps the child, as nothing since the spawn has called `collect`. A child with none -- where the
  -- platform or a filter gives none -- has its exit looked for every
  -- POLL_NS instead.
  local watch, _ = raw.exit_watch(pid)
  if watch ~= nil then h._exit_fd = watch end
  return h, ""
end

--- Starts one executable and returns an owning handle. argv[1] is an exact
--- path, without PATH lookup: [`Proc.find`] finds a program by
--- name. Dropping or closing a handle whose child is unfinished ends the
--- child and its group; `wait(timeout)` does the same on expiry.
--- `timeout_ns` is refused: bound the child with `h:wait(timeout_ns)`.
function Child.start(argv: {string}, opts?: Options): Handle | nil, string
  opts = opts or {}
  if opts.timeout_ns ~= nil then
    error("timeout_ns is Child.run's; bound a started child with h:wait(timeout_ns)", 2)
  end
  validate(argv, opts)
  return start(argv, opts)
end

--- Waits for the first of several handles to finish, servicing every
--- one's streams meanwhile, and returns it settled: its `wait()` answers
--- at once. Nil and [`Poll.TIMEOUT`] when `timeout_ns` passes first --
--- no handle finished, and nothing failed -- and the handles are left
--- running: a timeout is `done == nil and trouble == Poll.TIMEOUT`, and
--- any other trouble beside a nil `done` is a failure. In a task of
--- [`Poll.run`] that is cancelled, it answers nil and
--- [`Poll.CANCELLED`], the handles left running too. A `timeout_ns`
--- below 0 or past [`Poll.MOST_NS`] raises.
function Child.wait_any(handles: {Handle}, timeout_ns?: integer): Handle | nil, string
  -- TODO: carry a settled group's lingering members on Child.Result, a
  -- field beside the exit status, and answer the handle with "" here:
  -- build/test.tl reads the trouble beside the handle's result today, and
  -- build.contracts exempts this pair from the error-slot rules until then.
  if #handles == 0 then error("no handles to wait for", 2) end
  Poll.checked_ns(timeout_ns, "timeout_ns", 2)
  local deadline = timeout_ns ~= nil and now() + timeout_ns or nil
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
    local left = slice(deadline, handles)
    if left == nil then return nil, Poll.TIMEOUT end
    local _, cancelled = pump(handles, left, nil, true)
    if cancelled ~= "" then return nil, cancelled end
  end
end

--- The children of this process that no handle owns, as the process
--- table lists this thread's (`children`), but for the sandboxes' inits
--- it started (`sandbox_inits`), each of which ends with the child it
--- was started for; nil where there is no such list.
local function strays(): {integer} | nil
  local children, _ = raw.children()
  if children == nil then return nil end
  local inits: {integer:boolean} = {}
  for _, pid in ipairs(raw.sandbox_inits()) do inits[pid] = true end
  local found: {integer} = {}
  for _, pid in ipairs(children) do
    if not owned[pid] and not inits[pid] then found[#found + 1] = pid end
  end
  return found
end

--- Ends and reaps every child of this process that no handle owns:
--- what a supervised child left behind when it died without ending
--- its own descendants -- a process group it started, say, which its
--- own group's SIGKILL never reached -- and that this process adopted
--- as their subreaper. Each is sent SIGKILL, with its group when it
--- leads one, until none is left or a second has passed; a stray in
--- one of the process groups `spared` names is left running. Returns
--- how many were ended. Only a Linux process that adopts orphans can
--- find them; elsewhere this returns 0 and they are init's.
function Child.end_strays(spared?: {integer}): integer
  if not adopting then return 0 end
  local groups: {integer:boolean} = {}
  for _, group in ipairs(spared or {}) do groups[group] = true end
  local ended = 0
  local seen: {integer:boolean} = {}
  local deadline = now() + KILL_REAP_NS
  while true do
    collect()
    local found = strays()
    if found ~= nil and next(groups) ~= nil then
      local ending: {integer} = {}
      for _, pid in ipairs(found) do
        -- Not answered: ended as before.
        local group, _ = sys.getpgid(pid)
        if group == nil or not groups[group] then ending[#ending + 1] = pid end
      end
      found = ending
    end
    if found == nil or #found == 0 or now() >= deadline then return ended end
    for _, pid in ipairs(found) do
      local _, _ = sys.kill(-pid, sys.SIGKILL)
      local _, _ = sys.kill(pid, sys.SIGKILL)
      if not seen[pid] then
        seen[pid] = true
        ended = ended + 1
      end
    end
    if through_run() then
      -- Shielded: ending the strays is a cleanup, which a cancel does
      -- not cut short.
      Poll.shielded(function()
        local _, _ = Poll.delay(POLL_NS // 10)
      end)
    else
      local _, _ = sys.nanosleep(POLL_NS // 10)
    end
  end
end

--- The child [`Child.run`] has started, ended where the run is left
--- other than by returning: a task killed where the run waits, or in
--- its cleanup, which the run would not otherwise finish.
local record Running
  handle: Handle
  metamethod __close: function(Running)
end

local running_mt: metatable<Running> = {
  __close = function(self: Running)
    local h = self.handle
    if h == nil or h._closed then return end
    local cleaned, _, _ = pcall(terminate, h)
    if not cleaned then emergency_cleanup(h) end
  end,
}

--- Runs a program -- one executable path -- to completion and answers its
--- [`Result`]. A child that exits nonzero, or is ended by a signal or its
--- timeout, is still a [`Result`], with `ok` false. `argv[1]` is used exactly as given:
--- there is no PATH search, and [`Proc.find`] finds a program by name. A nil
--- environment inherits this process's environment; a table replaces it
--- exactly. Standard streams inherit by default, or accept caller-owned
--- descriptors (which remain open here), "null", or "capture"; "stream"
--- is refused, as nothing could read or write it before the run returns.
--- The child owns a new process group by default, so timeout cleanup
--- includes descendants.
---
--- While the child runs, SIGINT and SIGTERM are held in a [`Child.guard`]:
--- either one ends the child and its group, then the caller's
--- dispositions are restored and the signal delivered again. The run
--- then answers nil and "cancelled by signal N". A run made while the
--- caller holds a [`Child.guard`] holds one inside it: a signal the
--- caller's guard caught before the run began does not end it, and one
--- that ends it is left to the caller's guard rather than delivered.
--- It also answers nil and why when the child cannot be started, and
--- nil and "signal guard: ..." when its guard cannot be opened. In a task
--- of [`Poll.run`] that is cancelled, it ends the child, as a timeout
--- would, and answers nil and [`Poll.CANCELLED`].
function Child.run(argv: {string}, opts?: Options): Result | nil, string
  opts = opts or {}
  validate(argv, opts)
  if opts.stdin == "stream" or opts.stdout == "stream" or opts.stderr == "stream" then
    error("a \"stream\" is read or written while the child runs: use Child.start", 2)
  end
  local held, guard_trouble = opened()
  if held == nil then return nil, "signal guard: " .. guard_trouble end
  -- Closed after `running`, as the run is left: the child is ended
  -- before the guard gives back the signals.
  local guard <close>: Guard = held
  local holder: Running = {}
  local running <close> = setmetatable(holder, running_mt)
  local h: Handle
  local function supervised(): Result | nil, string
    local started, trouble = start(argv, opts)
    if not started then return nil, trouble end
    h = started
    running.handle = started
    return h:wait(opts.timeout_ns)
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
  running.handle = nil
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
