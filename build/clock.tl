--- How long a verb took, for its verdict line.
local Time = require("cosmic.time")

local record clock
end

--- Whole milliseconds since `from`, a [`Time.monotonic_ns`] reading: the
--- unit a verdict line and [`work.record`]'s elapsed column are read in.
function clock.elapsed_ms(from: integer): integer
  return (Time.monotonic_ns() - from) // Time.ms(1)
end

--- The time since `from` as a verdict line says it: "<ms> ms".
function clock.took(from: integer): string
  return clock.elapsed_ms(from) .. " ms"
end

return clock
