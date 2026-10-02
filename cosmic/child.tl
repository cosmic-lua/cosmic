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
  --- Whether the child ran past a timeout -- its own
  --- [`Options.timeout_ns`], or [`Handle.wait`]'s -- and was ended for it.
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
  --- With `unveil`, fresh writable scratch at /noexec, mounted noexec:
  --- files there cannot execute, including through aliases. Reading,
  --- interpreting or copying their bytes elsewhere is still allowed.
  --- No unveiled path or alias may occupy / or /noexec or beneath it.
  --- This option does not change ordinary /tmp policy. Unsupported
  --- creation fails.
  noexec_scratch: boolean
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

--- Where a child's stdin comes from, beside a descriptor number.
local enum Stdin
  --- This process's own.
  "inherit"
  --- /dev/null.
  "null"
  --- A pipe the caller writes through the handle's `stdin_stream`.
  "stream"
end

--- Where a child's stdout goes, beside a descriptor number.
local enum Stdout
  --- This process's own.
  "inherit"
  --- /dev/null.
  "null"
  --- Memory, the last `capture_limit` bytes of it, for the Result.
  "capture"
  --- A pipe the caller reads through the handle's `stdout_stream`.
  "stream"
end

--- Where a child's stderr goes, beside a descriptor number.
local enum Stderr
  --- This process's own.
  "inherit"
  --- /dev/null.
  "null"
  --- Memory, for the Result, as stdout's.
  "capture"
  --- A pipe the caller reads through the handle's `stderr_stream`.
  "stream"
  --- Stdout's destination, capture or stream included.
  "stdout"
end

--- An ordinary-filesystem Linux launch under both nonzero IDs. All
--- real, effective and saved IDs are set, supplementary groups and
--- effective/permitted/inheritable/ambient capabilities are cleared,
--- and no_new_privs prevents privileged exec from restoring privilege.
--- The capability bounding set stays unchanged. Inherited cwd and
--- descriptors remain grants; an explicit cwd is checked after the
--- transition. Unsupported platforms fail before starting a child.
local record Credentials
  --- The user ID, from 1 through 4294967294.
  user: integer
  --- The group ID, from 1 through 4294967294.
  group: integer
end

