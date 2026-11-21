--- Worked examples for [`cosmic.number`], shown by `cosmic docs` under
--- the symbol each one demonstrates and run by `cosmic test` like any other
--- test.

local Number = require("cosmic.number")

local record Example end

--- A number a person typed: an optional "-" and decimal digits, nothing
--- else, so `--limit 1e2` is refused rather than read as 100.
function Example.read_integer()
  local limit, why = Number.read_integer("20")
  print(limit, why)
  assert(limit == 20 and why == "")
  local none, refused = Number.read_integer("1e2")
  print(none, refused)
  assert(none == nil and refused:find('"e" at 2', 1, true) ~= nil, refused)
end

return Example
