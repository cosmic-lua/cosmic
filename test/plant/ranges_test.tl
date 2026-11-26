local Ranges = require("test.plant.ranges")

local function show(list: {Ranges.Range}): string
  local parts: mut {string} = {}
  for _, r in ipairs(list) do parts[#parts + 1] = tostring(r.first) .. "-" .. tostring(r.last) end
  return table.concat(parts, ",")
end

local function test_overlapping_ranges_join()
  assert(show(Ranges.merge({ { first = 1, last = 5 }, { first = 3, last = 8 } })) == "1-8")
end

local function test_apart_ranges_stay_and_sort()
  assert(show(Ranges.merge({ { first = 10, last = 12 }, { first = 1, last = 2 } })) == "1-2,10-12")
end

local function test_the_input_is_not_changed()
  local input: {Ranges.Range} = { { first = 1, last = 2 }, { first = 2, last = 9 } }
  local _ = Ranges.merge(input)
  assert(show(input) == "1-2,2-9")
end
