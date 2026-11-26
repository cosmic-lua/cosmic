local Rle = require("test.plant.rle")

local function test_nothing_encodes_to_nothing()
  assert(Rle.encode("") == "")
end

local function test_short_runs_decode()
  assert(Rle.decode("3a1b2c") == "aaabcc")
end
