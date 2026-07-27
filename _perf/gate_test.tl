#!/usr/bin/env cosmic
--- Tests for the perf gate orchestration: the retry and A/A triage
--- flows, which are testable precisely because they are Teal rather
--- than ||-chains in a make recipe. The measure function is injected,
--- so each path is exercised with fabricated results files and no real
--- benchmarks.

local fs = require("cosmic.fs")
local gate = require("_perf.gate")
local json = require("cosmic.json")

local tmpdir = os.getenv("TEST_TMPDIR") or "/tmp"

local function write_results(path: string, wall_ns: number)
  local payload = {
    meta = {},
    results = {
      {
        name = "scenario",
        wall_ns = wall_ns,
        spread_pct = 2,
        samples_ns = {},
        iterations = 1,
      },
    },
  }
  local encoded = json.encode(payload)
  assert(fs.write(path, encoded))
end

local function paths(prefix: string): string, string, string
  return fs.join(tmpdir, prefix .. "-base.json"),
  fs.join(tmpdir, prefix .. "-cur.json"),
  fs.join(tmpdir, prefix .. "-selfb.json")
end

local function test_clean_compare_measures_nothing()
  local base, cur, selfb = paths("clean")
  write_results(base, 1000)
  write_results(cur, 1010)
  local calls = 0
  local code = gate.gate({
      baseline = base, current = cur, selfcheck_b = selfb, threshold = 10,
      measure = function(_out: string): integer
        calls = calls + 1
        return 0
      end,
    })
  assert(code == 0, "clean compare must pass, got " .. code)
  assert(calls == 0, "clean compare must not re-measure, got " .. calls)
end
test_clean_compare_measures_nothing()

local function test_flagged_regression_retries_then_passes()
  local base, cur, selfb = paths("retry")
  write_results(base, 1000)
  write_results(cur, 1300)
  local calls = 0
  local code = gate.gate({
      baseline = base, current = cur, selfcheck_b = selfb, threshold = 10,
      measure = function(out: string): integer
        calls = calls + 1
        write_results(out, 1010) -- the re-measurement comes back quiet
        return 0
      end,
    })
  assert(code == 0, "noise filtered by the retry must pass, got " .. code)
  assert(calls == 1, "expected exactly one re-measurement, got " .. calls)
end
test_flagged_regression_retries_then_passes()

local function test_persistent_regression_triaged_as_noise_passes()
  local base, cur, selfb = paths("noise")
  write_results(base, 1000)
  write_results(cur, 1300)
  local calls = 0
  local code = gate.gate({
      baseline = base, current = cur, selfcheck_b = selfb, threshold = 10,
      measure = function(out: string): integer
        calls = calls + 1
        if calls == 1 then
          write_results(out, 1300) -- regression persists on re-measurement
        else
          write_results(out, 1800) -- A/A control swings just as hard: noise
        end
        return 0
      end,
    })
  assert(code == 0, "A/A-reclassified noise must pass, got " .. code)
  assert(calls == 2, "expected re-measure + selfcheck-b, got " .. calls)
end
test_persistent_regression_triaged_as_noise_passes()

local function test_real_regression_survives_triage_and_fails()
  local base, cur, selfb = paths("real")
  write_results(base, 1000)
  write_results(cur, 1300)
  local calls = 0
  local code = gate.gate({
      baseline = base, current = cur, selfcheck_b = selfb, threshold = 10,
      measure = function(out: string): integer
        calls = calls + 1
        if calls == 1 then
          write_results(out, 1300) -- persists
        else
          write_results(out, 1310) -- A/A control is quiet: it is real
        end
        return 0
      end,
    })
  assert(code == 1, "a real regression must fail the gate, got " .. code)
  assert(calls == 2, "expected re-measure + selfcheck-b, got " .. calls)
end
test_real_regression_survives_triage_and_fails()

local function test_measure_failure_propagates()
  local base, cur, selfb = paths("mfail")
  write_results(base, 1000)
  write_results(cur, 1300)
  local code = gate.gate({
      baseline = base, current = cur, selfcheck_b = selfb, threshold = 10,
      measure = function(_out: string): integer
        return 3
      end,
    })
  assert(code == 3, "a failed measurement must propagate its code, got " .. code)
end
test_measure_failure_propagates()

local function test_selfcheck_reports_quiet_and_noisy()
  local a, b, _ = paths("self")
  local code = gate.selfcheck({
      a = a, b = b, threshold = 10,
      measure = function(out: string): integer
        write_results(out, out == a and 1000 or 1010)
        return 0
      end,
    })
  assert(code == 0, "quiet selfcheck exits 0, got " .. code)
  code = gate.selfcheck({
      a = a, b = b, threshold = 10,
      measure = function(out: string): integer
        write_results(out, out == a and 1000 or 1500)
        return 0
      end,
    })
  assert(code == 0, "noisy selfcheck is informational and exits 0, got " .. code)
end
test_selfcheck_reports_quiet_and_noisy()

local function test_missing_baseline_fails_loudly()
  local base, cur, selfb = paths("missing")
  write_results(cur, 1000)
  local code = gate.gate({
      baseline = base, current = cur, selfcheck_b = selfb, threshold = 10,
      measure = function(_out: string): integer
        return 0
      end,
    })
  assert(code == 1, "a missing baseline must fail, got " .. code)
end
test_missing_baseline_fails_loudly()

local function test_main_parses_positionals_without_separator()
  -- the cosmic dispatcher consumes a standalone "--", so main takes its
  -- paths positionally; a missing file must reach the gate (exit 1),
  -- never the usage error (exit 2)
  local code = gate.main("compare", "no.json", "such.json", "file.json",
    "--threshold", "10", "--samples", "1")
  assert(code == 1, "positional parse must reach the gate, got " .. code)
  code = gate.main("bogus-mode")
  assert(code == 2, "unknown mode must print usage, got " .. code)
end
test_main_parses_positionals_without_separator()
