--- The pty relay `cosmic sandbox` runs a program through when its own
--- input is a terminal: the program is given a pty of its own as its
--- terminal -- never the caller's, which a program holding it could write
--- control sequences to or push input into -- and this loop copies
--- between the two.
---
--- The caller's keys go to the pty's master as they are: they are the
--- user's own input. What the program writes goes through a
--- [`build.term_filter`] on its way to the caller's terminal, so it reaches the
--- terminal as text and the few sequences a screen is drawn with, and
--- no more; the filter answers the program's terminal queries itself,
--- and the answers are written to the master as the terminal's input.
---
--- THE CALLER'S TERMINAL is saved, put in raw mode for the run and
--- restored on every way out: the program's exit, a failure, a raise and
--- a signal this process catches. First the sequences that undo what the
--- filter let the program set (its attributes, scroll region, hidden
--- cursor, alternate screen and the rest of the private modes) are
--- written, then the saved termios is put back; nothing is flushed with
--- `tcflush` -- see the TODO in `restore`. A process ended by SIGKILL
--- restores nothing, as with any program that sets a terminal raw.
---
--- THE WINDOW SIZE is the caller's, set on the master before the program
--- starts and again whenever it is seen to change.
---
--- SIGNALS: SIGINT and SIGTERM sent to this process are caught by a
--- [`Child.guard`] and passed to the program's process group; the
--- terminal's own keys are not signals here, since raw mode hands ^C to
--- the program as a byte and the pty's line discipline raises its SIGINT
--- in the program's session. SIGHUP is not caught: when the caller's
--- terminal hangs up, this process dies of it by default, its pty master
--- closes with it, and the kernel hangs up the program's session.
--- The run's end is the program's: this returns what [`Child.run`] does,
--- its [`Child.Result`], and the verb exits with the program's status.
---
--- The loop waits in [`sys.poll`] at most `TICK_MS` at a time, which is
--- what every check that no descriptor announces is made at: the
--- program's exit, a signal the guard caught and the caller's window.

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

--- The caller's own terminal, as descriptors.
local record Terminal
  --- Where the caller's keys are read; a terminal. 0 by default.
  input: integer
  --- Where the filtered output is written. 1 by default.
  output: integer
end

local record TermRelay
  --- The caller's terminal.
  type Terminal = Terminal
  --- Runs `argv` as [`Child.start_on_terminal`] starts it, with `opts`,
  --- on a pty relayed to `terminal` (this process's stdin and stdout
  --- when nil), and answers its [`Child.Result`] once it has ended, as
  --- [`Child.run`] does; nil and why where the relay cannot be set up
  --- (no pty, `terminal.input` no terminal, the start failed, or the
  --- platform cannot give a program a controlling terminal: macOS).
  --- Raises as [`Child.start_on_terminal`] does for `opts`.
  run: function(argv: {string}, opts: Child.Options, terminal?: Terminal): Child.Result | nil, string
end

--- What `run` puts back when it ends, however it does: held in a
--- `<close>` variable.
local record Restoring
  metamethod __close: function(Restoring)
  input: integer
  output: integer
  --- The caller's termios as it was, or nil until `run` has put the
  --- terminal in raw mode.
  saved: string | nil
  filter: TermFilter.Filter
end

--- Writes all of `data` to `fd`, waiting when it is not ready. False and
--- why when `fd` fails.
local function write_all(fd: integer, data: string): boolean, string
  local at = 1
  while at <= #data do
    local count, why, errno = sys.write(fd, at == 1 and data or data:sub(at))
    if count ~= nil then
      at = at + count
    elseif errno == sys.EAGAIN then
      local _, _ = sys.poll({ fd }, { sys.POLLOUT }, TICK_MS)
    elseif errno ~= sys.EINTR then
      return false, why
    end
  end
  return true, ""
end

local restoring_mt: metatable<Restoring> = {
  __close = function(self: Restoring)
    local resets = self.filter:restore()
    if resets ~= "" then
      local _, _ = write_all(self.output, resets)
    end
    if self.saved ~= nil then
      local _, _ = sys.tcsetattr(self.input, self.saved)
      self.saved = nil
    end
    -- TODO: discard the caller's typed-ahead input here, once
    -- cosmic.sys.tcflush can name the input queue alone: the call it has
    -- discards the output queue too, which can still hold the program's
    -- last bytes on a slow terminal, so none is made.
  end,
}

--- The size of `fd`'s window as "rows,columns", or "".
local function window(fd: integer): string
  local size, _ = sys.winsize(fd)
  if size == nil then return "" end
  return size.rows .. "," .. size.columns
end

