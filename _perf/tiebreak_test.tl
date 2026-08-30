#!/usr/bin/env cosmic
--- Tests for the perf gate's baseline tiebreak: whether two readings of
--- the baseline binary disagree, the per-scenario median that decides
--- when they do, and the resolution that buys a third reading only then.
--- The measure function is injected, so every path runs on fabricated
--- results files and no real benchmarks.

local check = require("cosmic.check")
local compare = require("_perf.compare")
local fs = require("cosmic.fs")
local json = require("cosmic.json")
local pt = require("_perf.perf_types")
local tiebreak = require("_perf.tiebreak")

local tmpdir = os.getenv("TEST_TMPDIR") or "/tmp"

--- One in-memory reading, one scenario per (name -> wall_ns) entry.
local function reading(rows: {string: number}, bin_sha?: string): pt.Results
  local results: {pt.Measurement} = {}
  for name, wall_ns in pairs(rows) do
    results[#results + 1] = {
      name = name, wall_ns = wall_ns, spread_pct = 2,
      samples_ns = {}, iterations = 1,
    }
  end
  return {meta = {bin_sha = bin_sha or "aaaa1111"}, results = results}
end

--- Write a reading to disk, the way a measurement pass would.
local function write_reading(path: string, rows: {string: number}, bin_sha?: string)
  local encoded = check.must(json.encode(reading(rows, bin_sha)))
  check.must(fs.write(path, encoded))
end

--- The wall_ns of one scenario in a results table, nil when absent.
local function wall_of(r: pt.Results, name: string): number | nil
  for _, m in ipairs(r.results) do
    if m.name == name then return m.wall_ns end
  end
  return nil
end

local function test_a_quiet_pair_does_not_disagree()
  local a = reading({s = 1000})
  local b = reading({s = 1050})
  assert(not tiebreak.disagrees(a, b, 10),
    "a 5% move is under the 10% bar and is not a disagreement")
end

local function test_a_faster_second_reading_disagrees()
  local a = reading({s = 1000})
  local b = reading({s = 700})
  assert(tiebreak.disagrees(a, b, 10),
    "a -30% move past the bar is a disagreement in the faster direction")
end

local function test_a_slower_second_reading_disagrees()
  local a = reading({s = 1000})
  local b = reading({s = 1300})
  assert(tiebreak.disagrees(a, b, 10),
    "a +30% move past the bar is a disagreement")
end

local function test_the_median_follows_the_majority()
  -- The lone HIGH reading loses, and so does the lone LOW one.
  local high = tiebreak.median_of({reading({s = 1300}), reading({s = 1000}),
      reading({s = 1000})})
  assert(wall_of(high, "s") == 1000,
    "the majority 1000 outvotes a lone 1300, got " .. tostring(wall_of(high, "s")))
  local low = tiebreak.median_of({reading({s = 700}), reading({s = 1000}),
      reading({s = 1000})})
  assert(wall_of(low, "s") == 1000,
    "the majority 1000 outvotes a lone 700, got " .. tostring(wall_of(low, "s")))
end

local function test_a_row_missing_from_one_reading_is_carried_through()
  local first = reading({s = 1300, only_here = 500})
  local median = tiebreak.median_of({first, reading({s = 1000}),
      reading({s = 1000})})
  assert(wall_of(median, "s") == 1000, "the comparable row is medianed")
  assert(wall_of(median, "only_here") == 500,
    "a row absent from a reading keeps the first reading's number, got " ..
    tostring(wall_of(median, "only_here")))
end

local function test_an_agreeing_pair_costs_one_measurement()
  local base = fs.join(tmpdir, "tb-agree-base.json")
  write_reading(base, {s = 1000})
  local calls = 0
  local side, err = tiebreak.baseline_side(base, 10, function(out: string): integer
      calls = calls + 1
      write_reading(out, {s = 1050})
      return 0
    end)
  assert(side ~= nil, "an agreeing pair resolves, got " .. tostring(err))
  assert(calls == 1, "an agreeing pair buys no third reading, got " .. calls)
  assert(side:match("%-retry%.json$"),
    "the retry IS the baseline side when the pair agrees, got " .. side)
end

local function test_a_disagreeing_pair_buys_a_third_and_medians_it()
  local base = fs.join(tmpdir, "tb-split-base.json")
  write_reading(base, {s = 1000})
  local calls = 0
  local side, err = tiebreak.baseline_side(base, 10, function(out: string): integer
      calls = calls + 1
      write_reading(out, {s = calls == 1 and 700 or 1000})
      return 0
    end)
  assert(side ~= nil, "a disagreeing pair resolves, got " .. tostring(err))
  assert(calls == 2, "a disagreeing pair buys exactly one more, got " .. calls)
  assert(side:match("%-median%.json$"),
    "a disagreeing pair judges against the median, got " .. side)
  local written = check.must(compare.load_results(side))
  assert(wall_of(written, "s") == 1000,
    "the median file carries the majority number, got " ..
    tostring(wall_of(written, "s")))
end

local function test_a_third_reading_of_another_binary_is_refused()
  local base = fs.join(tmpdir, "tb-identity-base.json")
  write_reading(base, {s = 1000}, "aaaa1111")
  local calls = 0
  local side, err = tiebreak.baseline_side(base, 10, function(out: string): integer
      calls = calls + 1
      write_reading(out, {s = 700}, calls == 1 and "aaaa1111" or "dddd4444")
      return 0
    end)
  assert(side == nil, "a third reading of another binary must refuse")
  assert(err:find("DIFFERENT binaries", 1, true) ~= nil,
    "the refusal names the identity mismatch, got " .. tostring(err))
end

local function test_a_failed_measurement_is_reported()
  local base = fs.join(tmpdir, "tb-failed-base.json")
  write_reading(base, {s = 1000})
  local side, err = tiebreak.baseline_side(base, 10, function(_out: string): integer
      return 3
    end)
  assert(side == nil, "a failed re-measurement resolves to nothing")
  assert(err:find("re-measurement", 1, true) ~= nil,
    "the failure is reported rather than swallowed, got " .. tostring(err))
end
