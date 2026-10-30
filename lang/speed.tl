--- The timing the speed tests of `lang/` share. A speed test holds one piece of
--- work to a multiple of another and never to a clock, so that a slow machine
--- slows both sides alike. A moment of load can still fall on one side only, so
--- each side is the least of several samples, each sample long enough to read,
--- the samples of the two sides taken in turn so that load falls on both. The
--- comparison is made after every pair of samples and while it fails more are
--- taken: it fails only if every pair does. A limit under the
--- cost of a quadratic form (16 times for four times the input) therefore still
--- catches one.
local Clock = require("cosmic.clock")

local record Speed
  --- The least time, in nanoseconds, that one run of `work` takes over five samples.
  --- A sample repeats `work` until it has taken a few milliseconds, which a clock reads without
  --- much error.
  least: function(work: function()): integer

  --- Whether `scaled` costs at most `limit` times what `base` costs, or `false` and the least
  --- times of the pairs of samples it took. `most_pairs` (12 by default) is how many pairs it
  --- takes before it fails.
  within: function(base: function(), scaled: function(), limit: integer, most_pairs?: integer): boolean, string
end

--- The time a sample takes at least, in nanoseconds.
local FLOOR <const> = 5000000
local SAMPLES <const> = 5
--- The most pairs of samples `within` takes by default: a pass ends it sooner.
local PAIRS <const> = 12
--- The most runs a sample makes, for work that takes almost no time.
local MOST_RUNS <const> = 2000

local function elapsed(work: function(), runs: integer): integer
  collectgarbage()
  local started = Clock.monotonic_ns()
  for _ = 1, runs do
    work()
  end
  return Clock.monotonic_ns() - started
end

--- How many runs of `work` make a sample long enough to read, and the time of its first run.
local function plan(work: function()): integer, integer
  local first = elapsed(work, 1)
  if first < FLOOR then
    return math.min(MOST_RUNS, FLOOR // math.max(first, 1) + 1), first
  end
  return 1, first
end

function Speed.least(work: function()): integer
  local runs, best = plan(work)
  for _ = 1, SAMPLES do
    best = math.min(best, elapsed(work, runs) // runs)
  end
  return best
end

function Speed.within(base: function(), scaled: function(), limit: integer, most_pairs?: integer): boolean, string
  local base_runs, small = plan(base)
  local scaled_runs, large = plan(scaled)
  -- The samples of the two sides alternate, so that a stretch of load falls on both: the side
  -- read all at once would take it whole, and the other side none. Load only adds time, so each
  -- side's least keeps falling toward its true cost, and the comparison is made after every pair:
  -- a pass ends it, and only a form that is over the limit at its true cost takes every pair.
  for _ = 1, most_pairs or PAIRS do
    small = math.min(small, elapsed(base, base_runs) // base_runs)
    large = math.min(large, elapsed(scaled, scaled_runs) // scaled_runs)
    if large <= limit * small then
      return true, ""
    end
  end
  return false, "took " .. tostring(large // 1000) .. " us against " .. tostring(small // 1000) .. " us, over " .. tostring(limit) .. " times"
end

return Speed