function TermRelay.run(argv: {string}, opts: Child.Options, terminal?: Terminal): Child.Result | nil, string
  local input = terminal ~= nil and terminal.input or 0
  local output = terminal ~= nil and terminal.output or 1
  local system, _ = sys.uname()
  if system == nil or system.sysname ~= "Linux" then
    -- TODO: give the program a controlling terminal on macOS, once the
    -- Seatbelt trampoline that applies a policy before exec (the design's
    -- phase 8, doc/plans/sandbox.md) also makes the pty slave its
    -- controlling terminal; until then spawn's terminal argument is
    -- ENOSYS there, and a program with a terminal is not run unhooked.
    return nil, "terminal: giving a sandboxed program a terminal needs the Seatbelt trampoline, " ..
      "which is not yet available on " .. (system ~= nil and system.sysname or "this system") ..
      "; run it with its input from a file or a pipe"
  end
  local saved, saved_why = sys.tcgetattr(input)
  if saved == nil then
    return nil, "terminal: this process's input is no terminal: " .. saved_why
  end
  local pty, pty_why = sys.openpty()
  if pty == nil then return nil, "terminal: no pty to give the program: " .. pty_why end
  local master, slave = pty.master, pty.slave
  local nonblocking, nonblocking_why = sys.set_nonblocking(master, true)
  if not nonblocking then
    local _, _ = sys.close(master)
    local _, _ = sys.close(slave)
    return nil, "terminal: " .. nonblocking_why
  end
  local size, _ = sys.winsize(input)
  if size ~= nil then
    local _, _ = sys.setwinsize(master, size.rows, size.columns)
  end
  -- Held before the program starts, and closed after it has ended, so a
  -- signal that comes between never finds it unguarded.
  local opened, guard_why = Child.guard()
  if opened == nil then
    local _, _ = sys.close(master)
    local _, _ = sys.close(slave)
    return nil, "terminal: " .. guard_why
  end
  local guard <close> = opened
  local started, start_why = Child.start_on_terminal(argv, opts, slave)
  -- The program holds its own slave now; ours would keep the master from
  -- ever reading the end of the program's output.
  local _, _ = sys.close(slave)
  if started == nil then
    local _, _ = sys.close(master)
    return nil, start_why
  end
  local running <close> = started
  local filter = TermFilter.new()
  local restoring <close>: Restoring = setmetatable({
    input = input, output = output, saved = nil, filter = filter,
  }, restoring_mt)
  local raw, raw_why = sys.tcraw(input)
  if not raw then
    local _, _ = sys.close(master)
    return nil, "terminal: " .. raw_why
  end
  restoring.saved = saved

  -- TODO: wake on SIGWINCH and catch SIGHUP, once Child.guard (or a
  -- cosmic.sys binding) can hold signals beyond SIGINT and SIGTERM: the
  -- caller's window is looked at every TICK_MS instead of when it changes,
  -- and a SIGHUP sent to this process (a hangup of its terminal needs no
  -- handler) ends it with the terminal still raw.
  local pending = ""
  local keys_open = true
  local master_open = true
  local signals = 0
  local seen = window(input)
  local result: Child.Result
  local failure: string

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
      local written, why = write_all(output, passed)
      if not written then
        failure = "terminal: writing the program's output: " .. why
        return -1
      end
    end
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
    local now = window(input)
    if now ~= seen then
      seen = now
      local resized, _ = sys.winsize(input)
      if resized ~= nil then
        local _, _ = sys.setwinsize(master, resized.rows, resized.columns)
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
    local master_fd = (master_open or #pending > 0) and master or -1
    local master_events = (master_open and sys.POLLIN or 0) | (#pending > 0 and sys.POLLOUT or 0)
    local ready, poll_why = sys.poll({ keys_fd, master_fd }, { sys.POLLIN, master_events }, TICK_MS)
    if ready == nil then
      failure = "terminal: waiting: " .. poll_why
      break
    end
    if ready[2] ~= 0 then
      if ready[2] & sys.POLLOUT ~= 0 and #pending > 0 then
        local _ = flush_pending()
      end
      if master_open and ready[2] & (sys.POLLIN | sys.POLLHUP | sys.POLLERR) ~= 0 then
        local _ = relay_output()
      end
    end
    if ready[1] ~= 0 then
      local keys, _, errno = sys.read(input, CHUNK)
      if keys ~= nil and keys ~= "" then
        pending = pending .. keys
        local _ = flush_pending()
      elseif keys == "" or (errno ~= sys.EAGAIN and errno ~= sys.EINTR) then
        -- The caller's terminal has gone: hang the program up as its own
        -- terminal's hangup would, and wait for it to go.
        keys_open = false
        local _, _ = running:stop(sys.SIGHUP)
      end
    end
  end
  if result ~= nil and master_open then
    -- What the program wrote last is still in the master.
    local budget = MOST_AFTER_EXIT
    while budget > 0 do
      local count = relay_output()
      if count <= 0 then break end
      budget = budget - count
    end
  end
  local _, _ = sys.close(master)
  if failure ~= nil then return nil, failure end
  return result, ""
end

return TermRelay
