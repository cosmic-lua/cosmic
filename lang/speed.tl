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
--- The longest a sample of the base side of `within` is made, in nanoseconds, to cap its time.
local LONGEST <const> = 20000000
--- The fewest pairs of samples `within` takes before it passes.
local FEWEST_PAIRS <const> = 3
--- The most runs a sample makes, for work that takes almost no time.
local MOST_RUNS <const> = 2000

local function elapsed(work: function(), runs: integer): integer
  local started = Clock.monotonic_ns()
  for _ = 1, runs do
    work()
  end
  return Clock.monotonic_ns() - started
end

--- The time of the first run of `work`, which is cold and is not a sample.
local function first_run(work: function()): integer
  return math.max(elapsed(work, 1), 1)
end

--- How many runs of `work`, whose first took `first`, make a sample of at least `target`.
local function runs_for(first: integer, target: integer): integer
  return math.min(MOST_RUNS, target // first + 1)
end

function Speed.least(work: function()): integer
  local runs = runs_for(first_run(work), FLOOR)
  local best = math.maxinteger
  for _ = 1, SAMPLES do
    best = math.min(best, elapsed(work, runs) // runs)
  end
  return best
end

function Speed.within(base: function(), scaled: function(), limit: integer, most_pairs?: integer): boolean, string
  -- A sample of each side lasts about as long as one run of the scaled side, within a limit: a
  -- stretch of load that preempts a long sample preempts a short one as often, and the ratio is
  -- not raised by the scaled side being the longer to hit.
  local base_first, scaled_first = first_run(base), first_run(scaled)
  local target = math.min(math.max(FLOOR, scaled_first), LONGEST)
  local base_runs, scaled_runs = runs_for(base_first, target), runs_for(scaled_first, target)
  local small, large = math.maxinteger, math.maxinteger
  -- The samples of the two sides alternate, so that a stretch of load falls on both: the side
  -- read all at once would take it whole, and the other side none. Load only adds time, so each
  -- side's least keeps falling toward its true cost, and the comparison is made after every pair:
  -- a pass ends it, and only a form that is over the limit at its true cost takes every pair. A
  -- pass waits for a few pairs, so that one slow sample of the base alone cannot pass a form.
  for pair = 1, most_pairs or PAIRS do
    small = math.min(small, elapsed(base, base_runs) // base_runs)
    large = math.min(large, elapsed(scaled, scaled_runs) // scaled_runs)
    if pair >= FEWEST_PAIRS and large <= limit * small then
      return true, ""
    end
  end
  return false, "took " .. tostring(large // 1000) .. " us against " .. tostring(small // 1000) .. " us, over " .. tostring(limit) .. " times"
end

return Speed
