--- Deterministic statistical cases; host timings are not inputs to the gate.
local Perf = require("build.perf")
local Test = require("cosmic.test")
local support = require("build.test_support_fixture")

local function population(delta: number, count?: integer): {Perf.Pair}
  local samples: mut {Perf.Pair} = {}
  for i = 1, count or 200 do
    local a = if i % 2 == 0 then 99 else 101 end
    samples[i] = { a = a, b = 200 - a + delta }
  end
  return samples
end

local function has_reason(reasons: {string}, wanted: string): boolean
  for _, reason in ipairs(reasons) do
    if reason == wanted then return true end
  end
  return false
end

local function test_identical_population_passes()
  local measured = Perf.compare(population(0), population(0))
  assert(measured.status == "pass")
  assert(measured.delta.low == -2 and measured.delta.high == 2)
  assert(measured.tail_interval.low == 0 and measured.tail_interval.high == 0)
end

local function test_consistent_slowdown_cannot_hide_in_single_sample_noise()
  local calibration = population(0)
  support.nth(calibration, 1).b, support.nth(calibration, 2).b = 1, 199
  assert(Perf.compare(calibration, population(5)).status == "regression")
end

local function test_biased_calibration_is_inconclusive()
  assert(Perf.compare(population(10), population(1)).status == "inconclusive")
end

local function test_positive_interval_inside_noise_is_not_a_pass()
  local shifted: mut {Perf.Pair} = {}
  for i = 1, 200 do shifted[i] = { a = 100, b = 100.5 } end
  local measured = Perf.compare(population(0), shifted)
  assert(measured.delta.low > 0 and measured.delta.low < measured.noise)
  assert(measured.status ~= "pass" and has_reason(measured.reasons, "positive_median_interval"))
end

local function test_slow_tail_cannot_hide_behind_fast_median()
  local candidate = population(-5)
  for i = 171, 200 do support.nth(candidate, i).b = 150 + i end
  local measured = Perf.compare(population(0), candidate)
  assert(measured.delta.median < 0 and measured.tail_delta > 0)
  assert(measured.status ~= "pass" and has_reason(measured.reasons, "positive_tail_interval"))
end

local function test_distribution_has_independently_computed_binomial_ranks()
  -- Exact integer sums, documented in doc/performance/validation.md; the
  -- production implementation instead uses a normalized mode recurrence.
  local record Ranks
    n: integer
    low: integer
    high: integer
    p95_low: integer
    p95_high: integer
  end
  local cases: {Ranks} = {
    { n = 6, low = 1, high = 6, p95_low = 4, p95_high = 7 },
    { n = 30, low = 10, high = 21, p95_low = 25, p95_high = 31 },
    { n = 85, low = 33, high = 53, p95_low = 76, p95_high = 86 },
    { n = 86, low = 34, high = 53, p95_low = 77, p95_high = 86 },
    { n = 100, low = 40, high = 61, p95_low = 90, p95_high = 100 },
    { n = 200, low = 86, high = 115, p95_low = 183, p95_high = 197 },
    { n = 400, low = 180, high = 221, p95_low = 370, p95_high = 390 },
    { n = 1000, low = 469, high = 532, p95_low = 934, p95_high = 966 },
    { n = 1074, low = 505, high = 570, p95_low = 1004, p95_high = 1037 },
    { n = 1075, low = 505, high = 571, p95_low = 1005, p95_high = 1038 },
    { n = 1076, low = 506, high = 571, p95_low = 1006, p95_high = 1039 },
    { n = 2000, low = 956, high = 1045, p95_low = 1878, p95_high = 1922 },
  }
  for _, case in ipairs(cases) do
    local n = case.n
    local values: mut {number} = {}
    for i = 1, n do values[i] = n + 1 - i end
    local distribution = Perf.distribution(values)
    assert(values[1] == n and distribution.median == (n + 1) / 2)
    assert(distribution.low == case.low and distribution.high == case.high, "median ranks: " .. tostring(n))
    assert(distribution.p95_interval.low == case.p95_low, "p95 lower rank: " .. tostring(n))
    if case.p95_high > n then
      assert(not distribution.p95_interval.upper_bounded and distribution.p95_interval.high == nil)
    else
      assert(distribution.p95_interval.upper_bounded and distribution.p95_interval.high == case.p95_high,
        "p95 upper rank: " .. tostring(n))
    end
  end
end

local function test_noisier_candidate_needs_review_even_if_faster()
  local candidate: mut {Perf.Pair} = {}
  for i = 1, 200 do candidate[i] = { a = 100, b = if i % 2 == 0 then 40 else 60 end } end
  local measured = Perf.compare(population(0), candidate)
  assert(measured.delta.high < 0 and measured.tail_delta < 0)
  assert(measured.status == "inconclusive" and has_reason(measured.reasons, "increased_dispersion"))
end

