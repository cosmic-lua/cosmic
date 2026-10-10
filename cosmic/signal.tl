--- SIGINT and SIGTERM held for this process while it supervises
--- children or serves connections, so it can end that work before it is
--- ended itself: [`Signal.guard`] opens a guard, which catches either
--- signal rather than acting on it until it closes, and then delivers it
--- again. [`Child.run`] holds one of its own, as [`Net.serve`] does; the
--- waits of [`cosmic.child`], [`cosmic.net`] and [`cosmic.http`] end once
--- the innermost open guard catches one. A signal the process ignores
--- stays ignored and is never caught: a non-interactive shell starts a
--- background job (`cmd &`) with SIGINT ignored, so `kill -INT` of one
--- does nothing; send SIGTERM, or start it with the signal restored.
local Clock = require("cosmic.clock")
local Innermost = require("cosmic.internal.innermost_guard")
local Poll = require("cosmic.poll")
local sys = require("cosmic.sys")

--- The raw process table, [`cosmic.child`]'s too, which holds this
--- process's signals: it arrives as the second argument `require`
--- passes this chunk's loader (core/store.c's `raw_modules`).
local type raw_process = require("cosmic.internal.process")

local extra: any = select(2, ...)
local raw: raw_process
if type(extra) == "table" then
  raw = extra as raw_process
else
  raw = require("cosmic.internal.process")
end

--- SIGINT and SIGTERM held for this process until it closes; see
--- [`Signal.guard`].
local record Guard is Innermost.Held
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

--- The stamp of the latest signal a guard caught and then closed on
--- while another stayed open, 0 when none: the last guard to close
--- delivers it, where that guard opened after it and so never saw it.
local owed = 0

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
  noted(self, raw.child_signal_read(self == Innermost.active()))
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
  if not Poll.in_task() then error("signal: g:wait waits in a task of Poll.run", 2) end
  Poll.checked_ns(timeout_ns, "signal", "timeout_ns", 2)
  local deadline: integer
  if timeout_ns ~= nil then deadline = Clock.monotonic_ns() + timeout_ns end
  while true do
    -- Asked before each wait and after each wake, never from the
    -- pipe's bytes: another task waiting on it may have drained it.
    local signal = self:take()
    if signal ~= 0 then return signal, "" end
    if self._closed then return 0, "signal: the guard is closed" end
    local left: integer
    if deadline ~= nil then left = math.max(deadline - Clock.monotonic_ns(), 0) end
    local woken, why = Poll.readable(raw.child_signal_fd(), left)
    if not woken then return 0, why end
    -- The last close wakes this wait having closed the pipe.
    if not self._closed then Innermost.drain_wake(raw.child_signal_fd()) end
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
  local active = open_guards[#open_guards]
  Innermost.set(active)
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
  Innermost.set(g)
  return g, ""
end

local record Signal
  type Guard = Guard
end

--- Holds SIGINT and SIGTERM for this process while it supervises
--- children, so it can end them before it is ended itself. Until the
--- guard closes, either signal is caught rather than acted on:
--- `g:cancelled()` answers the last one delivered, 0 until one is. A signal
--- the process ignores stays ignored (a shell's `cmd &` starts with SIGINT
--- ignored). Only `h:wait` reads the guard -- it ends its child and answers
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
--- closes. A signal this process ignores stays ignored: a non-interactive
--- shell starts `cmd &` with SIGINT ignored, so the guard never catches
--- it there.
---
--- Guards nest: one opened while another is open -- a [`Child.run`]'s
--- too -- is the innermost until it closes, and the waits (`h:wait`,
--- a stream's, [`cosmic.http`]'s) read the innermost. Each guard sees
--- the signals delivered since it opened, and none before: a guard
--- opened after a signal, to run a child during a shutdown, runs it.
--- What an inner guard sees and takes, the outer ones still see.
---
--- Closing the guard -- `g:close()`, or leaving the scope of a
--- `local g <close> = assert(Signal.guard())` -- restores the
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
function Signal.guard(): Guard | nil, string
  return opened()
end

return Signal
