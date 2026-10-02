--- Synthetic populations challenge the performance gate, independent of the
--- host's scheduler. Integration measurements retain actual command outputs.
local Perf = require("build.perf")

local function population(delta: number): {Perf.Pair}
  local samples: {Perf.Pair} = {}
  for i = 1, 30 do
    samples[i] = { a = 100, b = 100 + delta + (i % 2 == 0 and 1 or -1) }
  end
  return samples
end

local function test_identical_population_passes()
  local measured = Perf.compare(population(0), population(0))
  assert(measured.status == "pass")
  assert(measured.delta.low == -1 and measured.delta.high == 1)
end

local function test_consistent_slowdown_cannot_hide_in_single_sample_noise()
  local calibration = population(0)
  calibration[1].b, calibration[2].b = 1, 199
  local measured = Perf.compare(calibration, population(3))
  assert(measured.status == "regression")
end

local function test_biased_calibration_is_inconclusive()
  assert(Perf.compare(population(10), population(1)).status == "inconclusive")
end

local function test_positive_interval_inside_noise_is_not_a_pass()
  local shifted: {Perf.Pair} = {}
  for i = 1, 30 do shifted[i] = { a = 100, b = 100.5 } end
  assert(Perf.compare(population(0), shifted).status == "inconclusive")
end

local function test_slow_tail_cannot_hide_behind_fast_median()
  local candidate = population(-5)
  candidate[29].b, candidate[30].b = 150, 160
  local measured = Perf.compare(population(0), candidate)
  assert(measured.delta.median < 0 and measured.tail_delta > 0)
  assert(measured.status == "inconclusive")
end

local function test_distribution_sorts_a_copy_and_has_exact_sign_ranks()
  local values: {number} = {}
  for i = 1, 30 do values[i] = 31 - i end
  local distribution = Perf.distribution(values)
  assert(values[1] == 30 and distribution.median == 15.5)
  assert(distribution.low == 10 and distribution.high == 21)
  assert(distribution.p95 == 29)
end

local function test_noisier_candidate_needs_review_even_if_faster()
  local candidate: {Perf.Pair} = {}
  for i = 1, 30 do candidate[i] = { a = 100, b = i % 2 == 0 and 40 or 60 } end
  local measured = Perf.compare(population(0), candidate)
  assert(measured.delta.high < 0 and measured.tail_delta < 0)
  assert(measured.status == "inconclusive")
end
