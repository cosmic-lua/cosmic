--- Clocks and sleeping. Every reading is in nanoseconds, so nothing
--- above this module carries a unit it has to remember.

local sys = require("cosmic.sys")

local record Time
end

--- The wall clock, which can step backwards when the host adjusts it.
function Time.now_ns(): integer | nil, string
  local reading, trouble = sys.clock_gettime(sys.CLOCK_REALTIME)
  if reading == nil then
    return nil, trouble
  end
  return reading
end

--- A clock that only moves forward, for measuring how long something
--- took.
function Time.monotonic_ns(): integer | nil, string
  local reading, trouble = sys.clock_gettime(sys.CLOCK_MONOTONIC)
  if reading == nil then
    return nil, trouble
  end
  return reading
end

--- Sleeps, resuming the wait when a signal interrupts it.
function Time.sleep_ns(nanoseconds: integer): boolean, string
  local ok, trouble = sys.nanosleep(nanoseconds)
  if not ok then
    return false, trouble
  end
  return true, ""
end

return Time
