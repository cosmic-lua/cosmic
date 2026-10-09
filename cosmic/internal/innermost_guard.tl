--- The innermost open guard of [`cosmic.signal`], the one a wait reads:
--- cosmic.signal sets it as guards open and close, and cosmic.child's
--- waits and streams read it. It is kept here, not in cosmic.signal's
--- record, so what cosmic.child reads of a guard stays out of the public
--- module's surface.

local sys = require("cosmic.sys")

local record innermost_guard
  --- What a wait reads of an open guard: the fields and method a
  --- [`Signal.Guard`] declares under the same names.
  interface Held
    _read: integer
    _fresh: integer
    _closed: boolean
    cancelled: function(Held): integer
  end
end

local type Held = innermost_guard.Held

local innermost: Held | nil

--- The innermost open guard, or nil when none is open.
function innermost_guard.active(): Held | nil
  return innermost
end

--- Makes `guard` the innermost open guard, or none with nil.
function innermost_guard.set(guard: Held | nil)
  innermost = guard
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
