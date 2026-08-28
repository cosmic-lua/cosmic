#!/usr/bin/env cosmic
--- Tests for the gate's binary-identity rules: which runs may serve as
--- same-binary noise controls, and what happens to a pair the gate
--- requires to match when one side records no `bin_sha`. A stampless
--- file names no binary, so it can neither prove sameness nor earn a
--- control seat on the strength of not having been refused.

local fs = require("cosmic.fs")
local gate = require("_perf.gate")
local json = require("cosmic.json")

local tmpdir = os.getenv("TEST_TMPDIR") or "/tmp"

--- Fabricate a one-scenario results file, stamped or not.
local function write_results(path: string, wall_ns: number, bin_sha?: string)
  local row: {string: any} = {
    name = "scenario", wall_ns = wall_ns, spread_pct = 2,
    samples_ns = {}, iterations = 1,
  }
  local payload: {string: any} = {meta = {bin_sha = bin_sha}, results = {row}}
  local encoded = json.encode(payload)
  assert(fs.write(path, encoded))
end

local function paths(prefix: string): string, string, string
  return fs.join(tmpdir, prefix .. "-base.json"),
  fs.join(tmpdir, prefix .. "-cur.json"),
  fs.join(tmpdir, prefix .. "-selfb.json")
end

-- `current` is measured at 2000 against a 1000 baseline, and the retry
-- reproduces a +40% regression the A/A control does not explain.
-- Admitting the stampless `current` as a same-binary control donates a
-- -30% swing that buys full triage credit and passes the gate.
local function test_a_stampless_current_is_not_a_control()
  local base, cur, selfb = paths("stampless-control")
  write_results(base, 1000, "aaaa1111")
  write_results(cur, 2000)
  local calls = 0
  local code = gate.gate({
      baseline = base, current = cur, selfcheck_b = selfb, threshold = 10,
      measure = function(out: string): integer
        calls = calls + 1
        if calls == 1 then
          write_results(out, 1400, "bbbb2222") -- the regression persists
        else
          write_results(out, 1390, "bbbb2222") -- and the A/A pair is quiet
        end
        return 0
      end,
    })
  assert(code == 1,
    "a stampless current must not buy noise credit, got " .. code)
  assert(calls == 2, "expected re-measure + selfcheck-b, got " .. calls)
end

-- The A/A pair is one the gate itself measured and requires to match,
-- so an unidentified pair is refused rather than read: without that,
-- the +38% swing between these two stampless files would reclassify
-- the +30% regression as noise.
local function test_a_stampless_aa_pair_is_not_a_noise_floor()
  local base, cur, selfb = paths("stampless-aa")
  write_results(base, 1000, "aaaa1111")
  write_results(cur, 1300, "bbbb2222")
  local calls = 0
  local code = gate.gate({
      baseline = base, current = cur, selfcheck_b = selfb, threshold = 10,
      measure = function(out: string): integer
        calls = calls + 1
        write_results(out, calls == 1 and 1300 or 1800)
        return 0
      end,
    })
  assert(code == 1,
    "an unidentified A/A pair must not float a regression, got " .. code)
  assert(calls == 2, "expected re-measure + selfcheck-b, got " .. calls)
end

-- `selfcheck` measures twice and reports the floor it read; two files
-- that cannot be shown to name one binary have no floor to report.
local function test_stampless_selfcheck_refuses()
  local a, b, _ = paths("stampless-self")
  local code = gate.selfcheck({
      a = a, b = b, threshold = 10,
      measure = function(out: string): integer
        write_results(out, out == a and 1000 or 1010)
        return 0
      end,
    })
  assert(code == 1,
    "a selfcheck over an unidentified pair must refuse, got " .. code)
end

-- A control that will not load names nothing either, so the predicate
-- is false for it and it drops -- a control lost, not a refusal.
local function test_a_control_that_will_not_load_is_not_admitted()
  local base, cur, selfb = paths("unloadable-control")
  write_results(base, 1000, "aaaa1111")
  write_results(cur, 2000, "bbbb2222")
  local calls = 0
  local code = gate.gate({
      baseline = base, current = cur, selfcheck_b = selfb, threshold = 10,
      measure = function(out: string): integer
        calls = calls + 1
        if calls == 1 then
          write_results(out, 1400, "bbbb2222") -- the regression persists
        else
          write_results(out, 1390, "bbbb2222")
          assert(fs.remove(cur)) -- current is now unreadable as a control
        end
        return 0
      end,
    })
  assert(code == 1,
    "an unloadable control must not buy noise credit, got " .. code)
  assert(calls == 2, "expected re-measure + selfcheck-b, got " .. calls)
end
