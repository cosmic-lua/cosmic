--- The timing the speed tests of `lang/` share. A speed test holds one piece of
--- work to a multiple of another and never to a clock, so that a slow machine
--- slows both sides alike. A moment of load can still fall on one side only, so
--- each side is the least of several samples, each sample long enough to read,
--- and a comparison that fails is made again: it fails only if every attempt
--- does. A limit under the cost of a quadratic form (16 times for four times the
--- input) therefore still catches one.
local Clock = require("cosmic.clock")

local record Speed
  --- The least time, in nanoseconds, that one run of `work` takes over three samples.
  --- A sample repeats `work` until it has taken a few milliseconds, which a clock reads without
  --- much error.
  least: function(work: function()): integer

  --- Whether `scaled` costs at most `limit` times what `base` costs, or `false` and the times
  --- of the last attempt. `attempts` (3 by default) is how many comparisons may fail before it does.
  within: function(base: function(), scaled: function(), limit: integer, attempts?: integer): boolean, string
end

--- The time a sample takes at least, in nanoseconds.
local FLOOR <const> = 5000000
local SAMPLES <const> = 3
--- The most runs a sample makes, for work that takes almost no time.
local MOST_RUNS <const> = 2000

local function elapsed(work: function(), runs: integer): integer
  local started = Clock.monotonic_ns()
  for _ = 1, runs do
    work()
  end
  return Clock.monotonic_ns() - started
end

function Speed.least(work: function()): integer
  local first = elapsed(work, 1)
  local runs = 1
  if first < FLOOR then
    runs = math.min(MOST_RUNS, FLOOR // math.max(first, 1) + 1)
  end
  local best = first
  for _ = 1, SAMPLES do
    best = math.min(best, elapsed(work, runs) // runs)
  end
  return best
end

function Speed.within(base: function(), scaled: function(), limit: integer, attempts?: integer): boolean, string
  local why = ""
  for _ = 1, attempts or 3 do
    local small, large = Speed.least(base), Speed.least(scaled)
    if large <= limit * small then
      return true, ""
    end
    why = "took " .. large // 1000 .. " us against " .. small // 1000 .. " us, over " .. limit .. " times"
  end
  return false, why
end

return Speed
