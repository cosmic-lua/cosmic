--- The pty relay `cosmic sandbox` runs a program through when one of its
--- own standard streams is a terminal: the program is given a pty of its
--- own for each stream that is, never the caller's terminal, which a
--- program holding it could write control sequences to or push input
--- into, and this loop copies between the two. A stream that is no
--- terminal -- a pipe or a file -- is the program's as it is, untouched
--- and unfiltered, so `cosmic sandbox -- tar c . > x.tar`, `2> err` and
--- `| grep` write the bytes the program wrote.
---
--- The caller's keys, where its stdin is a terminal, go to the pty's
--- master as they are: they are the user's own input, and the pty is then
--- the program's stdin and its controlling terminal. What the program
--- writes to a terminal stream goes through a [`build.term_filter`] on its
--- way to the caller's terminal -- its stdout's, else its stderr's, else,
--- where only stdin is a terminal and the pty carries nothing but the
--- echo of what is typed, its stdin's -- so it reaches the terminal as
--- text and the few sequences a screen is drawn with, and no more. Both
--- output streams being terminals, they share the pty and so the filter
--- and the stdout's terminal. The filter answers the program's terminal
--- queries itself, and the answers are written to the master as the
--- terminal's input.
---
--- THE CALLER'S TERMINAL is, where stdin is one, saved, put in raw mode
--- for the run and restored on every way out: the program's exit, a
--- failure, a raise and a signal this process catches. First the
--- saved termios is put back, then the sequences that undo what the filter
--- let the program set (attributes, scroll region, hidden cursor,
--- alternate screen and the rest of the private modes) are written for as
--- long as the terminal takes them, `RESET_MS` at most, so a terminal that
--- stopped taking output cannot keep it raw; nothing is flushed with `tcflush` -- see the TODO in `restore`. A
--- process ended by SIGKILL restores nothing, as with any program that
--- sets a terminal raw.
---
--- THE WINDOW SIZE is the terminal's, set on the pty before the program
--- starts and again whenever it is seen to change.
---
--- SIGNALS: SIGINT and SIGTERM sent to this process are caught by a
--- [`Child.guard`] and passed to the program's process group, and
--- delivered to this process again once the program has ended and the
--- terminal is restored, as [`Child.run`] does; the terminal's own keys
--- are not signals here, since raw mode hands ^C to the program as a byte
--- and the pty's line discipline raises its SIGINT in the program's
--- session. SIGHUP is not caught: when the caller's terminal hangs up,
--- this process dies of it by default, its pty master closes with it, and
--- the kernel hangs up the program's session. The run's end is the
--- program's: this returns what [`Child.run`] does, its [`Child.Result`],
--- and the verb exits with the program's status.
---
--- A LINE TO SHOW the caller, from the descriptor [`Terminal.notes`] names,
--- goes to the caller's stderr beside the program's output, which the
--- filter does not see: the sandbox relay writes one for each connection
--- it allows or refuses, with the remedy a refusal needs, and it may not
--- hold the caller's terminal itself. They are the relay's, with every
--- control byte already shown as "?".
---
--- The loop waits in [`sys.poll`] at most `TICK_MS` at a time, which is
--- what every check that no descriptor announces is made at: the
--- program's exit, a signal the guard caught and the caller's window.
--- THE CALLER'S OUTPUT is non-blocking for the run (the open file's mode
--- is put back as it was found, for it is shared with the caller's shell):
--- what the program wrote and the notes are queued, at most `MOST_QUEUED`
--- bytes, and written as the terminal takes them, in order. Above that
--- nothing more is read from the program's pty or the notes pipe, so a
--- terminal that stops taking output (flow control) makes the program wait
--- on its own pty and leaves the loop serving signals, the program's exit
--- and the window. After the program has ended, what is queued is written
--- for as long as the terminal makes progress, `STALL_MS` at most, and
--- dropped past that or on a signal.

local Child = require("cosmic.child")
local sys = require("cosmic.sys")
local TermFilter = require("build.term_filter")

