#!/usr/bin/env cosmic
--- Tests for the perf gate's reproduction rule: the strike-twice
--- filter that fails a regression only when two independent
--- current-side samples flag it, and the baseline retry that gives
--- those two samples one common baseline to be judged against. The
--- measure function is injected, so each path is exercised with
--- fabricated results files and no real benchmarks.

local fs = require("cosmic.fs")
local gate = require("_perf.gate")
local json = require("cosmic.json")

local tmpdir = os.getenv("TEST_TMPDIR") or "/tmp"

--- Fabricate a results file, one scenario per (name -> wall_ns) entry.
local function write_multi(path: string, rows: {string: number}, bin_sha?: string)
  local results: {{string: any}} = {}
  for name, wall_ns in pairs(rows) do
    results[#results + 1] = {
      name = name, wall_ns = wall_ns, spread_pct = 2,
      samples_ns = {}, iterations = 1,
    }
  end
  local payload: {string: any} = {meta = {bin_sha = bin_sha}, results = results}
  local encoded = json.encode(payload)
  assert(fs.write(path, encoded))
end

local function write_results(path: string, wall_ns: number, bin_sha?: string)
  write_multi(path, {scenario = wall_ns}, bin_sha)
end

local function paths(prefix: string): string, string, string
  return fs.join(tmpdir, prefix .. "-base.json"),
  fs.join(tmpdir, prefix .. "-cur.json"),
  fs.join(tmpdir, prefix .. "-selfb.json")
end

-- The strike-twice rule. Pass 1 flags only `a`; the retry reads `a`
-- quiet but flags `b` for the first time, and the controls agree with
-- the retry (cur's sha differs so it drops; the remaining pair is
-- quiet — no triage credit). Before the rule, `b` failed the gate on
-- that single appearance: run 33034667243 attempt 2, disjoint flag sets.
local function test_strike_once_regression_reclassifies_and_passes()
  local base, cur, selfb = paths("strike-once")
  write_multi(base, {a = 1000, b = 1000}, "aaaa1111")
  write_multi(cur, {a = 1300, b = 1000}, "bbbb2222")
  local calls = 0
  local code = gate.gate({
      baseline = base, current = cur, selfcheck_b = selfb, threshold = 10,
      measure = function(out: string): integer
        calls = calls + 1
        write_multi(out, {a = 1000, b = 1300}, "cccc3333")
        return 0
      end,
    })
  assert(code == 0,
    "a regression flagging only in the retry did not reproduce, got " .. code)
  assert(calls == 2, "expected re-measure + selfcheck-b, got " .. calls)
end

-- ...and only the strike-once flag reclassifies: `a`, striking in both
-- passes, still fails the same run that waves `b` through as noise.
local function test_strike_twice_regression_still_fails()
  local base, cur, selfb = paths("strike-twice")
  write_multi(base, {a = 1000, b = 1000}, "aaaa1111")
  write_multi(cur, {a = 1300, b = 1000}, "bbbb2222")
  local calls = 0
  local code = gate.gate({
      baseline = base, current = cur, selfcheck_b = selfb, threshold = 10,
      measure = function(out: string): integer
        calls = calls + 1
        write_multi(out, {a = 1300, b = 1300}, "cccc3333")
        return 0
      end,
    })
  assert(code == 1,
    "a regression striking in both passes must still fail, got " .. code)
  assert(calls == 2, "expected re-measure + selfcheck-b, got " .. calls)
end

-- The other failure mode from that run: the baseline is measured once,
-- so a one-off low reading there anchors every pass (attempt 1 flagged
-- http_stream_read_1mb off a baseline reading the same binary disowned
-- next attempt). With measure_baseline set, the retry re-measures BOTH
-- sides and pass 2 reads the washed-out baseline.
local function test_baseline_retry_rescues_a_one_off_baseline_reading()
  local base, cur, selfb = paths("base-retry")
  write_results(base, 1000, "aaaa1111") -- the one-off: reads 1300 on retry
  write_results(cur, 1300, "bbbb2222")
  local bcalls = 0
  local bpath: string = nil
  local code = gate.gate({
      baseline = base, current = cur, selfcheck_b = selfb, threshold = 10,
      measure = function(out: string): integer
        write_results(out, 1300, "bbbb2222") -- the current side holds steady
        return 0
      end,
      measure_baseline = function(out: string): integer
        bcalls = bcalls + 1
        bpath = out
        write_results(out, 1300, "aaaa1111")
        return 0
      end,
    })
  assert(code == 0,
    "a baseline retry must wash out a one-off baseline reading, got " .. code)
  assert(bcalls == 1, "expected exactly one baseline re-measure, got " .. bcalls)
  assert(bpath ~= nil and bpath:match("%-base%-retry%.json$"),
    "the baseline retry gets BASE's own -retry.json sibling, got " .. tostring(bpath))
