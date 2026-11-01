--- Worked examples for [`cosmic.rand`], shown by `cosmic docs` under the
--- symbol each one demonstrates and run by `cosmic test` like any
--- other test -- see doc/design.md's `examples` table.

local Codec = require("cosmic.codec")
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

--- Bytes nobody can guess or replay, for a token: unlike a `Source`,
--- never the same twice.
function Example.entropy()
  local bytes, err = Rand.entropy(16)
  assert(bytes ~= nil, err)
  assert(#bytes == 16)
  print(Codec.hex(bytes))
end

--- Simulated measurement noise with [`Rand.Source.normal`]: a sensor
--- reads a true value of 20 with a standard deviation of 0.5. The
--- readings cluster around 20, and a source made from the same seed
--- replays them.
function Example.normal()
  local rng, replay = Rand.new(7), Rand.new(7)
  local readings: mut {number} = {}
  for i = 1, 200 do
    local reading = rng:normal(20, 0.5)
    readings[i] = reading
    assert(reading > 20 - 0.5 * 8 and reading < 20 + 0.5 * 8, "a reading fell eight deviations out")
    assert(replay:normal(20, 0.5) == reading, "the same seed drew another value")
  end
  local sum: number = 0
  for _, reading in ipairs(readings) do sum = sum + reading end
  local mean = sum / #readings
  print(("%.1f"):format(mean))
  assert(mean > 19 and mean < 21)
  local standard = 0.0
  for _ = 1, 400 do standard = standard + rng:normal() end
  assert(math.abs(standard / 400) < 0.5, "normal() should draw around 0")
end

--- Waiting times with [`Rand.Source.gamma`]: draws of shape 2 and scale 3
--- are always positive and skewed, and average shape * scale = 6 (here,
--- minutes until the second event of a process averaging one per 3). A
--- shape below 1 is allowed too, and `scale` defaults to 1.
function Example.gamma()
  local rng, replay = Rand.new(11), Rand.new(11)
  local total: number = 0
  local n = 500
  for _ = 1, n do
    local wait = rng:gamma(2, 3)
    assert(wait > 0, "a gamma draw must be positive")
    assert(replay:gamma(2, 3) == wait, "the same seed drew another value")
    total = total + wait
  end
  local mean = total / n
  print(("%.0f"):format(mean))
  assert(mean > 4 and mean < 8)
  assert(rng:gamma(0.5) > 0)
end

return Example
