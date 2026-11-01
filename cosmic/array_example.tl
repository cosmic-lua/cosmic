--- Worked examples for [`cosmic.array`], shown by `cosmic docs` under the
--- symbol each one demonstrates and run by `cosmic test` like any
--- other test -- see doc/design.md's `examples` table.

local Array = require("cosmic.array")

local record Example end

--- An element at a computed position; a position past the end raises.
function Example.at()
  local scores: {integer} = { 10, 20, 30 }
  local last = Array.at(scores, #scores)
  print(last)
  assert(last == 30)
  local ok, why = pcall(function(): integer
    return Array.at(scores, 4)
  end)
  assert(not ok and tostring(why):find("outside the array of 3", 1, true) ~= nil)
end

return Example