end

-- A baseline retry that names a different binary than the baseline file
-- re-measured the wrong thing; trusting it would compare the candidate
-- against a stranger.
local function test_baseline_retry_naming_a_different_binary_is_refused()
  local base, cur, selfb = paths("base-retry-identity")
  write_results(base, 1000, "aaaa1111")
  write_results(cur, 1300, "bbbb2222")
  local bcalls = 0
  local code = gate.gate({
      baseline = base, current = cur, selfcheck_b = selfb, threshold = 10,
      measure = function(out: string): integer
        write_results(out, 1300, "bbbb2222")
        return 0
      end,
      measure_baseline = function(out: string): integer
        bcalls = bcalls + 1
        write_results(out, 1300, "dddd4444") -- not the baseline's binary
        return 0
      end,
    })
  assert(code == 1,
    "a baseline retry naming a different binary must refuse, got " .. code)
  assert(bcalls == 1, "must refuse right after the baseline retry, got " .. bcalls)
end

-- The masked baseline. Pass 1's `b` reads slow on the BASELINE side, so
-- the true +30% regression there is hidden; pass 2 judges against the
-- honest baseline retry and flags it. Keying the reproduction rule to
-- pass 1's flags would call that "flagged only in the retry" and
-- publish the regression, so the flags are re-keyed to the re-measured
-- baseline: two independent current-side samples, one common baseline.
local function test_masked_baseline_regression_still_fails()
  local base, cur, selfb = paths("masked-base")
  write_multi(base, {a = 1000, b = 1300}, "aaaa1111") -- b's 1300 is the one-off
  write_multi(cur, {a = 1300, b = 1300}, "bbbb2222")
  local code = gate.gate({
      baseline = base, current = cur, selfcheck_b = selfb, threshold = 10,
      measure = function(out: string): integer
        write_multi(out, {a = 1000, b = 1300}, "bbbb2222")
        return 0
      end,
      measure_baseline = function(out: string): integer
        write_multi(out, {a = 1000, b = 1000}, "aaaa1111")
        return 0
      end,
    })
  assert(code == 1,
    "a regression the pass-1 baseline masked must still fail, got " .. code)
end

-- The accepted cost, in the false-positive direction. `x` is steady on
-- every current-side run and the BASELINE retry is the one-off fast
-- reading, so both current samples flag against it and the gate fails
-- where the old rule passed. The controls are all quiet, so nothing
-- absorbs it -- a false red costs one workflow re-run, which is the
-- cheaper of the two errors.
local function test_a_one_off_fast_baseline_retry_fails_the_gate()
  local base, cur, selfb = paths("fast-base-retry")
  write_multi(base, {a = 1000, x = 1000}, "aaaa1111")
  write_multi(cur, {a = 1300, x = 1000}, "bbbb2222")
  local code = gate.gate({
      baseline = base, current = cur, selfcheck_b = selfb, threshold = 10,
      measure = function(out: string): integer
        write_multi(out, {a = 1000, x = 1000}, "bbbb2222")
        return 0
      end,
      measure_baseline = function(out: string): integer
        write_multi(out, {a = 1000, x = 700}, "aaaa1111") -- the one-off
        return 0
      end,
    })
  assert(code == 1,
    "a one-off fast baseline retry on a stable scenario fails, got " .. code)
end

-- ...and the guard on that cost. Same numbers, except `x` also swings
-- on the current side: the A/A control pair reads +30%, which is
-- TRIAGE_K-comparable to the +42.9% flag, so the existing noise credit
-- absorbs it and the gate passes. A scenario unstable enough to
-- produce a one-off baseline reading is normally unstable on the
-- current side too, where the credit already lives.
local function test_current_side_instability_absorbs_the_fast_baseline_retry()
  local base, cur, selfb = paths("unstable-current")
  write_multi(base, {a = 1000, x = 1000}, "aaaa1111")
  write_multi(cur, {a = 1300, x = 1000}, "bbbb2222")
  local calls = 0
  local code = gate.gate({
      baseline = base, current = cur, selfcheck_b = selfb, threshold = 10,
      measure = function(out: string): integer
        calls = calls + 1
        write_multi(out, {a = 1000, x = calls == 1 and 1000 or 1300}, "bbbb2222")
        return 0
      end,
      measure_baseline = function(out: string): integer
        write_multi(out, {a = 1000, x = 700}, "aaaa1111")
        return 0
      end,
    })
  assert(code == 0,
    "current-side instability must absorb the baseline retry, got " .. code)
  assert(calls == 2, "expected re-measure + selfcheck-b, got " .. calls)
end
