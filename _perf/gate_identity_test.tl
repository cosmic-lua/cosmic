#!/usr/bin/env cosmic
--- Tests for the perf gate's binary-identity rules: which measured runs
--- may serve as same-binary noise controls, and what happens when a
--- results file records no `bin_sha` at all. A file that names no binary
--- cannot prove two runs measured the same one, so it may neither join
--- the control set nor stand in for an A/A noise floor.

local check = require("cosmic.check")
local fs = require("cosmic.fs")
local gate = require("_perf.gate")
local json = require("cosmic.json")

local tmpdir = os.getenv("TEST_TMPDIR") or "/tmp"

--- Fabricate a one-scenario results file, stamped only when asked.
local function write_results(path: string, wall_ns: number, bin_sha?: string)
  local payload: {string: any} = {
    meta = {bin_sha = bin_sha},
    results = {{
        name = "scenario", wall_ns = wall_ns, spread_pct = 2,
        samples_ns = {}, iterations = 1,
      }},
  }
  local encoded = check.must(json.encode(payload))
  assert(fs.write(path, encoded))
end

local function paths(prefix: string): string, string, string
  return fs.join(tmpdir, prefix .. "-base.json"),
  fs.join(tmpdir, prefix .. "-cur.json"),
  fs.join(tmpdir, prefix .. "-selfb.json")
end

-- A stampless `current` names no binary, so pairing it against the retry
-- measures nothing: the -30% "swing" it donates is the regression itself
-- read backwards, and it buys the +40% enough credit to be waved through.
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
          write_results(out, 1390, "bbbb2222") -- the A/A control is quiet
        end
        return 0
      end,
    })
  assert(code == 1,
    "a stampless current must not buy noise credit, got " .. code)
  assert(calls == 2, "expected re-measure + selfcheck-b, got " .. calls)
end

-- The A/A pair the gate measures itself must be identifiable: two
-- stampless files could be two different binaries, and a noise floor is
-- only a noise floor if the subject is constant.
local function test_a_stampless_aa_pair_is_not_a_noise_floor()
  local base, cur, selfb = paths("stampless-aa")
  write_results(base, 1000, "aaaa1111")
  write_results(cur, 1300, "bbbb2222")
  local code = gate.gate({
      baseline = base, current = cur, selfcheck_b = selfb, threshold = 10,
      measure = function(out: string): integer
        write_results(out, out == selfb and 1800 or 1300)
        return 0
      end,
    })
  assert(code == 1,
    "an unidentified A/A pair must not float the bar, got " .. code)
end

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
    "an unidentified selfcheck pair must refuse, got " .. code)
end

-- A control that will not load names no binary either, so it is dropped
-- from the control set rather than trusted by its path alone.
local function test_a_control_that_will_not_load_is_not_admitted()
  local base, cur, selfb = paths("unloadable-control")
  write_results(base, 1000, "aaaa1111")
  write_results(cur, 2000, "bbbb2222")
  local calls = 0
  local code = gate.gate({
      baseline = base, current = cur, selfcheck_b = selfb, threshold = 10,
      measure = function(out: string): integer
        calls = calls + 1
        write_results(out, calls == 1 and 1400 or 1390, "bbbb2222")
        if calls == 2 then
          assert(fs.remove(cur))
        end
        return 0
      end,
    })
  assert(code == 1,
    "an unloadable control must not buy noise credit, got " .. code)
  assert(calls == 2, "expected re-measure + selfcheck-b, got " .. calls)
end
