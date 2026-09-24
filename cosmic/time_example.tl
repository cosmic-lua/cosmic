--- Worked examples for `cosmic.time`, shown by `cosmic docs` under the
--- symbol each one demonstrates and run by `cosmic test` like any other
--- test -- see doc/design.md's `examples` table.

local Time = require("cosmic.time")

local Example = {}

--- A millisecond's wait, measured on the monotonic clock, which never
--- jumps the way the wall clock can.
function Example.sleep_ns()
  local before = Time.monotonic_ns()
  assert(Time.sleep_ns(1000000))
  local waited = Time.monotonic_ns() - before
  print(waited >= 1000000)
  assert(waited >= 1000000, tostring(waited))
end

return Example
