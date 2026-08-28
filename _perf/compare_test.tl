local compare = require("_perf.compare")
local pt = require("_perf.perf_types")

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

local function test_regression_beyond_noise_fails()
  local deltas, failures = compare.diff(
    results({m("a", 1000, 2)}),
    results({m("a", 1300, 2)}), 10)
  assert(failures == 1, "expected 1 failure, got " .. failures)
  local d = find_delta(deltas, "a")
  assert(d.verdict == "regression", "30% slower should regress, got " .. d.verdict)
  assert(math.abs(d.delta_pct - 30.0) < 0.01, "delta_pct wrong: " .. d.delta_pct)
end

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

local function test_improvement_beyond_noise_is_faster()
  local deltas, failures = compare.diff(
    results({m("a", 1000, 2)}),
    results({m("a", 700, 2)}), 10)
  assert(failures == 0, "improvements are not failures")
  assert(find_delta(deltas, "a").verdict == "faster", "30% faster should be faster")
end

local function test_new_scenario_is_not_failure()
  local deltas, failures = compare.diff(
    results({}),
    results({m("fresh", 500, 1)}), 10)
  assert(failures == 0, "new scenarios are informational")
  assert(find_delta(deltas, "fresh").verdict == "new", "expected new")
end

local function test_missing_scenario_fails()
  -- Deleting a benchmark must not be a way to hide a regression.
  local deltas, failures = compare.diff(
    results({m("gone", 500, 1)}),
    results({}), 10)
  assert(failures == 1, "missing scenario must fail")
  assert(find_delta(deltas, "gone").verdict == "missing", "expected missing")
end

local function test_errored_scenario_fails()
  local bad: pt.Measurement = {name = "broken", samples_ns = {}, error = "boom"}
  local deltas, failures = compare.diff(
    results({m("broken", 500, 1)}),
    results({bad}), 10)
  assert(failures == 1, "errored scenario must fail")
  assert(find_delta(deltas, "broken").verdict == "error", "expected error verdict")
end

-- Deliberate pin: a scenario whose BASELINE row errored is a failing
-- verdict, the same way a "missing" scenario is. It must not read as
-- "new" (never gated), or a broken scenario could stay broken
-- indefinitely and silently; a fresh, passing baseline is what clears
-- it, not merely running the gate again.
local function test_errored_baseline_is_a_failure()
  local bad: pt.Measurement = {name = "flaky", samples_ns = {}, error = "boom"}
  local deltas, failures = compare.diff(
    results({bad}),
    results({m("flaky", 500, 1)}), 10)
  assert(failures == 1, "a baseline error must fail until the baseline is refreshed")
  assert(find_delta(deltas, "flaky").verdict == "baseline-error",
    "expected baseline-error, got " .. find_delta(deltas, "flaky").verdict)
end

-- A scenario truly absent from the baseline (never measured, not
-- errored) stays "new" and non-failing -- this is what makes the case
-- above about the baseline having ERRORED, not merely being incomplete.
local function test_truly_new_scenario_is_not_a_failure()
  local deltas, failures = compare.diff(
    results({}),
    results({m("brand_new", 500, 1)}), 10)
  assert(failures == 0, "a scenario absent from the baseline is not a failure")
  assert(find_delta(deltas, "brand_new").verdict == "new", "expected new")
end

-- A row with wall_ns nil and no error is malformed, not a crash: it
-- must resolve to a clean verdict rather than arithmetic on nil below.
local function test_malformed_current_row_does_not_throw()
  local malformed: pt.Measurement = {name = "odd", samples_ns = {}}
  local deltas, failures = compare.diff(
    results({m("odd", 500, 1)}),
    results({malformed}), 10)
  assert(failures == 1, "a malformed current row must fail")
  assert(find_delta(deltas, "odd").verdict == "malformed",
    "expected malformed, got " .. find_delta(deltas, "odd").verdict)
end

-- Symmetric case: a malformed BASELINE row (no error, no wall_ns) is
-- just as undiffable as a malformed current row.
local function test_malformed_baseline_row_does_not_throw()
  local malformed: pt.Measurement = {name = "odd", samples_ns = {}}
  local deltas, failures = compare.diff(
    results({malformed}),
    results({m("odd", 500, 1)}), 10)
  assert(failures == 1, "a malformed baseline row must fail")
  assert(find_delta(deltas, "odd").verdict == "malformed",
    "expected malformed, got " .. find_delta(deltas, "odd").verdict)
end

