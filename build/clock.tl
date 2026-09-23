--- How long a verb took, for its verdict line.
local Time = require("cosmic.time")

local record clock
end

--- Whole milliseconds since `from`, a `Time.monotonic_ns` reading; 0
--- when the clock cannot be read.
function clock.elapsed_ms(from: integer): integer
  local now = Time.monotonic_ns()
  if now == nil then
    return 0
  end
  return (now - from) // 1000000
end

return clock