local function test_small_samples_are_exploratory_and_ties_are_valid()
  for _, n in ipairs({ 30, 100, 199 }) do
    local samples: mut {Perf.Pair} = {}
    for i = 1, n do samples[i] = { a = 100, b = 100 } end
    local measured = Perf.compare(samples, samples)
    assert(measured.status == "inconclusive" and has_reason(measured.reasons, "exploratory_sample_count"))
    if n == 30 then assert(has_reason(measured.reasons, "unbounded_tail_interval")) end
  end
  local equal: mut {number} = {}
  for i = 1, 2000 do equal[i] = 7 end
  local measured = Perf.distribution(equal)
  assert(measured.low == 7 and measured.high == 7 and measured.p95_interval.high == 7)
end

local function test_nonfinite_observations_are_refused()
  for _, invalid in ipairs({ math.huge, -math.huge, 0 / 0 }) do
    assert(not pcall(Perf.distribution, { 1, 2, 3, 4, 5, invalid }))
  end
end

local function test_finite_median_midpoint_does_not_overflow()
  local measured = Perf.distribution({ 1e308, 1e308, 1e308, 1e308, 1e308, 1e308 })
  assert(measured.median == 1e308)
end

local function test_positive_tail_inside_its_own_noise_cannot_pass()
  local calibration, candidate: mut {Perf.Pair}, mut {Perf.Pair} = {}, {}
  for i = 1, 200 do
    calibration[i] = { a = i, b = 201 - i }
    candidate[i] = { a = 100, b = if i <= 180 then 90 else 105 end }
  end
  local measured = Perf.compare(calibration, candidate)
  local low, noise = measured.tail_interval.low, measured.tail_noise
  assert(low ~= nil and noise ~= nil and low > 0 and low < noise)
  assert(measured.delta.high <= 0 and measured.status == "inconclusive")
  assert(has_reason(measured.reasons, "positive_tail_interval"))
end

local function test_biased_tail_calibration_is_not_excused_by_median()
  local calibration, candidate: mut {Perf.Pair}, mut {Perf.Pair} = {}, {}
  for i = 1, 200 do
    calibration[i] = { a = 100, b = if i <= 180 then 100 else 105 end }
    candidate[i] = { a = 100, b = 100 }
  end
  local measured = Perf.compare(calibration, candidate)
  assert(measured.calibration.low <= 0 and measured.calibration.high >= 0)
  assert(measured.status == "inconclusive" and has_reason(measured.reasons, "biased_tail_calibration"))
end

local function test_overflowing_derived_bounds_are_refused()
  local samples: mut {Perf.Pair} = {}
  for i = 1, 200 do
    local value = if i <= 190 then -1e308 else 1e308 end
    samples[i] = { a = value, b = value }
  end
  assert(not pcall(Perf.compare, samples, samples))
end

local function test_build_history_transitions_cover_queries_docs_and_leaf_edits()
  local before = { "0", "6", "0", "PASS", "4", "4" }
  local next_run = { "0", "6", "0", "PASS", "5", "5" }
  Perf.check_transition(before, before, false, false)
  Perf.check_transition(before, next_run, true, false)
  Perf.check_transition(before, { "1", "5", "1", "PASS", "5", "5" }, true, true)
  assert(not pcall(Perf.check_transition, before, before, true, false))
  assert(not pcall(Perf.check_transition, before, next_run, false, false))
  for _, invalid in ipairs({
      { "0", "6", "0", "PASS", "6", "6" },
      { "0", "6", "0", "PASS", "5", "4" },
      { "0", "6", "1", "PASS", "5", "5" },
      { "1", "5", "0", "PASS", "5", "5" },
      { "0", "5", "0", "PASS", "5", "5" },
  }) do assert(not pcall(Perf.check_transition, before, invalid, true, false)) end
  assert(not pcall(Perf.check_transition, before, next_run, true, true))
end

local function test_shared_fixture_history_cannot_pass_pair_checks()
  local fresh = { "0", "6", "0", "PASS", "4", "4" }
  Perf.check_history(fresh, fresh)
  assert(not pcall(Perf.check_history, fresh, { "0", "6", "0", "PASS", "37", "37" }))
  assert(not pcall(Perf.check_history, fresh, { "0", "6", "0", "PASS", "4", "5" }))
end

local function argv_with(count: string): {string}
  return { "a", "b", "/nonexistent/out", count }
end

local function test_sample_counts_are_validated_apart_for_benchmark_and_lifecycle()
  -- Each refuses before it makes an output directory.
  Test.raises(function() Perf.benchmark(argv_with("29"), "perf.tl") end, "30 to 2000")
  for _, count in ipairs({ "5", "30" }) do
    local lifecycle_ok, lifecycle_trouble = pcall(Perf.rehearse, argv_with(count), "perf.tl")
    assert(not lifecycle_ok and tostring(lifecycle_trouble):find("6 to 29", 1, true) ~= nil)
  end
end
