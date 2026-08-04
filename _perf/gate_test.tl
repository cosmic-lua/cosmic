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

local function write_results(path: string, wall_ns: number, bin_sha?: string)
  local payload = {
    meta = {bin_sha = bin_sha},
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
  -- The +30% regression and the A/A control's ~+38% swing are
  -- COMPARABLE magnitudes (30% is well within TRIAGE_K=2 * 38%), which
  -- is what makes this reclassification legitimate rather than a
  -- magnitude-blind wave-through -- see
  -- test_large_regression_survives_unstable_selfcheck_and_fails below
  -- for the case where the sizes do NOT match and it must still fail.
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

-- Magnitude-blindness was the bug: a scenario's A/A self-check clearing
-- the bar used to wave through ANY regression there, even one far
-- larger than the self-check swing itself. A +300% regression must
-- still fail even though this scenario's A/A control is measurably
-- unstable (+30%) -- the instability just isn't big enough to explain
-- the regression.
local function test_large_regression_survives_unstable_selfcheck_and_fails()
  local base, cur, selfb = paths("large-unstable")
  write_results(base, 1000)
  write_results(cur, 4000) -- +300%
  local calls = 0
  local code = gate.gate({
      baseline = base, current = cur, selfcheck_b = selfb, threshold = 10,
      measure = function(out: string): integer
        calls = calls + 1
        if calls == 1 then
          write_results(out, 4000) -- regression persists on re-measurement
        else
          write_results(out, 5200) -- A/A control swings +30%: unstable, but
          -- nowhere near +300%
        end
        return 0
      end,
    })
  assert(code == 1,
    "a regression far larger than the self-check swing must still fail, got " .. code)
  assert(calls == 2, "expected re-measure + selfcheck-b, got " .. calls)
end
test_large_regression_survives_unstable_selfcheck_and_fails()

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

-- The identity rules. `meta.bin` is a NAME -- two runs forty commits
-- apart both say `o/bin/cosmic` -- so the gate reads `bin_sha`, and
-- refuses the two pairings that answer confidently about the wrong
-- thing.
local function test_compare_refuses_a_binary_against_itself()
  local base, cur, selfb = paths("same-bin")
  write_results(base, 1000, "aaaa1111")
  write_results(cur, 1010, "aaaa1111")
  local calls = 0
  local code = gate.gate({
      baseline = base, current = cur, selfcheck_b = selfb, threshold = 10,
      measure = function(_out: string): integer
        calls = calls + 1
        return 0
      end,
    })
  assert(code == 1, "comparing a binary with itself must refuse, got " .. code)
  assert(calls == 0, "and refuse before measuring anything, got " .. calls)
end
test_compare_refuses_a_binary_against_itself()

-- The same pair naming DIFFERENT binaries is the comparison the gate
-- exists for, so it runs -- which is what makes the refusal above about
-- identity rather than about the field being present.
local function test_compare_runs_when_the_binaries_differ()
  local base, cur, selfb = paths("diff-bin")
  write_results(base, 1000, "aaaa1111")
  write_results(cur, 1010, "bbbb2222")
  local code = gate.gate({
      baseline = base, current = cur, selfcheck_b = selfb, threshold = 10,
      measure = function(_out: string): integer
        return 0
      end,
    })
  assert(code == 0, "a real comparison must proceed, got " .. code)
end
test_compare_runs_when_the_binaries_differ()

-- A noise floor is only a noise floor if the subject is constant.
-- Measured across two binaries it reports the change as noise and
-- raises the bar every real regression afterwards has to clear.
local function test_selfcheck_refuses_two_different_binaries()
  local a, b = paths("selfcheck-bins")
  write_results(a, 1000, "aaaa1111")
  write_results(b, 1010, "bbbb2222")
  local code = gate.selfcheck({
      a = a, b = b, threshold = 10,
      measure = function(_out: string): integer
        return 0
      end,
    })
  assert(code == 1,
    "an A/A control across two binaries must refuse, got " .. code)
end
test_selfcheck_refuses_two_different_binaries()

-- A file that does not say what it measured cannot be checked either
-- way. It says so on stderr and the comparison proceeds, so a results
-- file written before the field existed stays readable.
-- The retry's `opts.measure(opts.current)` overwrites current.json under
-- whatever binary happens to be running at that moment. If that binary
-- is the SAME as the baseline's, the retry's own re-compare would read
-- "no regression" for the wrong reason -- current now equals baseline by
-- construction, not because the change was clean. The post-measure
-- identity check must catch that before trusting the re-compare.
local function test_retry_remeasurement_changing_identity_is_refused()
  local base, cur, selfb = paths("retry-identity-flip")
  write_results(base, 1000, "aaaa1111")
  write_results(cur, 1300, "bbbb2222")
  local calls = 0
  local code = gate.gate({
      baseline = base, current = cur, selfcheck_b = selfb, threshold = 10,
      measure = function(out: string): integer
        calls = calls + 1
        -- comes back quiet, but now names the BASELINE's binary
        write_results(out, 1010, "aaaa1111")
        return 0
      end,
    })
  assert(code == 1,
    "an identity flip on the retried file must refuse, got " .. code)
  assert(calls == 1,
    "must refuse right after the retry, before any A/A step, got " .. calls)
end
test_retry_remeasurement_changing_identity_is_refused()

-- Before triage() trusts the A/A pair as a noise floor, `current` and
-- `selfcheck_b` must name the SAME binary -- otherwise the "noise floor"
-- is really two different binaries, which raises the bar every real
-- regression afterwards has to clear.
local function test_aa_control_naming_different_binary_is_refused()
  local base, cur, selfb = paths("aa-identity-mismatch")
  write_results(base, 1000, "aaaa1111")
  write_results(cur, 1300, "bbbb2222")
  local calls = 0
  local code = gate.gate({
      baseline = base, current = cur, selfcheck_b = selfb, threshold = 10,
      measure = function(out: string): integer
        calls = calls + 1
        if calls == 1 then
          write_results(out, 1300, "bbbb2222") -- persists, same binary as cur
        else
          write_results(out, 1310, "cccc3333") -- A/A control: a THIRD binary
        end
        return 0
      end,
    })
  assert(code == 1,
    "an A/A control naming a different binary than current must refuse, got " .. code)
  assert(calls == 2,
    "must measure the retry and the A/A control before refusing, got " .. calls)
end
test_aa_control_naming_different_binary_is_refused()

local function test_a_file_without_a_sha_is_not_refused()
  local base, cur, selfb = paths("no-sha")
  write_results(base, 1000)
  write_results(cur, 1010)
  local code = gate.gate({
      baseline = base, current = cur, selfcheck_b = selfb, threshold = 10,
      measure = function(_out: string): integer
        return 0
      end,
    })
  assert(code == 0, "an unidentified pair still compares, got " .. code)
end
test_a_file_without_a_sha_is_not_refused()
