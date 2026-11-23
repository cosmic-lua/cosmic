--- Worked examples for [`cosmic.number`], shown by `cosmic docs` under
--- the symbol each one demonstrates and run by `cosmic test` like any other
--- test.

local Number = require("cosmic.number")

local record Example end

--- A number a person typed: an optional "-" and decimal digits, nothing
--- else, so `--limit 1e2` is refused rather than read as 100.
function Example.integer()
  local limit = assert(Number.integer("20"))
  print(limit)
  assert(limit == 20)
  local none, refused = Number.integer("1e2")
  print(none, refused)
  assert(none == nil and refused.message:find('"e" at 2', 1, true) ~= nil)
end

return Example
