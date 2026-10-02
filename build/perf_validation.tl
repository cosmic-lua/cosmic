--- Fixed synthetic validation; no executable measurements are inputs.
--- Run: o/bin/cosmic build/perf_validation.tl /tmp/perf-validation.json
local Perf = require("build.perf")
local Fs = require("cosmic.fs")
local Json = require("cosmic.json")

local record Validation
end

local record Source
  state: integer
end

local function uniform(source: Source): number
  source.state = source.state * 16807 % 2147483647
  return source.state / 2147483647
end

local function normal(source: Source): number
  return math.sqrt(-2 * math.log(uniform(source))) * math.cos(2 * math.pi * uniform(source))
end

local function draw(source: Source, population: integer, tail_multiplier: number): number
  if population == 1 then return 100 + 10 * normal(source) end
  if population == 2 then return -100 * math.log(uniform(source)) end
  if population == 3 then return 100 * math.exp(normal(source)) end
  if uniform(source) < 0.9 then return 90 + 20 * uniform(source) end
  return (180 + 40 * uniform(source)) * tail_multiplier
end

local function median(population: integer): number
  if population == 2 then return 100 * math.log(2) end
  if population == 4 then return 90 + 20 * 0.5 / 0.9 end
  return 100
end

local function p95(population: integer): number
  if population == 1 then return 100 + 10 * 1.6448536269514722 end
  if population == 2 then return -100 * math.log(0.05) end
  if population == 3 then return 100 * math.exp(1.6448536269514722) end
  return 200
end

local record Case
  name: string
  population: integer
  shift: number
  tail_multiplier: number
  sizes: {integer}
  gate: string
  stress: integer
end

local function cases(): {Case}
  local result: {Case} = {}
  local names = { "normal", "exponential", "lognormal", "mixture" }
  for population = 1, 4 do
    result[#result + 1] = { name = "null_" .. names[population], population = population,
      shift = 0, tail_multiplier = 1, sizes = { 30, 100, 200, 400 }, gate = "null", stress = 0 }
  end
  result[#result + 1] = { name = "normal_shift_1sd", population = 1, shift = 10,
    tail_multiplier = 1, sizes = { 200 }, gate = "shift", stress = 0 }
  result[#result + 1] = { name = "mixture_tail_double", population = 4, shift = 0,
    tail_multiplier = 2, sizes = { 400 }, gate = "tail", stress = 0 }
  for population = 1, 4 do
    for _, fraction in ipairs({ 0.05, 0.10 }) do
      result[#result + 1] = { name = names[population] .. "_shift_" .. fraction,
        population = population, shift = median(population) * fraction,
        tail_multiplier = 1, sizes = { 200, 400 }, gate = "advisory", stress = 0 }
    end
  end
  for _, multiplier in ipairs({ 1.2, 1.5 }) do
    result[#result + 1] = { name = "mixture_tail_" .. multiplier, population = 4,
      shift = 0, tail_multiplier = multiplier, sizes = { 200, 400 }, gate = "advisory", stress = 0 }
  end
  result[#result + 1] = { name = "paired_common_delay", population = 1, shift = 0,
    tail_multiplier = 1, sizes = { 200, 400 }, gate = "advisory", stress = 1 }
  result[#result + 1] = { name = "order_and_drift", population = 1, shift = 0,
    tail_multiplier = 1, sizes = { 200, 400 }, gate = "advisory", stress = 2 }
  return result
end

local function samples(source: Source, case: Case, n: integer, calibration: boolean): {Perf.Pair}
  local result: {Perf.Pair} = {}
  for i = 1, n do
    local a = draw(source, case.population, 1)
    local b = draw(source, case.population, calibration and 1 or case.tail_multiplier)
    if not calibration then b = b + case.shift end
    if case.stress == 1 then
      local delay = 40 * uniform(source)
      a, b = a + delay, b + delay
    elseif case.stress == 2 then
      a, b = a + 0.05 * i, b + 0.05 * i
      if i % 2 == 0 then a = a + 10 else b = b + 10 end
    end
    result[i] = { a = a, b = b }
  end
  return result
end

local record Count
  hits: integer
  total: integer
  finite: integer
end

local function observe(counts: {string:Count}, name: string, hit: boolean, finite?: boolean)
  local count = counts[name]
  if count == nil then
    count = { hits = 0, total = 0, finite = 0 }
    counts[name] = count
  end
  count.total = count.total + 1
  if hit then count.hits = count.hits + 1 end
  if finite ~= false then count.finite = count.finite + 1 end
end

local function inside(low: number | nil, high: number | nil, truth: number): boolean
  return (low == nil or low <= truth) and (high == nil or high >= truth)
end

local function cover(counts: {string:Count}, name: string, bounds: Perf.Interval, truth: number)
  observe(counts, name, inside(bounds.low, bounds.high, truth), bounds.lower_bounded and bounds.upper_bounded)
end