--- How long a wait for a descriptor may last before the loop looks at
--- what none announces.
local TICK_MS <const> = 20
--- The most bytes read from either side at a time.
local CHUNK <const> = 65536
--- The most bytes held for the master (keys and answers): reading the
--- caller's keys stops above it, and an answer to a query is dropped
--- instead of held, so a program that never reads its input and floods
--- queries holds no more than this.
local MOST_PENDING <const> = 65536
--- The most bytes read from the master after the program has exited, for
--- a program's last words, however much a process that kept the pty open
--- goes on writing.
local MOST_AFTER_EXIT <const> = 1024 * 1024
--- The most bytes queued for the caller's terminal before nothing more is
--- read for it.
local MOST_QUEUED <const> = 1024 * 1024
--- How long, once the program has ended, the queue may wait on a terminal
--- that takes nothing before what is left is dropped.
local STALL_MS <const> = 1000
--- How long the sequences that undo the program's terminal modes are
--- offered to a terminal that takes nothing.
local RESET_MS <const> = 200

--- The caller's own standard streams, as descriptors.
local record Terminal
  --- The caller's stdin, 0 by default.
  input: integer
  --- The caller's stdout, 1 by default.
  output: integer
  --- The caller's stderr, 2 by default.
  error: integer
  --- The read end of a non-blocking pipe whose bytes are lines to show the caller on
  --- `error`, beside the program's output and in order with it (nil for
  --- none): the sandbox relay's decision lines, whose process may not hold
  --- the caller's terminal as its standard error. Each line ends in CR and
  --- LF there, for the terminal is raw where its input is a terminal, and
  --- is written whole, between the program's writes, with the bytes a
  --- terminal could act on shown as "?" ([`TermRelay.note_lines`]).
  notes: integer
end

local record TermRelay
  --- The caller's standard streams.
  type Terminal = Terminal
  --- Runs `argv` as [`Child.start_on_pty`] starts it, with `opts`, on a
  --- pty for each of `terminal`'s streams (this process's own when nil)
  --- that is a terminal, and answers its [`Child.Result`] once it has
  --- ended, as [`Child.run`] does; nil and why where the relay cannot be
  --- set up (none of the streams a terminal, no pty, or the start failed). Raises as
  --- [`Child.start_on_pty`] does for `opts`.
  run: function(argv: {string}, opts: Child.Options, terminal?: Terminal): Child.Result | nil, string
  --- The text to write to the caller's terminal for the bytes `data` of a
  --- notes pipe that follow `held` (what an earlier call kept), and what to
  --- keep: the whole lines among them, each ending in CR LF, and the rest.
  --- Every byte but a newline that a terminal could act on, and every byte
  --- from 0x7f up, is shown as "?": the pipe carries the relay's whole
  --- standard error, which is not all lines it chose. A tail that grows
  --- past a line a screen holds is written as a line of its own.
  note_lines: function(held: string, data: string): TermRelay.Notes
  --- What [`note_lines`] answers.
  record Notes
    --- The text to write, ending in CR LF where it is not empty.
    text: string
    --- What to keep for the next call: a line's beginning.
    tail: string
  end
end

--- The longest line kept waiting for its newline.
local MOST_NOTE <const> = 8192

function TermRelay.note_lines(held: string, data: string): TermRelay.Notes
  local text = held .. data
  local last = text:match(".*()\n")
  local whole, tail: string, string
  if last ~= nil then
    whole, tail = text:sub(1, last - 1), text:sub(last + 1)
  elseif #text > MOST_NOTE then
    whole, tail = text, ""
  else
    return { text = "", tail = text }
  end
  local shown = whole:gsub("[%z\1-\9\11-\31\127-\255]", "?"):gsub("\n", "\r\n")
  return { text = shown .. "\r\n", tail = tail }
end

--- The pty's slave, which the relay holds until it has read all the program
--- wrote: macOS drops what the master has not read when the last slave
--- descriptor closes.
local record Slave
  metamethod __close: function(Slave)
  fd: integer
end

local slave_mt: metatable<Slave> = {
  __close = function(self: Slave)
    local _, _ = sys.close(self.fd)
  end,
}

--- What `run` puts back when it ends, however it does: held in a
--- `<close>` variable, from the pty's start on.
local record Restoring
  metamethod __close: function(Restoring)
  input: integer
  output: integer
  --- The pty's master, closed last.
  master: integer
  --- The descriptors of the caller's output that `run` made non-blocking,
  --- which are put back to blocking.
  made_nonblocking: {integer}
  --- The caller's termios as it was, or nil until `run` has put the
  --- terminal in raw mode.
  saved: string | nil
  filter: TermFilter.Filter
end

