local Text = require("text")

local function test_pad_both_ways()
  assert(Text.pad_left("7", 3) == "  7")
  assert(Text.pad_right("7", 3) == "7  ")
  assert(Text.pad_left("1234", 3) == "1234")
end
