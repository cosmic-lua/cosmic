--- Worked examples for `cosmic.rand`, shown by `cosmic docs` under the
--- symbol each one demonstrates and run by `cosmic test` like any
--- other test -- see doc/design.md's `examples` table.

local Rand = require("cosmic.rand")

local Example = {}

--- A seed names one sequence: two sources made from it draw the same
--- values, which is what lets a run that depends on chance be replayed.
function Example.new()
  local a, b = Rand.new(2026), Rand.new(2026)
  local roll = a:int(1, 6)
  print(roll)
  assert(roll >= 1 and roll <= 6)
  assert(b:int(1, 6) == roll, "the same seed drew another value")
end

return Example
