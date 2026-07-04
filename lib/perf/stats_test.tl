local stats = require("perf.stats")

local function close_enough(a: number, b: number): boolean
  return math.abs(a - b) < 1e-9
end

local function test_empty_lists_return_zero()
  assert(stats.min({}) == 0, "min of empty should be 0")
  assert(stats.max({}) == 0, "max of empty should be 0")
  assert(stats.mean({}) == 0, "mean of empty should be 0")
  assert(stats.median({}) == 0, "median of empty should be 0")
  assert(stats.stddev({}) == 0, "stddev of empty should be 0")
  assert(stats.spread_pct({}) == 0, "spread of empty should be 0")
end
test_empty_lists_return_zero()

local function test_sorted_returns_copy()
  local input = {3, 1, 2}
  local s = stats.sorted(input)
  assert(s[1] == 1 and s[2] == 2 and s[3] == 3, "sorted order wrong")
  assert(input[1] == 3, "input list must not be mutated")
end
test_sorted_returns_copy()

local function test_min_max_mean()
  local values = {4, 1, 7, 2}
  assert(stats.min(values) == 1, "min wrong")
  assert(stats.max(values) == 7, "max wrong")
  assert(close_enough(stats.mean(values), 3.5), "mean wrong: " .. stats.mean(values))
end
test_min_max_mean()

local function test_median_odd_and_even()
  assert(stats.median({5}) == 5, "single-value median wrong")
  assert(stats.median({3, 1, 2}) == 2, "odd median wrong")
  assert(close_enough(stats.median({4, 1, 3, 2}), 2.5), "even median wrong")
end
test_median_odd_and_even()

local function test_stddev()
  assert(stats.stddev({5}) == 0, "single-value stddev should be 0")
  -- sample stddev of {2, 4, 4, 4, 5, 5, 7, 9} is ~2.138
  local sd = stats.stddev({2, 4, 4, 4, 5, 5, 7, 9})
  assert(math.abs(sd - 2.138089935299395) < 1e-9, "stddev wrong: " .. sd)
end
test_stddev()

local function test_spread_pct()
  -- median 10, max-min = 2 -> 20%
  assert(close_enough(stats.spread_pct({9, 10, 11}), 20.0),
    "spread wrong: " .. stats.spread_pct({9, 10, 11}))
  assert(stats.spread_pct({0, 0, 0}) == 0, "zero-median spread should be 0")
end
test_spread_pct()

print("OK stats_test")
