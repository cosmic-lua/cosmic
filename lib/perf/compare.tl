--- Baseline-vs-current comparison gate for perf results.
--- Loads two results files produced by perf.run, compares median wall ns
--- per operation, and classifies each scenario. A delta only counts as a
--- regression (or improvement) when it clears the noise bar:
--- max(threshold, baseline spread, current spread).
---
--- Guardrails: scenarios that error, and scenarios present in the baseline
--- but missing from the current run (deleting a benchmark cannot hide a
--- regression), both count as failures.

local cio = require("cosmic.io")
local json = require("cosmic.json")
local harness = require("perf.harness")
local pt = require("perf.perf_types")

local DEFAULT_THRESHOLD_PCT = 10.0

--- Load a results JSON file written by perf.run.
--- @param path string Path to the results file
--- @return Results The decoded results, or nil on error
--- @return string Error message on failure
local function load_results(path: string): pt.Results, string
  local data, rerr = cio.slurp(path)
  if data == nil then
    return nil, path .. ": " .. tostring(rerr)
  end
  local decoded, jerr = json.decode(data)
  if decoded == nil then
    return nil, path .. ": " .. tostring(jerr)
  end
  local results = decoded as pt.Results
  if results.results == nil then
    return nil, path .. ": not a perf results file (missing 'results')"
  end
  return results
end

--- Compare current results against a baseline.
--- @param base Results The baseline results
--- @param cur Results The current results
--- @param threshold_pct number? Minimum noise bar in percent (default 10)
--- @return {Delta} One delta per scenario, current order first
--- @return integer Number of failures (regressions + errors + missing)
local function diff(base: pt.Results, cur: pt.Results, threshold_pct?: number): {pt.Delta}, integer
  local threshold = threshold_pct or DEFAULT_THRESHOLD_PCT
  local by_name: {string: pt.Measurement} = {}
  for _, b in ipairs(base.results) do
    by_name[b.name] = b
  end

  local deltas: {pt.Delta} = {}
  local failures = 0
  local seen: {string: boolean} = {}
  for _, c in ipairs(cur.results) do
    seen[c.name] = true
    local b = by_name[c.name]
    local d: pt.Delta = {name = c.name}
    if c.error then
      d.verdict = "error"
      failures = failures + 1
    elseif b == nil or b.error ~= nil or b.wall_ns == nil then
      d.cur_ns = c.wall_ns
      d.verdict = "new"
    else
      d.base_ns = b.wall_ns
      d.cur_ns = c.wall_ns
      d.noise_pct = math.max(threshold, b.spread_pct or 0, c.spread_pct or 0)
      if b.wall_ns > 0 then
        d.delta_pct = (c.wall_ns - b.wall_ns) / b.wall_ns * 100.0
      else
        d.delta_pct = 0.0
      end
      if d.delta_pct > d.noise_pct then
        d.verdict = "regression"
        failures = failures + 1
      elseif d.delta_pct < -d.noise_pct then
        d.verdict = "faster"
      else
        d.verdict = "ok"
      end
    end
    table.insert(deltas, d)
  end

  for _, b in ipairs(base.results) do
    if not seen[b.name] and b.error == nil then
      local d: pt.Delta = {name = b.name, base_ns = b.wall_ns, verdict = "missing"}
      failures = failures + 1
      table.insert(deltas, d)
    end
  end

  return deltas, failures
end

--- Reclassify baseline-vs-current regressions using an A/A self-check.
--- A regression whose scenario ALSO moves past its noise bar when the
--- current binary is compared against itself (two same-binary runs) is
--- indistinguishable from run-to-run variance, so it is reclassified to
--- the non-failing verdict "noise". A scenario that stays within the bar
--- under the self-check keeps its "regression" verdict — so a real
--- regression in a stable, low-variance scenario (json, sqlite, ...)
--- still fails the gate. This makes the noise/real call deterministic
--- instead of a manual judgement (see lib/perf/optimize/measurement.md).
--- @param base Results Baseline results
--- @param cur Results Current results
--- @param noise_a Results First self-check pass (current binary)
--- @param noise_b Results Second self-check pass (current binary)
--- @param threshold_pct number? Noise bar in percent (default 10)
--- @return {Delta} Deltas, with confirmed-noise regressions reclassified
--- @return integer Number of real failures (regressions + errors + missing)
local function triage(base: pt.Results, cur: pt.Results, noise_a: pt.Results, noise_b: pt.Results, threshold_pct?: number): {pt.Delta}, integer
  local deltas, failures = diff(base, cur, threshold_pct)
  local self_deltas = diff(noise_a, noise_b, threshold_pct)
  local unstable: {string: boolean} = {}
  for _, sd in ipairs(self_deltas) do
    -- The same binary vs itself should read "ok"; a scenario that instead
    -- clears the bar in either direction is too noisy to judge here.
    if sd.verdict == "regression" or sd.verdict == "faster" then
      unstable[sd.name] = true
    end
  end
  for _, d in ipairs(deltas) do
    if d.verdict == "regression" and unstable[d.name] then
      d.verdict = "noise"
      failures = failures - 1
    end
  end
  return deltas, failures
end

--- Format one delta as a report line.
--- @param d Delta The delta
--- @return string A single aligned line
local function format_delta(d: pt.Delta): string
  local base_str = d.base_ns and harness.format_ns(d.base_ns) or "-"
  local cur_str = d.cur_ns and harness.format_ns(d.cur_ns) or "-"
  local delta_str = "-"
  if d.delta_pct then
    delta_str = string.format("%+.1f%%", d.delta_pct)
  end
  local noise_str = "-"
  if d.noise_pct then
    noise_str = string.format("±%.1f%%", d.noise_pct)
  end
  return string.format("%-28s %12s -> %12s  %8s  (noise %7s)  %s",
    d.name, base_str, cur_str, delta_str, noise_str, d.verdict)
end

--- Format a full comparison report with a summary line.
--- @param deltas {Delta} Deltas from diff()
--- @return string The report text
local function format(deltas: {pt.Delta}): string
  local lines: {string} = {}
  local counts: {string: integer} = {}
  for _, d in ipairs(deltas) do
    table.insert(lines, format_delta(d))
    counts[d.verdict] = (counts[d.verdict] or 0) + 1
  end
  table.insert(lines, string.format(
      "%d scenarios: %d regression, %d faster, %d ok, %d noise, %d new, %d missing, %d error",
      #deltas,
      counts["regression"] or 0,
      counts["faster"] or 0,
      counts["ok"] or 0,
      counts["noise"] or 0,
      counts["new"] or 0,
      counts["missing"] or 0,
      counts["error"] or 0))
  return table.concat(lines, "\n")
end

local record compare
  DEFAULT_THRESHOLD_PCT: number
  load_results: function(path: string): pt.Results, string
  diff: function(base: pt.Results, cur: pt.Results, threshold_pct?: number): {pt.Delta}, integer
  triage: function(base: pt.Results, cur: pt.Results, noise_a: pt.Results, noise_b: pt.Results, threshold_pct?: number): {pt.Delta}, integer
  format_delta: function(d: pt.Delta): string
  format: function(deltas: {pt.Delta}): string
end

local M: compare = {
  DEFAULT_THRESHOLD_PCT = DEFAULT_THRESHOLD_PCT,
  load_results = load_results,
  diff = diff,
  triage = triage,
  format_delta = format_delta,
  format = format,
}

return M
