--- The innermost open guard of [`cosmic.signal`], the one a wait reads:
--- cosmic.signal sets it as guards open and close, and cosmic.child's
--- waits and streams read it. It is kept here, not in cosmic.signal's
--- record, so what cosmic.child reads of a guard stays out of the public
--- module's surface.

local sys = require("cosmic.sys")

--- What a guard has read of the signals, which a wait reads of an open
--- guard. It is written only by the functions of this module, so the
--- guard that holds it, in another module, writes none of its fields.
local record State
  --- The stamp of the latest signal the guard read.
  read: integer
  --- The signal delivered since the guard's last take, 0 when none.
  fresh: integer
  --- Whether the guard has closed.
  closed: boolean
end

local record innermost_guard
  type State = State

  --- What a wait reads of an open guard: the state and the method a
  --- [`Signal.Guard`] declares under the same names.
  interface Held
    state: State
    cancelled: function(Held): integer
  end
end

--- A state of a guard not yet open: nothing read, no signal delivered.
function innermost_guard.fresh_state(): State
  return { read = 0, fresh = 0, closed = false }
end

--- Takes `stamp` as what the guard has read, and `signal` as the signal
--- delivered since its last take.
function innermost_guard.note(state: State, signal: integer, stamp: integer)
  state.fresh, state.read = signal, stamp
end

--- Sets the stamp the guard has read, leaving the signal delivered since its last take.
function innermost_guard.set_read(state: State, stamp: integer)
  state.read = stamp
end

--- The signal delivered since the guard's last take, which it clears.
function innermost_guard.take_fresh(state: State): integer
  local signal = state.fresh
  state.fresh = 0
  return signal
end

--- Marks the guard closed.
function innermost_guard.close(state: State)
  state.closed = true
end

local type Held = innermost_guard.Held

local record Open
  innermost: Held | nil
end

local open: Open = {}

--- The innermost open guard, or nil when none is open.
function innermost_guard.active(): Held | nil
  return open.innermost
end

--- Makes `guard` the innermost open guard, or none with nil.
function innermost_guard.set(guard: Held | nil)
  open.innermost = guard
end

--- Empties the wake pipe `fd`, which a signal a guard catches writes to
--- and which is readable while any byte it wrote there is left.
function innermost_guard.drain_wake(fd: integer)
  while true do
    local bytes, _ = sys.read(fd, 512)
    if bytes == nil or #bytes < 512 then return end
  end
end

return innermost_guard
