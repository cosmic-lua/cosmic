--- How long a verb took, for its verdict line.
local Clock = require("cosmic.clock")

local record clock
end

--- Whole milliseconds since `from`, a [`Clock.monotonic_ns`] reading: the
--- unit a verdict line and [`work.record`]'s elapsed column are read in.
function clock.elapsed_ms(from: integer): integer
  return (Clock.monotonic_ns() - from) // Clock.ms(1)
end

--- The time since `from` as a verdict line says it: "<ms> ms".
function clock.took(from: integer): string
  return clock.elapsed_ms(from) .. " ms"
end

return clock
