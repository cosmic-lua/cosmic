local compare = require("perf.compare")
local pt = require("perf.perf_types")

local function results(measurements: {pt.Measurement}): pt.Results
  return {meta = {}, results = measurements}
end

local function m(name: string, wall_ns: number, spread_pct: number): pt.Measurement
  return {
    name = name,
    wall_ns = wall_ns,
    spread_pct = spread_pct,
    samples_ns = {},
    iterations = 1,
  }
end

local function find_delta(deltas: {pt.Delta}, name: string): pt.Delta
  for _, d in ipairs(deltas) do
    if d.name == name then
      return d
    end
  end
  return nil
end

local function test_unchanged_is_ok()
  local deltas, failures = compare.diff(
    results({m("a", 1000, 2)}),
    results({m("a", 1010, 2)}), 10)
  assert(failures == 0, "no failures expected")
  assert(find_delta(deltas, "a").verdict == "ok", "1% delta should be ok")
end
test_unchanged_is_ok()

local function test_regression_beyond_noise_fails()
  local deltas, failures = compare.diff(
    results({m("a", 1000, 2)}),
    results({m("a", 1300, 2)}), 10)
  assert(failures == 1, "expected 1 failure, got " .. failures)
  local d = find_delta(deltas, "a")
  assert(d.verdict == "regression", "30% slower should regress, got " .. d.verdict)
  assert(math.abs(d.delta_pct - 30.0) < 0.01, "delta_pct wrong: " .. d.delta_pct)
end
test_regression_beyond_noise_fails()

local function test_noisy_scenario_needs_bigger_delta()
  -- 30% slower but 40% spread in the baseline: not a confident regression.
  local deltas, failures = compare.diff(
    results({m("a", 1000, 40)}),
    results({m("a", 1300, 2)}), 10)
  assert(failures == 0, "noisy delta must not fail")
  local d = find_delta(deltas, "a")
  assert(d.verdict == "ok", "expected ok, got " .. d.verdict)
  assert(math.abs(d.noise_pct - 40.0) < 0.01, "noise bar wrong: " .. d.noise_pct)
end
test_noisy_scenario_needs_bigger_delta()

local function test_improvement_beyond_noise_is_faster()
  local deltas, failures = compare.diff(
    results({m("a", 1000, 2)}),
    results({m("a", 700, 2)}), 10)
  assert(failures == 0, "improvements are not failures")
  assert(find_delta(deltas, "a").verdict == "faster", "30% faster should be faster")
end
test_improvement_beyond_noise_is_faster()

local function test_new_scenario_is_not_failure()
  local deltas, failures = compare.diff(
    results({}),
    results({m("fresh", 500, 1)}), 10)
  assert(failures == 0, "new scenarios are informational")
  assert(find_delta(deltas, "fresh").verdict == "new", "expected new")
end
test_new_scenario_is_not_failure()

local function test_missing_scenario_fails()
  -- Deleting a benchmark must not be a way to hide a regression.
  local deltas, failures = compare.diff(
    results({m("gone", 500, 1)}),
    results({}), 10)
  assert(failures == 1, "missing scenario must fail")
  assert(find_delta(deltas, "gone").verdict == "missing", "expected missing")
end
test_missing_scenario_fails()

local function test_errored_scenario_fails()
  local bad: pt.Measurement = {name = "broken", samples_ns = {}, error = "boom"}
  local deltas, failures = compare.diff(
    results({m("broken", 500, 1)}),
    results({bad}), 10)
  assert(failures == 1, "errored scenario must fail")
  assert(find_delta(deltas, "broken").verdict == "error", "expected error verdict")
end
test_errored_scenario_fails()

local function test_errored_baseline_treated_as_new()
  local bad: pt.Measurement = {name = "flaky", samples_ns = {}, error = "boom"}
  local deltas, failures = compare.diff(
    results({bad}),
    results({m("flaky", 500, 1)}), 10)
  assert(failures == 0, "recovered scenario is not a failure")
  assert(find_delta(deltas, "flaky").verdict == "new", "expected new")
end
test_errored_baseline_treated_as_new()

local function test_format_summarizes()
  local deltas = compare.diff(
    results({m("a", 1000, 2), m("b", 1000, 2)}),
    results({m("a", 2000, 2), m("b", 990, 2)}), 10)
  local text = compare.format(deltas)
  assert(text:find("regression", 1, true), "report missing regression")
  assert(text:find("2 scenarios: 1 regression", 1, true),
    "summary line wrong:\n" .. text)
end
test_format_summarizes()

local function test_load_results_rejects_garbage()
  local r, err = compare.load_results("/nonexistent/path.json")
  assert(r == nil and err ~= nil, "missing file should error")

  local tmp = (os.getenv("TEST_TMPDIR") or os.getenv("TMPDIR") or "/tmp") .. "/not-results.json"
  local f = io.open(tmp, "w")
  assert(f ~= nil, "cannot create temp file")
  f:write("{\"unrelated\": true}")
  f:close()
  local r2, err2 = compare.load_results(tmp)
  assert(r2 == nil and err2 ~= nil and err2:find("results", 1, true),
    "wrong-shape file should be rejected: " .. tostring(err2))
  os.remove(tmp)
end
test_load_results_rejects_garbage()

local function test_triage_keeps_stable_regression()
  -- The regression reproduces: the A/A self-check is quiet for "a", so
  -- the regression stands and still fails the gate.
  local deltas, failures = compare.triage(
    results({m("a", 1000, 2)}), results({m("a", 1300, 2)}),
    results({m("a", 1300, 2)}), results({m("a", 1305, 2)}), 10)
  assert(failures == 1, "stable regression must still fail, got " .. failures)
  assert(find_delta(deltas, "a").verdict == "regression", "should stay regression")
end
test_triage_keeps_stable_regression()

local function test_triage_reclassifies_noisy_regression()
  -- Same +30% "regression", but the current binary swings ~-31% against
  -- itself for "a": indistinguishable from noise, so reclassify.
  local deltas, failures = compare.triage(
    results({m("a", 1000, 2)}), results({m("a", 1300, 2)}),
    results({m("a", 1300, 2)}), results({m("a", 900, 2)}), 10)
  assert(failures == 0, "noisy regression must not fail, got " .. failures)
  assert(find_delta(deltas, "a").verdict == "noise", "should reclassify to noise")
end
test_triage_reclassifies_noisy_regression()

local function test_triage_only_touches_regressions()
  -- "a" is a noisy regression -> noise; "b" is ok in the main diff even
  -- though its A/A is unstable -> triage must leave it ok, not invent a
  -- regression.
  local deltas, failures = compare.triage(
    results({m("a", 1000, 2), m("b", 1000, 2)}),
    results({m("a", 1300, 2), m("b", 1005, 2)}),
    results({m("a", 1300, 2), m("b", 1000, 2)}),
    results({m("a", 900, 2), m("b", 1400, 2)}), 10)
  assert(failures == 0, "a->noise, b ok: no failures, got " .. failures)
  assert(find_delta(deltas, "a").verdict == "noise", "a -> noise")
  assert(find_delta(deltas, "b").verdict == "ok", "b stays ok")
end
test_triage_only_touches_regressions()

local function test_triage_format_counts_noise()
  local deltas = compare.triage(
    results({m("a", 1000, 2)}), results({m("a", 1300, 2)}),
    results({m("a", 1300, 2)}), results({m("a", 900, 2)}), 10)
  local text = compare.format(deltas)
  assert(text:find("1 noise", 1, true), "summary should count noise:\n" .. text)
end
test_triage_format_counts_noise()

print("OK compare_test")