--- Writes `data` to the non-blocking `fd`, waiting for room at most `limit_ms`
--- in all: how much was written.
local function write_within(fd: integer, data: string, limit_ms: integer): integer
  local at = 1
  local waited = 0
  while at <= #data do
    local count, _, errno = sys.write(fd, data:sub(at))
    if count ~= nil then
      at = at + count
    elseif errno == sys.EAGAIN then
      if waited >= limit_ms then break end
      local _, _ = sys.poll({ fd }, { sys.POLLOUT }, TICK_MS)
      waited = waited + TICK_MS
    elseif errno ~= sys.EINTR then
      break
    end
  end
  return at - 1
end

local restoring_mt: metatable<Restoring> = {
  __close = function(self: Restoring)
    -- The termios first, which waits for nothing; the resets after, for
    -- as long as the terminal takes them.
    if self.saved ~= nil then
      local _, _ = sys.tcsetattr(self.input, self.saved)
      self.saved = nil
    end
    local resets = self.filter:restore()
    if resets ~= "" then
      local _ = write_within(self.output, resets, RESET_MS)
    end
    for _, fd in ipairs(self.made_nonblocking) do
      local _, _ = sys.set_nonblocking(fd, false)
    end
    local _, _ = sys.close(self.master)
    -- TODO: discard the caller's typed-ahead input here, once
    -- cosmic.sys.tcflush can name the input queue alone: the call it has
    -- discards the output queue too, which can still hold the program's
    -- last bytes on a slow terminal, so none is made.
  end,
}

--- The size of `fd`'s window, or -1 and -1.
local function window(fd: integer): integer, integer
  local size, _ = sys.winsize(fd)
  if size == nil then return -1, -1 end
  return size.rows, size.columns
end