local record Options
  --- The child's whole environment, by name: it replaces this process's
  --- rather than adding to it. Nil inherits this process's.
  env: {string:string}
  --- The directory the child starts in. Nil inherits this process's.
  cwd: string
  --- A descriptor, or "inherit" (the default), "null" or "stream", whose
  --- Writer is the handle's `stdin_stream`. A pipe to stdin, this one
  --- or `input`'s, makes this process ignore SIGPIPE from then on, so a
  --- write to a child that has gone fails with EPIPE instead of ending
  --- it.
  stdin: integer | Stdin
  --- Bytes fed to the child's stdin, which is then closed. Excludes a
  --- `stdin` of its own.
  input: string
  --- A descriptor, or "inherit" (the default), "null", "capture" or
  --- "stream", which the handle's `stdout_stream` reads.
  stdout: integer | Stdout
  --- A descriptor, or "inherit" (the default), "null", "capture",
  --- "stream" (read by the handle's `stderr_stream`) or "stdout", which
  --- shares stdout's destination, capture or stream included.
  stderr: integer | Stderr
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
  --- How long the child may run, from its start, before it is ended as
  --- an expired [`Handle.wait`] ends it -- SIGTERM, a grace period, then
  --- SIGKILL, its group included -- its Result `timed_out`. Nil for no
  --- limit. [`Child.run`]'s wait ends the child at it. A started child
  --- is ended for it by whatever waits on it once it has passed: its
  --- handle's `wait` (with a timeout of its own or not), [`try_wait`],
  --- [`Child.wait_any`], or a read or write of its streams. A child that
  --- exited by itself before that is not `timed_out`. Nothing ends it
  --- while nothing waits on it, as no thread runs here but the caller's:
  --- it runs past the deadline until something waits, or its handle
  --- closes. [`Handle.drain`], which ends no process, does not end it
  --- either: a loop over it asks [`try_wait`] to have the deadline kept.
  timeout_ns: integer
  --- What the child is held to (see [`Sandbox`]); nil for nothing.
  sandbox: Sandbox
  --- The IDs and privilege limits for this launch. Excludes sandbox
  --- unveil, offline, user and group. Child setup errors precede exec;
  --- a parent dumpability restoration error can follow exec and ends
  --- the owned child before reporting failure.
  credentials: Credentials
end

--- What [`Handle.try_wait`] answers.
local record TryWait
  --- Whether the child has exited.
  finished: boolean
  --- Its outcome, once `finished`.
  result: Result
end

-- TODO: hand the caller Stream.from_fd over a streamed output's pipe, and
-- delete `streamed`, `head`, `tail` and [`pipe_reader`], once it is
-- decided that a read of one output may stall the child on another: the
-- queue is what lets a wait on one stream service the rest, up to
-- `capture_limit` unread bytes each, so that reading stdout does not
-- stall on a full stderr, nor writing stdin on a full stdout
-- (child_lua_test's test_reading_stdout_does_not_stall_on_a_full_stderr
-- and test_writing_stdin_does_not_stall_on_a_full_stdout); a Stream.from_fd
-- over the bare pipe leaves the pipe's own buffer to hold them.
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
  --- The first terminal read or raw poll failure, after any queued bytes.
  failure: string
  head: integer
  tail: integer
  --- The Reader ended this pipe, explicitly or after an escaped writer.
  reader_closed: boolean
  consuming: boolean
end

--- Bounds and borrowed destinations for [`Handle.drain`].
local record DrainOptions
  --- Required finite wait budget, in nanoseconds; 0 makes one nonblocking round.
  timeout_ns: integer
  --- Required positive total byte budget across both outputs.
  max_bytes: integer
  --- Required exactly when stdout was started as "stream"; never closed here.
  stdout: Stream.Writer | nil
  --- Required exactly when stderr was started as "stream"; never closed here.
  stderr: Stream.Writer | nil
end

--- Why a bounded output drain stopped.
local enum DrainKind
  "eof"
  "limit"
  "timeout"
  "interrupted"
  "failed"
end

--- The outcome of [`Handle.drain`], independent of the child's exit status.
local record DrainResult
  --- The stopping condition; an interrupted guard signal remains untaken.
  kind: DrainKind
  --- Source bytes offered to sinks, including a final failed write; never replayed.
  bytes: integer
  --- Empty except for interrupted or failed, which name the original cause.
  reason: string
end

local record Handle
  metamethod __close: function(Handle)
  --- The child's process id.
  pid: integer
  --- Whether the child leads a process group of its own that this
  --- handle owns ([`Options.process_group`]).
  process_group: boolean
  --- Readers of stdout and stderr, when each was "stream". Each reads
  --- until the child's end of the pipe closes, or until the child has
  --- exited and nothing more is waiting: a descendant that escaped the
  --- group still holding it cannot hold a read up. A wait leaves them
  --- to read on; `close` ends them once what is queued is read. While
  --- the innermost open guard has caught a signal, a read or a write
  --- fails with "child: cancelled by signal N", as a wait does. A read
  --- or a write that waits past the child's own [`Options.timeout_ns`]
  --- ends the child as an expired `wait` would: a read then reads what
  --- it left, and a write fails. A read or raw poll failure follows the
  --- bytes already queued, then remains the reader's failure on later
  --- reads.
  stdout_stream: Stream.Reader | nil
  --- See `stdout_stream`.
  stderr_stream: Stream.Reader | nil
  --- A Writer to stdin, when it was "stream": [`Stream.to_fd`] over the
  --- pipe, so a write goes out whole and a failure is sticky; its `close`
  --- (or `abort`) closes the child's stdin, so the child reads end of
  --- file. A write fails once the child has closed its stdin, or has
  --- exited and nothing else holds it, and after a wait. A write the
  --- child does not read waits for it, however long: a child that stops
  --- reading until its streamed stdout is read, which sits unread at
  --- `capture_limit`, waits forever -- read the outputs as the input
  --- goes in, or bound the child with a timeout.
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
  _explicit_close: boolean
  _drain_next: integer
  _streams: {Pipe}
  _input_fd: integer | nil
  _input: string
  _input_at: integer
  _limit: integer
  --- When the child's own `timeout_ns` passes, on the monotonic clock;
  --- nil for none ([`Options.timeout_ns`]).
  _deadline: integer | nil
  --- Waits for the child to exit and answers its Result. With
  --- `timeout_ns`, or once the child's own [`Options.timeout_ns`]
  --- passes, whichever is first, a child still running is ended --
  --- SIGTERM, a grace period, then SIGKILL, its group included -- and
  --- the Result says `timed_out`; [`Child.wait_any`]'s timeout instead
  --- leaves every child running. While a [`Child.guard`] is open, a
  --- SIGINT or SIGTERM it catches ends the wait, timed or not, the same
  --- way: a child that has not exited is ended and the wait answers nil
  --- and "child: cancelled by signal N"; the guard keeps the signal, and a
  --- later wait answers the ended child's Result. In a task of
  --- [`Poll.run`] that is cancelled, it answers nil and
  --- [`Poll.CANCELLED`], and leaves the child running. A `timeout_ns`
  --- below 0 or past [`Poll.MOST_NS`] raises.
  wait: function(Handle, timeout_ns?: integer): Result | nil, string
  --- Fairly copies streamed outputs to borrowed Writers within both required
  --- bounds. EOF requires closed pipes, including escaped writers. A previous
  --- guard cancellation may be bypassed only after its signal was taken; a
  --- fresh signal interrupts without being consumed. Ordinary Reader failures
  --- remain sticky. No process is ended, reaped to completion, or timed out,
  --- past the child's own [`Options.timeout_ns`] or not.
  --- Concurrent reads/drains raise. Sink failure may have written a prefix;
  --- it ends the selected read ends, and the caller still owns child cleanup.
  --- The deadline bounds pipe waits, not arbitrary code in a Writer. A zero
  --- timeout pumps once without waiting and writes at most one chunk per pipe.
  drain: function(Handle, DrainOptions): DrainResult
  --- Whether the child has exited, without waiting: `finished` is false
  --- while it runs, and true with its `result` once it has exited and its
  --- group is cleared, as `wait` would answer. It services the child's
  --- captured and streamed outputs and input meanwhile. Once the child's
  --- own [`Options.timeout_ns`] has passed, a child still running is
  --- ended as an expired `wait` ends it, which waits for it to go, and
  --- `finished` is true, its Result `timed_out`. Nil and why when
  --- settling the child fails.
  try_wait: function(Handle): TryWait | nil, string
  --- Sends `signal` (SIGTERM by default) to the child, or to its whole
  --- group when `process_group` is true. It does not wait. False and why when the child
  --- has been reaped already or the signal cannot be sent.
  stop: function(Handle, signal?: integer): boolean, string
  --- Ends the child if it is still running, as an expired `wait` does,
  --- reaps it and closes its stdin stream, and ends its streamed outputs so
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

--- What a failure of this module's own, no system call's, answers: nil
--- and `why` under the module's name. A system call's message is
--- passed on as it is, or after the step it failed in.
local function refuse(why: string): nil, string
  return nil, "child: " .. why
end

--- The message a wait or a run cancelled by `signal` answers.
local function cancelled_by(signal: integer): string
  return "child: cancelled by signal " .. tostring(signal)
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

--- The earlier of `deadline` (nil for none) and the child's own, which
--- counts only while it is unsettled.
local function sooner(deadline: integer, self: Handle): integer
  local own = self._deadline
  if own == nil or self._status ~= nil or (deadline ~= nil and deadline <= own) then
    return deadline
  end
  return own
end

--- Whether the child's own deadline has passed while it is unsettled:
--- a wait that finds it so ends the child.
local function overdue(self: Handle): boolean
  return self._deadline ~= nil and self._status == nil and now() >= self._deadline
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

local function end_stream(stream: Pipe)
  if stream.fd ~= nil then
    close_fd(stream.fd)
    stream.fd = nil
  end
end

--- Keep a source failure apart from a Reader's sticky cancellation:
--- another operation can discover it while that Reader stays cancelled.
local function fail_stream(stream: Pipe, trouble: string)
  if stream.streamed and stream.failure == nil then stream.failure = trouble end
  end_stream(stream)
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

--- Whether a wait here goes through [`Poll.run`]: in one of its tasks,
--- where the task can yield -- not in a finalizer, say, which a handle's
--- `__gc` runs in, and which waits on its own.
local function through_run(): boolean
  return Poll.in_task() and coroutine.isyieldable()
end

--- What the descriptor a [`pump`] waits on is for.
local enum Kind
  --- A captured or streamed output, to read.
  "output"
  --- The bytes of `input`, to write.
  "input"
  --- Room in the stdin stream, which its writer, waiting on it, uses.
  "feed"
  --- The child's exit, which the caller reaps.
  "exit"
  --- A signal a guard caught, to drain.
  "wake"
end

--- One descriptor a [`pump`] waits on.
local record Entry
  fd: integer
  events: integer
  --- The child it belongs to; nil for a "wake".
  owner: Handle
  kind: Kind
  --- The output an "output" reads.
  output: Pipe
end

--- What a [`pump`] does about an [`Entry`] of one kind.
local record Service
  --- Whether the entry is still its own: in a run, another task may
  --- have ended what this waited on meanwhile ([`Poll.closing`]), and
  --- its number be another file's.
  live: function(Entry): boolean
  --- Services it, once its descriptor has an event.
  ready: function(Entry)
  --- Gives up on it, once the wait found a descriptor gone bad: it
  --- cannot be serviced, so it is ended rather than spun on.
  broken: function(Entry, string)
end

local function nothing(_: Entry, _trouble?: string) end

local services: {Kind:Service} = {
  output = {
    live = function(e: Entry): boolean return e.output.fd == e.fd end,
    ready = function(e: Entry)
      local stream = e.output
      -- A streamed output takes no more than its limit leaves room for.
      local want = CHUNK
      if stream.streamed and e.owner._limit - stream.size < want then
        want = e.owner._limit - stream.size
      end
      local data, trouble, errno = sys.read(stream.fd, want)
      if data == nil then
        if errno ~= sys.EAGAIN and errno ~= sys.EINTR then fail_stream(stream, trouble) end
      elseif data == "" then
        end_stream(stream)
      else
        keep(e.owner, stream, data)
      end
    end,
    broken = function(e: Entry, trouble: string) fail_stream(e.output, trouble) end,
  },
  input = {
    live = function(e: Entry): boolean return e.owner._input_fd == e.fd end,
    ready = function(e: Entry)
      local h = e.owner
      local offset = h._input_at
      local written, _, errno = sys.write(h._input_fd, h._input:sub(offset + 1, offset + CHUNK))
      if written ~= nil then
        h._input_at = offset + written
        if h._input_at >= #h._input then end_input(h) end
      elseif errno ~= sys.EAGAIN and errno ~= sys.EINTR then
        -- EPIPE included: a child that stopped reading has said so.
        end_input(h)
      end
    end,
    broken = function(e: Entry, _trouble: string) end_input(e.owner) end,
  },
  feed = {
    live = function(e: Entry): boolean return e.owner._feed_fd == e.fd end,
    ready = nothing,
    broken = nothing,
  },
  exit = {
    live = function(e: Entry): boolean return e.owner._exit_fd == e.fd end,
    ready = nothing,
    broken = nothing,
  },
  wake = {
    live = function(e: Entry): boolean return raw.child_signal_fd() == e.fd end,
    ready = drain_wake,
    broken = nothing,
  },
}

--- What a [`pump`] of `handles` waits on: each one's open outputs, not
--- a streamed one holding `_limit` unread bytes, its pending input, and
--- its exit while it is not reaped. With `feeding`, room in that
--- handle's stdin stream too.
local function watching(handles: {Handle}, feeding?: Handle): {Entry}
  local entries: {Entry} = {}
  if feeding ~= nil then
    entries[1] = { fd = feeding._feed_fd, events = sys.POLLOUT, owner = feeding, kind = "feed" }
  end
  for _, h in ipairs(handles) do
    for _, stream in ipairs(h._streams or {}) do
      if stream.fd ~= nil and (not stream.streamed or stream.size < h._limit) then
        entries[#entries + 1] = { fd = stream.fd, events = sys.POLLIN, owner = h,
          kind = "output", output = stream }
      end
    end
    if h._input_fd ~= nil then
      entries[#entries + 1] = { fd = h._input_fd, events = sys.POLLOUT, owner = h, kind = "input" }
    end
    if h._status == nil and h._exit_fd >= 0 then
      entries[#entries + 1] = { fd = h._exit_fd, events = sys.POLLIN, owner = h, kind = "exit" }
    end
  end
  return entries
end

--- Services `entries` once: waits up to `timeout_ns` (-1 for no limit)
--- for any of them to be ready, then reads what is there and writes what
--- fits. Returns whether anything moved. A "feed" is waited on only to
--- end the wait; its writer does the writing. With `signalled`, a
--- signal an open guard catches ends the wait too, the guards' wake
--- pipe drained for the caller to read the guard.
---
--- In a task of [`Poll.run`], the wait goes through the run, the other
--- tasks running meanwhile. Once the task is cancelled, a `cancellable`
--- pump answers false and [`Poll.CANCELLED`] at once; any other waits
--- shielded from the cancel ([`Poll.shielded`]), as the cleanup it
--- serves -- ending a child, emptying its pipes -- must finish.
local function pump(entries: {Entry}, timeout_ns: integer,
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
  -- A wait that yields never, as one with no time to wait does, is
  -- no wait of the run's: it looks and goes on.
  local in_run = timeout_ns ~= 0 and through_run()
  -- Drained only by a wait of the run's, or with no task about: a wait
  -- holding the thread in a task, draining it, would take the wake from
  -- a task waiting on it (`g:wait`) before the run could tell it.
  if signalled and active ~= nil and (in_run or not Poll.in_task()) then
    entries[#entries + 1] = { fd = raw.child_signal_fd(), events = sys.POLLIN, kind = "wake" }
  end
  local fds: {integer} = {}
  local events: {integer} = {}
  for i, e in ipairs(entries) do fds[i], events[i] = e.fd, e.events end
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
  local trouble = ""
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
    local polled, why = sys.poll(fds, events, timeout_ns >= 0 and Time.ceil(timeout_ns, MS) or -1)
    revents, trouble = polled, why
  end
  if revents == nil then
    for _, e in ipairs(entries) do
      local service = services[e.kind]
      if service.live(e) then service.broken(e, trouble) end
    end
    return true, ""
  end
  local moved = false
  for i, happened in ipairs(revents) do
    local e = entries[i]
    local service = services[e.kind]
    if happened ~= 0 and service.live(e) then
      moved = true
      service.ready(e)
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
    local _, _ = pump(watching({ self }), POLL_NS)
  end
end

--- Ends what is left of the child and settles it, answering its Result.
--- A child still running is sent SIGTERM -- its group's too -- and
--- SIGKILL once TERM_GRACE_NS has passed, and its Result says
--- `timed_out`; what its group has left after the leader is gone is
--- ended the same way. What its pipes still hold is then drained, and
--- every descriptor of its own is closed. Nil and why when the child
--- cannot be signalled, does not exit after SIGKILL, or leaves its group
--- members after it: the Result is kept for a later call all the same.
---
--- Its waits go through the run in a task, shielded, for a cleanup does
--- not end with its task's cancel. In a `<close>` handler of a task
--- being killed, or a finalizer, no wait can yield, and they hold the
--- thread in [`sys.poll`]: the cleanup there must finish too.
local function end_child(self: Handle): Result | nil, string
  if self._result ~= nil then return self._result, "" end
  local status, trouble = exited(self)
  if status == nil and trouble ~= "" then return nil, trouble end
  local timed_out, killed = status == nil, false
  if timed_out then
    local sent, why = sys.kill(target(self), sys.SIGTERM)
    if not sent then
      -- The child may have exited between the last look and this signal.
      local gone, _ = exited(self)
      if gone == nil then return nil, why end
    end
    local deadline = now() + TERM_GRACE_NS
    while true do
      local gone, gone_trouble = exited(self)
      if gone ~= nil then break end
      if gone_trouble ~= "" then return nil, gone_trouble end
      local left = slice(deadline, { self })
      if left ~= nil then
        local _, _ = pump(watching({ self }), left)
      elseif killed then
        return refuse("the child was not reaped after SIGKILL")
      else
        -- Only a child that ignored TERM gets here; the group's
        -- stragglers, if the leader honored it, are ended below.
        local _, _ = sys.kill(target(self), sys.SIGKILL)
        killed, deadline = true, now() + KILL_REAP_NS
      end
    end
  end
  local cleared = true
  if self.process_group then
    local alive, _, errno = sys.kill(-self.pid, 0)
    cleared = not alive and errno == sys.ESRCH
    if not cleared and not killed then
      local _, _ = sys.kill(-self.pid, sys.SIGTERM)
      cleared = group_gone(self, now() + TERM_GRACE_NS)
    end
    if not cleared then
      local _, _ = sys.kill(-self.pid, sys.SIGKILL)
      cleared = group_gone(self, now() + KILL_REAP_NS)
    end
  end
  -- Clearing the group waits, through the run in a task, where another
  -- task may settle this handle meanwhile: its Result is the one.
  if self._result ~= nil then return self._result, "" end
  local final = self._status
  local r: Result = {
    ok = final.code == 0 and not timed_out,
    timed_out = timed_out,
    captured = {},
    truncated = false,
  }
  if final.code >= 0 then r.code = final.code end
  if final.signal >= 0 then r.signal = final.signal end
  end_input(self)
  close_fd(self._feed_fd)
  self._feed_fd = nil
  if self._streams then
    -- Anything still buffered in a pipe is there for the taking now;
    -- a writer that escaped the group can keep it open, so stop at the
    -- first round that finds nothing rather than wait for end of file.
    -- A streamed output is left open, and no fuller than its limit: its
    -- reader reads on from the pipe, and ends it (see [`pipe_reader`]).
    while true do
      local moved, _ = pump(watching({ self }), 0)
      if not moved then break end
    end
    for _, stream in ipairs(self._streams) do
      if not stream.streamed then
        end_stream(stream)
        r.captured[stream.child_fd] = text_of(self, stream)
        if stream.truncated then r.truncated = true end
      end
    end
    r.stdout = r.captured[1]
    r.stderr = r.captured[2]
  end
  self._result, self._closed = r, true
  if not cleared then
    return refuse("process group " .. tostring(self.pid) .. " still has members after SIGKILL")
  end
  return r, ""
end

local closed_reader <const> = "child: the reader is closed"
local closed_writer <const> = "child: the writer is closed"
local EXITED <const> = "child: the child has exited"

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

--- One read or drain owns its queues even while a sink or pipe wait yields.
local record Consumption
  pipes: {Pipe}
  discard: boolean
  reason: string
  metamethod __close: function(Consumption)
end

local consumption_mt: metatable<Consumption> = {
  __close = function(self: Consumption)
    for _, pipe in ipairs(self.pipes) do
      if self.discard then
        if pipe.failure == nil then pipe.failure = self.reason end
        end_stream(pipe)
        pipe.chunks, pipe.head, pipe.tail, pipe.size = {}, 1, 0, 0
      end
      pipe.consuming = false
    end
  end,
}

local function consume(pipes: {Pipe}): Consumption
  for _, pipe in ipairs(pipes) do
    if pipe.consuming then error("child: output is already being consumed", 3) end
  end
  local owner: Consumption = setmetatable({ pipes = pipes, discard = false,
    reason = "child: output sink did not complete" }, consumption_mt)
  for _, pipe in ipairs(pipes) do pipe.consuming = true end
  return owner
end

--- Takes only the queued prefix requested, shared by Reader and drain.
local function take_chunk(pipe: Pipe, want: integer): string
  local chunk = pipe.chunks[pipe.head]
  if #chunk <= want then
    pipe.chunks[pipe.head] = nil
    pipe.head = pipe.head + 1
    pipe.size = pipe.size - #chunk
    return chunk
  end
  pipe.chunks[pipe.head] = chunk:sub(want + 1)
  pipe.size = pipe.size - want
  return chunk:sub(1, want)
end

-- How an object of this module is made. A handle, a guard and the Reader
-- and Writer of a streamed pipe are each one table, whose methods live
-- once on a record's own table, reached through `__index`, with the state
-- in fields: no closure each. A Reader or a Writer is a record of its own
-- ([`PipeReader`], [`FeedWriter`]) implementing the interface it answers. A
-- handle and a guard are public records themselves, whose fields the
-- docs list, so their methods are assigned (`Handle.wait = function(self:
-- Handle, ...)`) to the fields the record declares, with the docs on
-- them: `function Handle:wait` would be listed as an undocumented
-- function beside the documented field. The note on how an object is made
-- in cosmic/stream.tl says why Teal limits how that is written.

--- The Reader of a child's streamed output: it takes what `pump` queued,
--- pumping every stream of the child while it waits.
local record PipeReader is Stream.Reader
  child: Handle
  pipe: Pipe
  closed: boolean
  --- Why a wait the child could not go on with ended, "" until one has:
  --- every later read answers it.
  failed: string
  --- Holds the pipe while a read waits; one per Reader, so a read costs no
  --- allocation.
  owner: Consumption
  read: function(PipeReader, max_bytes?: integer): string | nil, string
  close: function(PipeReader): boolean, string
end

local pipe_reader_mt: metatable<PipeReader> = { __index = PipeReader }

local function waiting_read(self: PipeReader, max_bytes?: integer): string | nil, string
  local child, pipe = self.child, self.pipe
  local _ownership <close> = self.owner
  pipe.consuming = true
  while pipe.size == 0 do
    if pipe.failure ~= nil then
      self.failed = pipe.failure
      return nil, self.failed
    end
    if pipe.fd == nil then return nil, "" end
    local why = interrupted(child)
    if why ~= "" then
      self.failed = why
      return nil, why
    end
    if child._status ~= nil then
      -- The child is gone: what it wrote is in the pipe already, and
      -- a round that finds nothing ready means only an escaped
      -- descendant holds it open, which this read does not wait for.
      local _, _ = pump(watching({ child }), 0)
      if pipe.size == 0 and pipe.fd ~= nil then
        pipe.reader_closed = true
        end_stream(pipe)
      end
    elseif overdue(child) then
      -- Ended as a wait would end it; its pipe is read on from there.
      local ended, trouble = end_child(child)
      if ended == nil and child._status == nil then
        self.failed = trouble
        return nil, trouble
      end
    else
      local left = slice(sooner(nil, child), { child })
      if left ~= nil then
        local _, cancelled = pump(watching({ child }), left, true, true)
        -- Not kept as `failed`: the task's end, not the stream's.
        if cancelled ~= "" then return nil, cancelled end
      end
    end
  end
  return take_chunk(pipe, max_bytes or CHUNK), ""
end

function PipeReader:read(max_bytes?: integer): string | nil, string
  if max_bytes ~= nil and max_bytes < 1 then error("child: read's max_bytes must be positive", 2) end
  local pipe = self.pipe
  if pipe.consuming then error("child: output is already being consumed", 2) end
  if self.failed ~= "" then return nil, self.failed end
  if self.closed then return nil, closed_reader end
  if pipe.size ~= 0 then return take_chunk(pipe, max_bytes or CHUNK), "" end
  return waiting_read(self, max_bytes)
end

function PipeReader:close(): boolean, string
  if self.closed then return true, "" end
  self.closed = true
  local pipe = self.pipe
  pipe.reader_closed = true
  -- The child's next write to it fails, as it would into `head`.
  end_stream(pipe)
  pipe.chunks, pipe.head, pipe.tail, pipe.size = {}, 1, 0, 0
  return true, ""
end

--- The Reader of `self`'s streamed output at `index`.
local function pipe_reader(self: Handle, index: integer): Stream.Reader
  local pipe = self._streams[index]
  local owner: Consumption = setmetatable({ pipes = { pipe }, discard = false }, consumption_mt)
  local r: PipeReader = setmetatable(
    { child = self, pipe = pipe, closed = false, failed = "", owner = owner }, pipe_reader_mt)
  return r
end

--- The Writer of a child's stdin stream: [`Stream.to_fd`] over the pipe,
--- whose waits for room pump the child's outputs meanwhile, so a child
--- that waits for its output to be read does not stall the write.
local record FeedWriter is Stream.Writer
  child: Handle
  --- The pipe's descriptor as this Writer was made with, to tell it
  --- from the one the handle holds once it has been closed.
  fd: integer
  closed: boolean
  into: Stream.Writer
  write: function(FeedWriter, data: string): boolean, string
  close: function(FeedWriter): boolean, string
  abort: function(FeedWriter): boolean, string
end

local feed_writer_mt: metatable<FeedWriter> = { __index = FeedWriter }

function FeedWriter:write(data: string): boolean, string
  if self.closed then return false, closed_writer end
  -- Only a settled child's stdin is closed from under its writer.
  if self.child._feed_fd ~= self.fd then return false, EXITED end
  return self.into:write(data)
end

function FeedWriter:close(): boolean, string
  self.closed = true
  local child, fd = self.child, self.fd
  if child._feed_fd == nil then return true, "" end
  child._feed_fd = nil
  Poll.closing(fd)
  local ok, trouble = sys.close(fd)
  if not ok then return false, trouble end
  return true, ""
end

function FeedWriter:abort(): boolean, string
  return self:close()
end

local function feed_writer(self: Handle): Stream.Writer
  local fd = self._feed_fd
  local w: FeedWriter = setmetatable({ child = self, fd = fd, closed = false }, feed_writer_mt)
  -- A closure, for [`Stream.FdOptions.wait`] is called with no Writer.
  local function room(_fd: integer, _events: integer, _left: integer | nil): boolean, string
    local why = interrupted(self)
    if why == "" and overdue(self) then
      local _, trouble = end_child(self)
      why = trouble
    end
    if why == "" and self._status ~= nil then why = EXITED end
    if why ~= "" then return false, why end
    local left = slice(sooner(nil, self), { self })
    if left ~= nil then
      local _, cancelled = pump(watching({ self }, self), left, true, true)
      if cancelled ~= "" then return false, cancelled end
    end
    -- Another task may have closed it meanwhile, by this writer's
    -- close or a settle, and its number be another file's by now.
    if self._feed_fd ~= fd then return false, w.closed and closed_writer or EXITED end
    return true, ""
  end
  w.into = Stream.to_fd(fd, { nonblocking = true, wait = room })
  return w
end

--- Closes every streamed output a settle left open for its reader,
--- which then reads what is queued and ends.
local function end_streamed(self: Handle)
  if not self._streams then return end
  for _, stream in ipairs(self._streams) do
    if stream.streamed then end_stream(stream) end
  end
end

--- [`end_child`], with a net under it: whatever raises in the ending (an
--- allocation refused, a wait that fails) must still leave no process
--- behind, so a raise is answered by SIGKILL to the child, its group
--- included, and a reap that holds the thread and cannot wait through
--- anything that raised. The Result is left for a later `close` or
--- collection to settle; the failure is answered as the reason.
local function end_or_kill(self: Handle): Result | nil, string
  local ok, r, why = pcall(end_child, self)
  if ok then
    if r == nil then return nil, why end
    return r, ""
  end
  local _, _ = sys.kill(target(self), sys.SIGKILL)
  for _ = 1, 100 do
    local status, _ = exited(self)
    if status ~= nil then break end
    local _, _ = sys.nanosleep(POLL_NS)
  end
  return nil, tostring(r)
end

local function drain(self: Handle, opts: DrainOptions): DrainResult
  if type(opts) ~= "table" or math.type(opts.timeout_ns) ~= "integer" or
      math.type(opts.max_bytes) ~= "integer" or opts.max_bytes < 1 then
    error("child: drain requires integer timeout_ns and positive max_bytes", 3)
  end
  Poll.checked_ns(opts.timeout_ns, "child", "timeout_ns", 3)
  local timeout_ns, max_bytes = opts.timeout_ns, opts.max_bytes
  local pipes: {Pipe} = {}
  local sinks: {Stream.Writer} = {}
  local stdout, stderr = false, false
  for _, pipe in ipairs(self._streams or {}) do
    if pipe.streamed then
      local sink: Stream.Writer
      if pipe.child_fd == 1 then sink = opts.stdout else sink = opts.stderr end
      if sink == nil then error("child: drain requires a sink for each streamed output", 3) end
      if type(sink.write) ~= "function" then error("child: drain requires Writers", 3) end
      if pipe.child_fd == 1 then stdout = true else stderr = true end
      pipes[#pipes + 1], sinks[#sinks + 1] = pipe, sink
    end
  end
  if #pipes == 0 or (opts.stdout ~= nil and not stdout) or (opts.stderr ~= nil and not stderr) then
    error("child: drain sinks must name streamed outputs", 3)
  end
  local owner <close> = consume(pipes)
  local bytes = 0
  local guard = active
  local stamp: integer
  local deadline = now() + timeout_ns
  local function result(kind: DrainKind, reason?: string): DrainResult
    return { kind = kind, bytes = bytes, reason = reason or "" }
  end
  local function control(): DrainResult | nil
    if self._explicit_close then return result("failed", "child: the handle is closed") end
    for _, pipe in ipairs(pipes) do
      if pipe.reader_closed then return result("failed", closed_reader) end
    end
    if guard ~= nil then
      if guard._closed then return result("failed", "child: the guard is closed") end
      local signal = guard:cancelled()
      if (stamp == nil and guard._fresh ~= 0) or (stamp ~= nil and guard._read ~= stamp) then
        return result("interrupted", cancelled_by(signal))
      end
      if stamp == nil then stamp = guard._read end
    end
    return nil
  end
  local function complete(): DrainResult | nil
    local eof = true
    for _, pipe in ipairs(pipes) do
      if pipe.size == 0 and pipe.failure ~= nil then return result("failed", pipe.failure) end
      if pipe.fd ~= nil or pipe.size ~= 0 then eof = false end
    end
    if eof then return result("eof") end
    if bytes == max_bytes then return result("limit") end
    return nil
  end
  local stopped = control() or complete()
  if stopped ~= nil then return stopped end
  if timeout_ns == 0 then
    local _, _ = pump(watching({ self }), 0, true, guard ~= nil)
  end
  while true do
    stopped = control() or complete()
    if stopped ~= nil then return stopped end
    if timeout_ns ~= 0 and now() >= deadline then return result("timeout") end
    local moved = false
    local first = self._drain_next or 1
    for offset = 0, #pipes - 1 do
      local index = (first + offset - 1) % #pipes + 1
      stopped = control() or complete()
      if stopped ~= nil then return stopped end
      if timeout_ns ~= 0 and now() >= deadline then return result("timeout") end
      local pipe = pipes[index]
      if pipe.size ~= 0 then
        local chunk = take_chunk(pipe, math.min(CHUNK, max_bytes - bytes))
        bytes = bytes + #chunk
        self._drain_next = index % #pipes + 1
        owner.discard = true
        local ok, why = sinks[index]:write(chunk)
        if not ok then
          owner.reason = why
          return result("failed", why)
        end
        owner.discard = false
        moved = true
      end
    end
    stopped = control() or complete()
    if stopped ~= nil then return stopped end
    if timeout_ns == 0 then return result("timeout") end
    if not moved then
      local _, why = exited(self)
      if why ~= "" then return result("failed", why) end
      local left = slice(deadline, { self })
      if left == nil then return result("timeout") end
      local _, cancelled = pump(watching({ self }), left, true, guard ~= nil)
      stopped = control()
      if stopped ~= nil then return stopped end
      if cancelled ~= "" then return result("failed", cancelled) end
    end
  end
end

--- An explicit close ends a drain even while group cleanup is waiting.
local function closing_outputs(self: Handle)
  self._explicit_close = true
  for _, pipe in ipairs(self._streams or {}) do
    if pipe.streamed and pipe.fd ~= nil then Poll.closing(pipe.fd) end
  end
end

Handle.try_wait = function(self: Handle): TryWait | nil, string
  if self._result then return { finished = true, result = self._result }, "" end
  local _, _ = pump(watching({ self }), 0)
  local status, trouble = exited(self)
  if status == nil then
    if trouble ~= "" then return nil, trouble end
    if not overdue(self) then return { finished = false }, "" end
  end
  local r, settle_trouble = end_child(self)
  if r == nil then return nil, settle_trouble end
  return { finished = true, result = r }, ""
end

Handle.stop = function(self: Handle, signal?: integer): boolean, string
  if self._closed then return false, "child: process already reaped" end
  local ok, trouble = sys.kill(target(self), signal or sys.SIGTERM)
  if not ok then return false, trouble end
  return true, ""
end

Handle.wait = function(self: Handle, timeout_ns?: integer): Result | nil, string
  Poll.checked_ns(timeout_ns, "child", "timeout_ns", 2)
  if self._result then return self._result, "" end
  if timeout_ns == nil and self._deadline == nil and active == nil and not self._streams and
      not self._input_fd and not through_run() then
    local status, trouble = exited(self, true)
    if not status then return nil, trouble end
    return end_child(self)
  end
  local deadline: integer
  if timeout_ns ~= nil then deadline = now() + timeout_ns end
  deadline = sooner(deadline, self)
  -- Services the child's pipes until it exits, `deadline` passes ("")
  -- or the wait cannot go on: a signal the innermost open guard
  -- caught, a task cancelled, a child that cannot be asked about.
  local why = ""
  while true do
    local status, trouble = exited(self)
    if status ~= nil then return end_child(self) end
    why = trouble
    if why ~= "" then break end
    if active ~= nil and active:cancelled() ~= 0 then
      why = cancelled_by(active:cancelled())
      break
    end
    local left = slice(deadline, { self })
    if left == nil then break end
    local _, stopped = pump(watching({ self }), left, true, true)
    if stopped ~= "" then
      why = stopped
      break
    end
  end
  local cancelled = active ~= nil and active:cancelled() or 0
  if cancelled ~= 0 then
    -- A wait the guard's signal ended leaves no child running. The
    -- signal may have landed after the deadline, so say so here.
    if why == "" then why = cancelled_by(cancelled) end
    local _, ended_trouble = end_child(self)
    if ended_trouble ~= "" then
      -- `why` names the module already.
      return nil, why .. "; " .. (ended_trouble:gsub("^child: ", ""))
    end
    return nil, why
  end
  if why ~= "" then return nil, why end
  return end_child(self)
end

Handle.close = function(self: Handle): boolean, string
  closing_outputs(self)
  if not self._closed then
    local r, trouble = end_child(self)
    if not r then return false, trouble end
  end
  end_streamed(self)
  return true, ""
end

Handle.drain = drain

local handle_mt: metatable<Handle> = {
  __index = Handle,
  __close = function(self: Handle)
    closing_outputs(self)
    if not self._closed then local _, _ = end_or_kill(self) end
    end_streamed(self)
  end,
  __gc = function(self: Handle)
    closing_outputs(self)
    if not self._closed then local _, _ = end_or_kill(self) end
    end_streamed(self)
  end,
}

--- A handle for `pid`, owning it until it settles.
local function make_handle(pid: integer, process_group: boolean, limit: integer,
    deadline: integer | nil): Handle
  local h: Handle = setmetatable({
    pid = pid, process_group = process_group, _closed = false, _exit_fd = -1, _limit = limit,
    _explicit_close = false, _drain_next = 1, _deadline = deadline,
  }, handle_mt)
  -- Owned only once it has its metatable, so the finalizer covers the child from then; a
  -- failure between the two leaves an unowned child with a finalizer, which waitpid still reaps.
  owned[pid] = true
  return h
end

--- Takes `stamp`, a stamp the core answered, as what `g` has read: a
--- stamp that moved since the last is a signal caught, for both what
--- `cancelled` and what `take` answer.
local function noted(g: Guard, stamp: integer)
  if stamp ~= g._read then
    local signal = stamp % raw.SIGNAL_STAMP_UNIT
    g._signal, g._fresh, g._read = signal, signal, stamp
  end
end

local function read_guard(self: Guard)
  if self._closed then return end
  noted(self, raw.child_signal_read(self == active))
end

Guard.cancelled = function(self: Guard): integer
  read_guard(self)
  return self._signal
end

Guard.take = function(self: Guard): integer
  read_guard(self)
  local signal = self._fresh
  self._fresh = 0
  return signal
end

Guard.wait = function(self: Guard, timeout_ns?: integer): integer, string
  if not Poll.in_task() then error("child: g:wait waits in a task of Poll.run", 2) end
  Poll.checked_ns(timeout_ns, "child", "timeout_ns", 2)
  local deadline: integer
  if timeout_ns ~= nil then deadline = now() + timeout_ns end
  while true do
    -- Asked before each wait and after each wake, never from the
    -- pipe's bytes: another task waiting on it may have drained it.
    local signal = self:take()
    if signal ~= 0 then return signal, "" end
    if self._closed then return 0, "child: the guard is closed" end
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
local function restore_guard(self: Guard): string, boolean, integer
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

Guard.close = function(self: Guard): boolean, string
  if self._closed then
    if self._trouble ~= "" then return false, self._trouble end
    return true, ""
  end
  local trouble, last, owing = restore_guard(self)
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

Guard.release = function(self: Guard): integer | nil, string
  if self._closed then
    if self._trouble ~= "" then return nil, self._trouble end
    return self._signal, ""
  end
  local trouble, last, owing = restore_guard(self)
  if trouble ~= "" then return nil, trouble end
  if last and self._signal == 0 and owing ~= 0 then
    local _, _ = sys.kill(sys.getpid(), owing)
  end
  return self._signal, ""
end

local guard_mt: metatable<Guard> = {
  __index = Guard,
  __close = function(self: Guard)
    local _, _ = self:close()
  end,
}

--- A guard not yet open: [`opened`] opens it.
local function make_guard(): Guard
  local g: Guard = setmetatable({
    _read = 0, _signal = 0, _fresh = 0, _closed = false, _trouble = "",
  }, guard_mt)
  return g
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
  type Credentials = Credentials
  type Sandbox = Sandbox
  type Unveil = Unveil
  type TryWait = TryWait
  type DrainOptions = DrainOptions
  type DrainKind = DrainKind
  type DrainResult = DrainResult
  type Handle = Handle
  type Guard = Guard
end

--- Holds SIGINT and SIGTERM for this process while it supervises
--- children, so it can end them before it is ended itself. Until the
--- guard closes, either signal is caught rather than acted on:
--- `g:cancelled()` answers the last one delivered, 0 until one is.
--- Only `h:wait` reads the guard -- it ends its child and answers
--- "child: cancelled by signal N" once a signal is caught -- and a stream's
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
  if name == "stdin" and value == "pipe" then
    error("child: stdin = \"pipe\" was removed: use \"stream\" and write through the handle's " ..
      "stdin_stream, closing it for end of file, or `input` for bytes known in advance", 4)
  end
  local allowed: {string} = {}
  for word in pairs(words) do allowed[#allowed + 1] = "'" .. word .. "'" end
  table.sort(allowed)
  error("child: " .. name .. " must be a file descriptor or one of " .. table.concat(allowed, ", "), 4)
end

local STDIN_WORDS <const> = { inherit = true, null = true, stream = true }
local STDOUT_WORDS <const> = { inherit = true, null = true, capture = true, stream = true }
local STDERR_WORDS <const> = {
  inherit = true, null = true, capture = true, stdout = true, stream = true,
}
local FD_WORDS <const> = { capture = true }

local function without_nul(value: string, name: string)
  if value:find("\0", 1, true) then error("child: " .. name .. " contains a NUL byte", 4) end
end

local function validate(argv: {string}, opts: Options)
  if #argv == 0 then error("child: argv is empty", 3) end
  for i, value in ipairs(argv) do
    if type(value) ~= "string" then error("child: argv[" .. tostring(i) .. "] must be a string", 3) end
    without_nul(value, "argv[" .. tostring(i) .. "]")
  end
  if opts.cwd ~= nil then without_nul(opts.cwd, "cwd") end
  if opts.env ~= nil then
    for name, value in pairs(opts.env) do
      if type(name) ~= "string" or name == "" or name:find("=", 1, true) then
        error("child: environment name is empty, non-string, or contains '='", 3)
      end
      if type(value) ~= "string" then error("child: environment value must be a string", 3) end
      without_nul(name, "environment name")
      without_nul(value, "environment value")
    end
  end
  local stdin = descriptor(opts.stdin, "stdin", STDIN_WORDS)
  descriptor(opts.stdout, "stdout", STDOUT_WORDS)
  descriptor(opts.stderr, "stderr", STDERR_WORDS)
  if opts.input ~= nil then
    if type(opts.input) ~= "string" then error("child: input must be a string", 3) end
    if stdin ~= "inherit" then error("child: input and a stdin of its own exclude each other", 3) end
  end
  if opts.fds ~= nil then
    for number, value in pairs(opts.fds) do
      if not (number is integer) or number < 3 or number > 255 then
        error("child: fds keys are child descriptors from 3 to 255", 3)
      end
      descriptor(value, "fds[" .. tostring(number) .. "]", FD_WORDS)
    end
  end
  if opts.capture_limit ~= nil and (opts.capture_limit < 1 or opts.capture_limit > INT_MAX) then
    error("child: capture_limit is out of range", 3)
  end
  Poll.checked_ns(opts.timeout_ns, "child", "timeout_ns", 3)
  if opts.credentials ~= nil then
    local user, group = opts.credentials.user, opts.credentials.group
    if not (user is integer) or not (group is integer) or
      user < 1 or user > 4294967294 or group < 1 or group > 4294967294 then
      error("child: credentials need integer user and group from 1 to 4294967294", 3)
    end
    local sandbox = opts.sandbox
    if sandbox ~= nil and (sandbox.unveil ~= nil or sandbox.offline == true or
      sandbox.user ~= nil or sandbox.group ~= nil) then
      error("child: credentials exclude sandbox unveil, offline, user and group", 3)
    end
  end
  if opts.sandbox ~= nil and opts.sandbox.noexec_scratch ~= nil then
    if type(opts.sandbox.noexec_scratch) ~= "boolean" then
      error("child: noexec_scratch must be a boolean", 3)
    end
    if opts.sandbox.noexec_scratch and opts.sandbox.unveil == nil then
      error("child: noexec_scratch requires unveil", 3)
    end
  end
  if opts.sandbox ~= nil and opts.sandbox.unveil ~= nil then
    local unveil = opts.sandbox.unveil
    for _, list in ipairs({ unveil.reads or {}, unveil.writes or {} }) do
      for _, path in ipairs(list) do
        without_nul(path, "an unveiled path")
        if path:sub(1, 1) ~= "/" then error("child: an unveiled path must be absolute", 3) end
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
    streamed = streamed or false, head = 1, tail = 0, reader_closed = false, consuming = false,
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
  if opts.input ~= nil or stdin == "stream" then
    local ends, trouble = raw.pipe()
    if ends == nil then return nil, trouble end
    wiring.child_ends[#wiring.child_ends + 1] = ends.reader
    wiring.ours[#wiring.ours + 1] = ends.writer
    slots[0] = ends.reader
    -- A write to a child that has gone fails with EPIPE rather than
    -- ending this process, whoever writes it: this module feeding
    -- `input`, or the caller writing to `h.stdin_stream`.
    local ignored, ignore_trouble = raw.ignore_sigpipe()
    if not ignored then return nil, ignore_trouble end
    local nonblocking, nonblocking_trouble = sys.set_nonblocking(ends.writer, true)
    if not nonblocking then return nil, nonblocking_trouble end
    if opts.input ~= nil then
      wiring.input_fd = ends.writer
    else
      wiring.feed_fd = ends.writer
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
    return refuse("start: " .. wire_trouble)
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
    sandbox = { offline = opts.sandbox.offline == true,
      noexec_scratch = opts.sandbox.noexec_scratch == true, user = opts.sandbox.user,
      group = opts.sandbox.group }
    if given ~= nil then
      sandbox.unveil = { reads = given.reads or {}, writes = given.writes or {}, at = given.at }
    end
  end
  local credentials: raw_process.Credentials
  if opts.credentials ~= nil then
    credentials = { user = opts.credentials.user, group = opts.credentials.group }
  end
  local pid, trouble, errno = raw.spawn(argv[1], argv, opts.env, opts.cwd,
    slots[0], slots[1], slots[2], grouped, extra, sandbox, credentials)
  unwire(wiring, pid ~= nil)
  if not pid then
    if errno == sys.ENOENT and unfound_name(argv[1], opts.cwd) then
      trouble = trouble .. ": " .. string.format("%q", argv[1]) ..
        " is run as a path, with no PATH search; Proc.find(" ..
        string.format("%q", argv[1]) .. ") answers where a shell would find it"
    elseif errno == sys.EINVAL or errno == sys.EMFILE then
      trouble = trouble .. descriptor_limit_hint(slots)
    end
    return refuse("start: " .. trouble)
  end
  local deadline: integer
  if opts.timeout_ns ~= nil then deadline = now() + opts.timeout_ns end
  local h = make_handle(pid, grouped, opts.capture_limit or DEFAULT_CAPTURE_LIMIT, deadline)
  if #wiring.streams > 0 then h._streams = wiring.streams end
  if wiring.input_fd ~= nil then
    h._input_fd, h._input, h._input_at = wiring.input_fd, opts.input, 0
    if #opts.input == 0 then end_input(h) end
  end
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
--- child and its group; `wait(timeout)` does the same on expiry, and so
--- does a wait once the child's `timeout_ns`, counted from here, has
--- passed. Nothing ends it for `timeout_ns` while nothing waits on it
--- ([`Options.timeout_ns`]).
function Child.start(argv: {string}, opts?: Options): Handle | nil, string
  opts = opts or {}
  validate(argv, opts)
  return start(argv, opts)
end

--- Waits for the first of several handles to finish, servicing every
--- one's streams meanwhile, and returns it settled: its [`wait()`] answers
--- at once. Nil and [`Poll.TIMEOUT`] when `timeout_ns` passes first --
--- no handle finished, and nothing failed -- and the handles are left
--- running: a timeout is `done == nil and trouble == Poll.TIMEOUT`, and
--- any other trouble beside a nil `done` is a failure. A handle whose
--- own [`Options.timeout_ns`] passes first is ended, as an expired
--- [`Handle.wait`] ends it -- which waits for it to go, so the call
--- can outlast its own `timeout_ns` by the grace period -- and is
--- answered settled, its Result `timed_out`. In a task of
--- [`Poll.run`] that is cancelled, it answers nil and
--- [`Poll.CANCELLED`], the handles left running too. A `timeout_ns`
--- below 0 or past [`Poll.MOST_NS`] raises.
function Child.wait_any(handles: {Handle}, timeout_ns?: integer): Handle | nil, string
  -- TODO: carry a settled group's lingering members on Child.Result, a
  -- field beside the exit status, and answer the handle with "" here:
  -- build/test.tl reads the trouble beside the handle's result today, and
  -- build.contracts exempts this pair from the error-slot rules until then.
  if #handles == 0 then error("child: no handles to wait for", 2) end
  Poll.checked_ns(timeout_ns, "child", "timeout_ns", 2)
  local deadline = timeout_ns ~= nil and now() + timeout_ns or nil
  while true do
    for _, h in ipairs(handles) do
      if h._result then return h, "" end
      local status, trouble = exited(h)
      if status ~= nil then
        local _, settle_trouble = end_child(h)
        return h, settle_trouble
      end
      if trouble ~= "" then return nil, trouble end
      if overdue(h) then
        local _, settle_trouble = end_child(h)
        return h, settle_trouble
      end
    end
    local soonest = deadline
    for _, h in ipairs(handles) do soonest = sooner(soonest, h) end
    local left = slice(soonest, handles)
    if left ~= nil then
      local _, cancelled = pump(watching(handles), left, true)
      if cancelled ~= "" then return nil, cancelled end
    elseif deadline ~= nil and now() >= deadline then
      return nil, Poll.TIMEOUT
    end
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
--- then answers nil and "child: cancelled by signal N". A run made while the
--- caller holds a [`Child.guard`] holds one inside it: a signal the
--- caller's guard caught before the run began does not end it, and one
--- that ends it is left to the caller's guard rather than delivered.
--- It also answers nil and why when the child cannot be started, and
--- nil and "child: signal guard: ..." when its guard cannot be opened.
--- In a task of [`Poll.run`] that is cancelled, it ends the child, as a
--- timeout would, and answers nil and [`Poll.CANCELLED`].
function Child.run(argv: {string}, opts?: Options): Result | nil, string
  opts = opts or {}
  validate(argv, opts)
  if opts.stdin == "stream" or opts.stdout == "stream" or opts.stderr == "stream" then
    error("child: a \"stream\" is read or written while the child runs: use Child.start", 2)
  end
  local held, guard_trouble = opened()
  if held == nil then return refuse("signal guard: " .. guard_trouble) end
  -- Closed after the child is ended, as the run is left: the child is
  -- ended before the guard gives back the signals.
  local guard <close>: Guard = held
  local started, wait_trouble = start(argv, opts)
  local r: Result | nil
  local cleanup_trouble: string
  if started ~= nil then
    -- Ends the child where the run is left by a raise, or a task's kill.
    local _ending <close> = started
    -- Bounded by the deadline `start` gave it from `opts.timeout_ns`.
    r, wait_trouble = started:wait()
    if not started._closed and (guard:cancelled() ~= 0 or r == nil) then
      local _, failure = end_or_kill(started)
      if failure ~= "" then cleanup_trouble = failure end
    end
  end
  -- Closing re-delivers a caught signal, after the cleanup above.
  local restored, restore_trouble = guard:close()
  if not restored then return refuse("signal restore: " .. restore_trouble) end
  local cancellation = guard:cancelled()
  if cancellation ~= 0 then
    return nil, cleanup_trouble or wait_trouble or cancelled_by(cancellation)
  end
  if cleanup_trouble then return nil, cleanup_trouble end
  if r then return r, "" end
  return nil, wait_trouble
end

return Child