local function test_format_summarizes()
  local deltas = compare.diff(
    results({m("a", 1000, 2), m("b", 1000, 2)}),
    results({m("a", 2000, 2), m("b", 990, 2)}), 10)
  local text = compare.format(deltas)
  assert(text:find("regression", 1, true), "report missing regression")
  assert(text:find("2 scenarios: 1 regression", 1, true),
    "summary line wrong:\n" .. text)
end

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
  assert(os.remove(tmp))
end

local function test_triage_keeps_stable_regression()
  -- The regression reproduces: the A/A self-check is quiet for "a", so
  -- the regression stands and still fails the gate.
  local deltas, failures = compare.triage(
    results({m("a", 1000, 2)}), results({m("a", 1300, 2)}),
    results({m("a", 1300, 2)}), results({m("a", 1305, 2)}), 10)
  assert(failures == 1, "stable regression must still fail, got " .. failures)
  assert(find_delta(deltas, "a").verdict == "regression", "should stay regression")
end

local function test_triage_reclassifies_noisy_regression()
  -- Same +30% "regression", but the current binary swings ~-31% against
  -- itself for "a": COMPARABLE magnitude (30% is well within
  -- TRIAGE_K=2 * 31%), so it reclassifies to noise.
  local deltas, failures = compare.triage(
    results({m("a", 1000, 2)}), results({m("a", 1300, 2)}),
    results({m("a", 1300, 2)}), results({m("a", 900, 2)}), 10)
  assert(failures == 0, "noisy regression must not fail, got " .. failures)
  assert(find_delta(deltas, "a").verdict == "noise", "should reclassify to noise")
end

-- Reclassification is magnitude-aware: a regression only counts as
-- noise when its size is comparable to the self-check swing, so an
-- oversized regression is not waved through just because the
-- scenario's A/A self-check cleared the bar. A 30% self-check swing
-- does not excuse a +300% regression.
local function test_triage_large_regression_in_unstable_scenario_still_fails()
  local deltas, failures = compare.triage(
    results({m("a", 1000, 2)}), results({m("a", 4000, 2)}), -- +300%
    results({m("a", 1000, 2)}), results({m("a", 1300, 2)}), -- self: +30%
    10)
  assert(failures == 1,
    "a regression far larger than the self-check swing must still fail, got " .. failures)
  assert(find_delta(deltas, "a").verdict == "regression",
    "should stay regression, got " .. find_delta(deltas, "a").verdict)
end

-- The K=2 boundary itself: |regression| <= max(bar, K * |self delta|).
-- Here bar=10, self delta=20%, so the cutoff is exactly 40%. 40% must
-- reclassify; 41% (a hair over) must not.
local function test_triage_k_factor_boundary()
  local at_boundary = compare.triage(
    results({m("a", 1000, 2)}), results({m("a", 1400, 2)}), -- +40%
    results({m("a", 1000, 2)}), results({m("a", 1200, 2)}), -- self: +20%
    10)
  assert(find_delta(at_boundary, "a").verdict == "noise",
    "40% regression at exactly K*20% must reclassify, got " ..
    find_delta(at_boundary, "a").verdict)

  local over_boundary = compare.triage(
    results({m("a", 1000, 2)}), results({m("a", 1410, 2)}), -- +41%
    results({m("a", 1000, 2)}), results({m("a", 1200, 2)}), -- self: +20%
    10)
  assert(find_delta(over_boundary, "a").verdict == "regression",
    "41% regression just past K*20% must stay regression, got " ..
    find_delta(over_boundary, "a").verdict)
end

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

local function test_triage_format_counts_noise()
  local deltas = compare.triage(
    results({m("a", 1000, 2)}), results({m("a", 1300, 2)}),
    results({m("a", 1300, 2)}), results({m("a", 900, 2)}), 10)
  local text = compare.format(deltas)
  assert(text:find("1 noise", 1, true), "summary should count noise:\n" .. text)
end