local function rate(count: Count): {string:number}
  local n, proportion = count.total, count.hits / count.total
  local z = 1.959963984540054
  local denominator = 1 + z * z / n
  local center = (proportion + z * z / (2 * n)) / denominator
  local half = z / denominator * math.sqrt(proportion * (1 - proportion) / n + z * z / (4 * n * n))
  return { hits = count.hits, trials = n, finite = count.finite, rate = proportion,
    wilson95_low = center - half, wilson95_high = center + half }
end

local reason_keys = { "exploratory_sample_count", "unbounded_tail_interval", "biased_median_calibration",
  "biased_tail_calibration", "positive_median_interval", "positive_tail_interval", "increased_dispersion" }

local coverage_keys = { "coverage_median_a", "coverage_median_b", "coverage_median_delta",
  "coverage_aa_median", "coverage_tail_delta", "coverage_aa_tail" }

local function simulate(case: Case, index: integer, n: integer): {string:any}, boolean
  local bases = { 104729, 130363, 155921, 196613 }
  local counts: {string:Count} = {}
  for trial = 1, 5000 do
    local source: Source = { state = (bases[(index - 1) % 4 + 1] + 1009 * index +
      9176 * n + 104729 * trial) % 2147483646 + 1 }
    local calibration = samples(source, case, n, true)
    local candidate = samples(source, case, n, false)
    local reading = Perf.compare(calibration, candidate)
    observe(counts, "pass", reading.status == "pass")
    observe(counts, "regression", reading.status == "regression")
    observe(counts, "blocked", reading.status ~= "pass")
    observe(counts, "median_positive", reading.delta.low > 0)
    observe(counts, "aa_median_positive", reading.calibration.low > 0)
    local aa_tail_low = reading.calibration_tail_interval.low
    observe(counts, "aa_tail_positive", aa_tail_low ~= nil and aa_tail_low > 0)
    local reasons: {string:boolean} = {}
    for _, reason in ipairs(reading.reasons) do reasons[reason] = true end
    for _, reason in ipairs(reason_keys) do observe(counts, "reason_" .. reason, reasons[reason] == true) end
    local tail_low = reading.tail_interval.low
    observe(counts, "tail_positive", tail_low ~= nil and tail_low > 0)
    if case.gate == "null" or case.stress == 1 then
      local true_median, true_p95 = median(case.population), p95(case.population)
      if case.stress == 1 then true_median = true_median + 20 end
      observe(counts, "coverage_median_a", inside(reading.a.low, reading.a.high, true_median))
      observe(counts, "coverage_median_b", inside(reading.b.low, reading.b.high, true_median))
      observe(counts, "coverage_median_delta", inside(reading.delta.low, reading.delta.high, 0))
      observe(counts, "coverage_aa_median", inside(reading.calibration.low, reading.calibration.high, 0))
      cover(counts, "coverage_tail_delta", reading.tail_interval, 0)
      cover(counts, "coverage_aa_tail", reading.calibration_tail_interval, 0)
      if case.stress == 0 then
        cover(counts, "coverage_p95_a", reading.a.p95_interval, true_p95)
        cover(counts, "coverage_p95_b", reading.b.p95_interval, true_p95)
      end
    end
  end
  local failures: {string} = {}
  if case.gate == "null" then
    if n < 200 then
      if counts["pass"].hits ~= 0 then failures[#failures + 1] = "exploratory_pass" end
    else
      for _, key in ipairs(coverage_keys) do
        if counts[key].hits / 5000 < 0.94 then failures[#failures + 1] = key end
      end
      if counts["regression"].hits / 5000 > 0.06 then failures[#failures + 1] = "false_regression" end
      if counts["pass"].hits / 5000 < 0.80 then failures[#failures + 1] = "null_pass_rate" end
    end
  elseif case.gate == "shift" then
    if counts["blocked"].hits / 5000 < 0.95 then failures[#failures + 1] = "shift_detection" end
  elseif case.gate == "tail" then
    if counts["blocked"].hits / 5000 < 0.85 then failures[#failures + 1] = "tail_detection" end
  end
  local rates: {string:{string:number}} = {}
  for name, count in pairs(counts) do rates[name] = rate(count) end
  return { case = index, name = case.name, n = n, gate = case.gate, rates = rates,
    failures = failures, passed = #failures == 0 }, #failures == 0
end

--- Run the frozen numerical populations and persist every case as it finishes.
function Validation.main(argv: {integer:string}): integer
  assert(argv[1] ~= nil and argv[2] == nil, "usage: cosmic build/perf_validation.tl NEW_REPORT.json")
  local exists, trouble = Fs.exists(argv[1])
  assert(exists ~= nil, trouble)
  assert(not exists, "report already exists")
  local results: {{string:any}} = {}
  local passed = true
  for index, case in ipairs(cases()) do
    for _, n in ipairs(case.sizes) do
      local result, ok = simulate(case, index, n)
      results[#results + 1], passed = result, passed and ok
      assert(Fs.write(argv[1], assert(Json.encode({ protocol = "doc/performance/validation.md",
        trials_per_case = 5000, results = results, passed = passed }, { pretty = true })) .. "\n"))
      print(case.name .. " n=" .. n .. ": " .. (ok and "PASS" or "FAIL"))
    end
  end
  return passed and 0 or 2
end

return Validation
