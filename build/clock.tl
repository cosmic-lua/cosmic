--- How long a verb took, for its verdict line.
local Time = require("cosmic.time")

local record clock
end

--- Whole milliseconds since `from`, a `Time.monotonic_ns` reading.
function clock.elapsed_ms(from: integer): integer
  return (Time.monotonic_ns() - from) // 1000000
end

return clock
