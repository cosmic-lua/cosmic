--- The guards [`Child.guard`] opens: SIGINT and SIGTERM held for this
--- process while it supervises children, and which guard is the
--- innermost open, the one a wait reads. cosmic.child re-exports the
--- guard and reads the innermost here; [`cosmic.net`] holds one around
--- [`Net.serve`] without loading the rest of cosmic.child.

local Clock = require("cosmic.clock")
local Poll = require("cosmic.poll")
local sys = require("cosmic.sys")

--- The raw process table, cosmic.child's too, which holds this
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

--- Empties the wake pipe, which is readable while any byte a signal
--- wrote there is left.
local function drain_wake()
  local fd = raw.child_signal_fd()
  while true do
    local bytes, _ = sys.read(fd, 512)
    if bytes == nil or #bytes < 512 then return end
  end
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
  if timeout_ns ~= nil then deadline = Clock.monotonic_ns() + timeout_ns end
  while true do
    -- Asked before each wait and after each wake, never from the
    -- pipe's bytes: another task waiting on it may have drained it.
    local signal = self:take()
    if signal ~= 0 then return signal, "" end
    if self._closed then return 0, "child: the guard is closed" end
    local left: integer
    if deadline ~= nil then left = math.max(deadline - Clock.monotonic_ns(), 0) end
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

local record signal_guard
  type Guard = Guard
end

--- Opens a guard, the innermost of those open, as [`Child.guard`] does.
function signal_guard.open(): Guard | nil, string
  return opened()
end

--- The innermost open guard, the one a wait reads, or nil when none is open.
function signal_guard.active(): Guard | nil
  return active
end

--- Empties the wake pipe a signal a guard catches writes to.
function signal_guard.drain_wake()
  drain_wake()
end

return signal_guard