-- The release lane's json_decode_large flag, in numbers: 798.63µs ->
-- 891.35µs is +11.6%, and the same binary drifts ~12.6% between two of
-- its three runs while reading ~+0.4% between the other two. Triaging
-- against only the quiet pair keeps the regression and holds the
-- release; reading the LOUDEST pair reclassifies it, because 11.6 is
-- within TRIAGE_K=2 * 12.6.
local function test_the_loudest_control_pair_sets_the_noise_credit()
  local base = results({m("json_decode_large", 798630, 2)})
  local cur = results({m("json_decode_large", 891350, 2)})
  local c1 = results({m("json_decode_large", 1210000, 2)})
  local c2 = results({m("json_decode_large", 1215000, 2)})
  local c3 = results({m("json_decode_large", 1362460, 2)})

  local quiet_only, quiet_failures = compare.triage_many(base, cur, {c1, c2}, 10)
  assert(quiet_failures == 1,
    "the quiet pair alone must keep the regression, got " .. quiet_failures)
  assert(find_delta(quiet_only, "json_decode_large").verdict == "regression",
    "quiet pair: stays regression")

  local deltas, failures = compare.triage_many(base, cur, {c1, c2, c3}, 10)
  assert(failures == 0,
    "the loud pair must reclassify it, got " .. failures)
  assert(find_delta(deltas, "json_decode_large").verdict == "noise",
    "loudest pair: reclassifies to noise")
end

-- The other half of the same release flag, and the property that makes
-- the change a fix rather than a hole: codec_base64_roundtrip_64k went
-- 132.05µs -> 159.82µs (+21.0%) while the same binary held within 4.8%
-- of itself. 21.0 > max(10, 2 * 4.8), so no control pair excuses it and
-- the gate still refuses the release.
local function test_a_real_regression_survives_every_control_pair()
  local base = results({m("codec_base64_roundtrip_64k", 132050, 2)})
  local cur = results({m("codec_base64_roundtrip_64k", 159820, 2)})
  local c1 = results({m("codec_base64_roundtrip_64k", 193460, 2)})
  local c2 = results({m("codec_base64_roundtrip_64k", 196180, 2)})
  local c3 = results({m("codec_base64_roundtrip_64k", 202750, 2)})

  local deltas, failures = compare.triage_many(base, cur, {c1, c2, c3}, 10)
  assert(failures == 1,
    "a real regression must still fail, got " .. failures)
  assert(find_delta(deltas, "codec_base64_roundtrip_64k").verdict == "regression",
    "stays regression across every pair")
end

-- The identity header. A report's two sides come from two FILES, so the
-- binary each was measured on is said once above the table.

local function sha_results(measurements: {pt.Measurement}, bin_sha?: string): pt.Results
  local meta: pt.Meta = {}
  if bin_sha then
    meta.bin_sha = bin_sha
  end
  return {meta = meta, results = measurements}
end

local function test_identity_header_says_same_for_one_binary()
  local line = compare.format_identity(
    sha_results({m("a", 1000, 2)}, "145057b9fe90aabbccdd"),
    sha_results({m("a", 1010, 2)}, "145057b9fe90aabbccdd"))
  assert(line == "binaries: base 145057b9fe90  current 145057b9fe90  (same)",
    "got: " .. line)
end

local function test_identity_header_says_differ_for_two_binaries()
  local line = compare.format_identity(
    sha_results({m("a", 1000, 2)}, "145057b9fe90aabbccdd"),
    sha_results({m("a", 1010, 2)}, "9f2c1ab30de4aabbccdd"))
  assert(line == "binaries: base 145057b9fe90  current 9f2c1ab30de4  (differ)",
    "got: " .. line)
end

-- A side with no stamp is `unknown`, and the pair is `(unverifiable)` --
-- never `(same)`, which would assert what neither file says.
local function test_identity_header_is_unverifiable_without_a_stamp()
  local line = compare.format_identity(
    sha_results({m("a", 1000, 2)}, "145057b9fe90aabbccdd"),
    sha_results({m("a", 1010, 2)}))
  assert(line == "binaries: base 145057b9fe90  current unknown  (unverifiable)",
    "got: " .. line)
end

-- The identity arguments are optional, and a caller that omits them
-- gets exactly the table and summary it got before the header existed.
local function test_format_without_identity_is_the_bare_report()
  local base = sha_results({m("a", 1000, 2)}, "145057b9fe90aabbccdd")
  local cur = sha_results({m("a", 1010, 2)}, "145057b9fe90aabbccdd")
  local deltas = compare.diff(base, cur, 10)
  local bare = compare.format(deltas)
  local lines: {string} = {}
  for line in bare:gmatch("[^\n]+") do
    lines[#lines + 1] = line
  end
  assert(#lines == 2, "one row and one summary, got " .. #lines)
  assert(lines[1] == compare.format_delta(deltas[1]), "got: " .. lines[1])
  assert(bare:find("binaries:", 1, true) == nil, "no header without both files")
  assert(compare.format(deltas, base, cur) ==
    compare.format_identity(base, cur) .. "\n" .. bare,
    "both files given: the header is prepended and nothing else moves")
end

print("OK compare_test")