function TermRelay.run(argv: {string}, opts: Child.Options, terminal?: Terminal): Child.Result | nil, string
  local input = terminal ~= nil and terminal.input or 0
  local output = terminal ~= nil and terminal.output or 1
  local errors = terminal ~= nil and terminal.error or 2
  local notes = terminal ~= nil and terminal.notes or nil
  local streams: {integer} = {}
  for number, fd in ipairs({ input, output, errors }) do
    if sys.isatty(fd) then streams[#streams + 1] = number - 1 end
  end
  if #streams == 0 then
    return nil, "terminal: none of this process's standard streams is a terminal"
  end
  local keys = sys.isatty(input)
  -- Where the program's output goes: the terminal it was written for, and
  -- where only stdin is one, whose echo the pty carries.
  local shown = input
  if sys.isatty(errors) then shown = errors end
  if sys.isatty(output) then shown = output end
  local saved: string | nil
  if keys then
    local state, saved_why = sys.tcgetattr(input)
    if state == nil then return nil, "terminal: " .. saved_why end
    saved = state
  end
  local rows, columns = window(shown)
  local pty: Child.PtyOptions = { streams = streams, keep_slave = true }
  if rows >= 0 then pty.rows, pty.columns = rows, columns end
  -- Held before the program starts, and closed after it has ended, so a
  -- signal that comes between never finds it unguarded.
  local opened, guard_why = Child.guard()
  if opened == nil then return nil, "terminal: " .. guard_why end
  local guard <close> = opened
  local started, start_why = Child.start_on_pty(argv, opts, pty)
  if started == nil then return nil, start_why end
  local master = started.master
  local _slave <close>: Slave = setmetatable({ fd = started.slave }, slave_mt)
  local filter = TermFilter.new()
  local restoring <close>: Restoring = setmetatable({
    input = input, output = shown, master = master, saved = nil, filter = filter,
    made_nonblocking = {},
  }, restoring_mt)
  local running <close> = started.child
  local nonblocking, nonblocking_why = sys.set_nonblocking(master, true)
  if not nonblocking then return nil, "terminal: " .. nonblocking_why end
  -- The caller's output belongs to an open file shared with its shell and
  -- every process beside it: its mode is put back as found (`restoring`),
  -- and only a descriptor found blocking is touched.
  local outputs: {integer} = { shown }
  if notes ~= nil and errors ~= shown then outputs[2] = errors end
  local found: {boolean} = {}
  for number, fd in ipairs(outputs) do
    local status, status_why = sys.fd_status(fd)
    if status == nil then return nil, "terminal: " .. status_why end
    found[number] = status & sys.O_NONBLOCK ~= 0
  end
  for number, fd in ipairs(outputs) do
    if not found[number] then
      local set, set_why = sys.set_nonblocking(fd, true)
      if not set then return nil, "terminal: " .. set_why end
      restoring.made_nonblocking[#restoring.made_nonblocking + 1] = fd
    end
  end
  if keys then
    local raw, raw_why = sys.tcraw(input)
    if not raw then return nil, "terminal: " .. raw_why end
    restoring.saved = saved
  end

  -- TODO: wake on SIGWINCH and catch SIGHUP, once Child.guard (or a
  -- cosmic.sys binding) can hold signals beyond SIGINT and SIGTERM: the
  -- caller's window is looked at every TICK_MS instead of when it changes,
  -- and a SIGHUP sent to this process (a hangup of its terminal needs no
  -- handler) ends it with the terminal still raw.
  local pending = ""
  local keys_open = keys
  local master_open = true
  local signals = 0
  local seen_rows, seen_columns = window(shown)
  local result: Child.Result
  local failure: string
  -- Where only stdin is a terminal, a write that fails (a terminal open
  -- for reading alone) loses an echo, and ends nothing.
  local echo_only = shown == input and not sys.isatty(output) and not sys.isatty(errors)

  -- What is to be shown the caller, in the order it came: the program's
  -- output (`fatal`: a failing terminal ends the run) and the notes.
  local record Queued
    fd: integer
    data: string
    fatal: boolean
  end
  local queue: {Queued} = {}
  local queued = 0

  --- Writes what the caller's terminal takes of the queue, without waiting.
  --- A write that fails drops its bytes, and ends the run where it was the
  --- program's output and not an echo.
  local function flush_queue(): integer
    local written = 0
    while queue[1] ~= nil do
      local item = queue[1]
      local count, why, errno = sys.write(item.fd, item.data)
      if count ~= nil then
        written = written + count
        queued = queued - count
        if count < #item.data then
          item.data = item.data:sub(count + 1)
          break
        end
        table.remove(queue, 1)
      elseif errno == sys.EAGAIN then
        break
      elseif errno ~= sys.EINTR then
        queued = queued - #item.data
        table.remove(queue, 1)
        if item.fatal and not echo_only then
          failure = "terminal: writing the program's output: " .. why
          break
        end
      end
    end
    return written
  end

  local function enqueue(fd: integer, data: string, fatal: boolean)
    queue[#queue + 1] = { fd = fd, data = data, fatal = fatal }
    queued = queued + #data
    local _ = flush_queue()
  end

  --- Writes what the master will take of `pending`.
  local function flush_pending(): boolean
    local count, _, errno = sys.write(master, pending)
    if count ~= nil then
      pending = pending:sub(count + 1)
    elseif errno ~= sys.EAGAIN and errno ~= sys.EINTR then
      -- A master that fails is a program that has gone: its exit says so.
      pending = ""
      master_open = false
      return false
    end
    return true
  end

  --- Reads what the program wrote and passes on what the filter lets
  --- through: how many bytes it read, 0 where there were none yet, and -1
  --- once there are none for good (or the caller's output failed).
  local function relay_output(): integer
    local data, _, errno = sys.read(master, CHUNK)
    if data == nil then
      -- EAGAIN: nothing yet. Any other failure (EIO on Linux) is the
      -- last slave descriptor closed.
      if errno == sys.EAGAIN or errno == sys.EINTR then return 0 end
      master_open = false
      return -1
    elseif data == "" then
      master_open = false
      return -1
    end
    local passed, answers = filter:feed(data)
    if #answers > 0 and #pending + #answers <= MOST_PENDING then
      pending = pending .. answers
    end
    if passed ~= "" then
      enqueue(shown, passed, true)
      if failure ~= nil then return -1 end
    end
    return #data
  end

  --- Shows the caller what the notes pipe holds, as lines: how many bytes
  --- it read, 0 where there were none yet, and -1 once there are none for
  --- good. A write to the caller that fails loses the line and ends nothing.
  local notes_open = notes ~= nil
  local note_tail = ""
  local function relay_notes(): integer
    if notes == nil then return -1 end
    local data, _, errno = sys.read(notes, CHUNK)
    if data == nil then
      if errno == sys.EAGAIN or errno == sys.EINTR then return 0 end
      notes_open = false
      return -1
    end
    if data == "" then
      notes_open = false
      return -1
    end
    local lines = TermRelay.note_lines(note_tail, data)
    note_tail = lines.tail
    if lines.text ~= "" then enqueue(errors, lines.text, false) end
    return #data
  end

  while failure == nil do
    local signal = guard:take()
    if signal ~= 0 then
      -- The first is passed on, as a signal sent to the program itself;
      -- a second ends it, as a run's own guard would.
      signals = signals + 1
      if signals == 1 then
        local _, _ = running:stop(signal)
      else
        local _, _ = running:close()
      end
    end
    local now_rows, now_columns = window(shown)
    if now_rows ~= seen_rows or now_columns ~= seen_columns then
      seen_rows, seen_columns = now_rows, now_columns
      if now_rows >= 0 then
        local _, _ = sys.setwinsize(master, now_rows, now_columns)
      end
    end
    local status, why = running:try_wait()
    if status == nil then
      failure = "terminal: " .. why
      break
    elseif status.finished then
      result = status.result
      break
    end
    local keys_fd = keys_open and #pending < MOST_PENDING and input or -1
    -- Nothing is read for a terminal that has a full queue of output
    -- waiting: the program waits on its pty instead.
    local room = queued < MOST_QUEUED
    local master_events = (master_open and room and sys.POLLIN or 0) | (#pending > 0 and sys.POLLOUT or 0)
    local master_fd = master_events ~= 0 and master or -1
    local notes_fd = notes_open and room and notes or -1
    local out_fd = queue[1] ~= nil and queue[1].fd or -1
    local ready, poll_why = sys.poll({ keys_fd, master_fd, notes_fd, out_fd },
      { sys.POLLIN, master_events, sys.POLLIN, sys.POLLOUT }, TICK_MS)
    if ready == nil then
      failure = "terminal: waiting: " .. poll_why
      break
    end
    if ready[2] ~= 0 then
      if ready[2] & sys.POLLOUT ~= 0 and #pending > 0 then
        local _ = flush_pending()
      end
      if master_open and room and ready[2] & (sys.POLLIN | sys.POLLHUP | sys.POLLERR) ~= 0 then
        local _ = relay_output()
      end
    end
    if ready[3] ~= 0 then
      local _ = relay_notes()
    end
    if ready[4] ~= 0 then
      local _ = flush_queue()
    end
    if ready[1] ~= 0 then
      local typed, _, errno = sys.read(input, CHUNK)
      if typed ~= nil and typed ~= "" then
        pending = pending .. typed
        local _ = flush_pending()
      elseif typed == "" or (errno ~= sys.EAGAIN and errno ~= sys.EINTR) then
        -- The caller's terminal has gone: hang the program up as its own
        -- terminal's hangup would, and wait for it to go.
        keys_open = false
        local _, _ = running:stop(sys.SIGHUP)
      end
    end
  end
  -- The queue is written once the program has ended, and what the program
  -- wrote last and the notes after it are read first. A terminal that
  -- takes nothing for `STALL_MS`, or a signal, drops what is left.
  local function settle(drain: boolean)
    local out_budget = drain and result ~= nil and master_open and MOST_AFTER_EXIT or 0
    -- The program is settled, and its relay ended with it: what it wrote
    -- last is in the notes pipe, which the caller's end of keeps open.
    local notes_budget = drain and result ~= nil and notes_open and MOST_AFTER_EXIT or 0
    local stalled = 0
    while true do
      if guard:take() ~= 0 then break end
      if failure == nil and queued < MOST_QUEUED then
        if out_budget > 0 then
          local count = relay_output()
          out_budget = count > 0 and out_budget - count or 0
        elseif notes_budget > 0 then
          local count = relay_notes()
          notes_budget = count > 0 and notes_budget - count or 0
        end
      end
      local reading = out_budget > 0 or notes_budget > 0
      if queue[1] == nil and not reading then break end
      if failure ~= nil and queue[1] == nil then break end
      if flush_queue() > 0 then
        stalled = 0
      elseif queue[1] ~= nil and (queued >= MOST_QUEUED or not reading) then
        if stalled >= STALL_MS then break end
        local _, _ = sys.poll({ queue[1].fd }, { sys.POLLOUT }, TICK_MS)
        stalled = stalled + TICK_MS
      end
    end
    queue = {}
    queued = 0
  end
  settle(true)
  if note_tail ~= "" then
    -- A last line the relay did not end.
    enqueue(errors, TermRelay.note_lines(note_tail, "\n").text, false)
    settle(false)
  end
  if failure ~= nil then return nil, failure end
  return result, ""
end

return TermRelay
