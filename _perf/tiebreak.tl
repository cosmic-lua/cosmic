--- The perf gate's baseline side: which reading of the baseline binary
--- passes 2 and 3 are judged against.
---
--- The gate re-measures the baseline binary once, because a single
--- unlucky reading in the caller's baseline file otherwise anchors every
--- later pass. Two readings have no majority, though. When they disagree
--- past the bar, which of them was the outlier is not in the data: the
--- same two numbers are produced by a one-off FAST retry (nothing
--- regressed, the gate must pass) and by a real regression that a
--- one-off SLOW pass-1 reading masked (the gate must fail). No function
--- of the two separates those, so a disagreeing pair earns a THIRD
--- reading and the per-scenario median of the three becomes the baseline
--- side -- the majority says which reading was the outlier. A pair that
--- agrees costs nothing extra: the retry is the baseline side, exactly
--- as it was before, and no third pass is measured.
---
--- The median is a tiebreak over comparable numbers, not a way to invent
--- one. A scenario that is not present with a `wall_ns` and no `error` in
--- EVERY reading keeps the first reading's row verbatim.

local compare = require("_perf.compare")
local fs = require("cosmic.fs")
local json = require("cosmic.json")
local pt = require("_perf.perf_types")

--- A results path's `-<suffix>.json` sibling, beside the caller's own
--- file and never over it. A trailing `.json` is replaced, so
--- `o/perf/base.json` becomes `o/perf/base-retry.json`; any other
--- spelling just gains the suffix.
--- @param path string The results path to derive from
--- @param suffix string The sibling's suffix, without its leading dash
--- @return string The sibling's own path
local function sibling(path: string, suffix: string): string
  local stem = path:match("^(.*)%.json$")
  return (stem or path) .. "-" .. suffix .. ".json"
end

--- Whether two readings of the SAME binary disagree past the noise bar.
--- A binary measured against itself should read `ok` everywhere, so a
--- `regression` or `faster` row -- the two verdicts that mean a scenario
--- moved -- is a disagreement, in either direction. The verdicts that
--- report a broken or absent row are not disagreements: they are the
--- gate's own business, and a tiebreak cannot help them.
--- @param a pt.Results The first reading
--- @param b pt.Results The second reading
--- @param threshold number Noise bar in percent
--- @return boolean True when any scenario moved past the bar
local function disagrees(a: pt.Results, b: pt.Results, threshold: number): boolean
  local deltas = compare.diff(a, b, threshold)
  for _, d in ipairs(deltas) do
    if d.verdict == "regression" or d.verdict == "faster" then
      return true
    end
  end
  return false
end

--- The per-scenario median of several readings of one binary.
---
--- `meta` and the scenario order come from the FIRST reading, which is
--- the caller's own baseline file. A scenario is medianed only when
--- every reading carries it with a `wall_ns` and no `error`; otherwise
--- its row is carried from the first reading unchanged, because a
--- median over rows that are not comparable would invent a number
--- rather than choose between measured ones. With an even number of
--- readings the lower middle wins; the gate always passes three.
--- @param runs {pt.Results} The readings, the first one canonical
--- @return pt.Results One results table carrying each row's median
local function median_of(runs: {pt.Results}): pt.Results
  local first = runs[1]
  local out: {pt.Measurement} = {}
  for _, m in ipairs(first.results) do
    local walls: {number} = {}
    if m.wall_ns ~= nil and m.error == nil then
      walls[1] = m.wall_ns
      for i = 2, #runs do
        for _, o in ipairs(runs[i].results) do
          if o.name == m.name and o.wall_ns ~= nil and o.error == nil then
            walls[#walls + 1] = o.wall_ns
          end
        end
      end
    end
    if #walls == #runs then
      table.sort(walls)
      out[#out + 1] = {
        name = m.name, iterations = m.iterations, samples_ns = m.samples_ns,
        wall_ns = walls[(#walls + 1) // 2], cpu_ns = m.cpu_ns,
        min_ns = m.min_ns, max_ns = m.max_ns, spread_pct = m.spread_pct,
        alloc_kb = m.alloc_kb, error = m.error,
      }
    else
      out[#out + 1] = m
    end
  end
  return {meta = first.meta, results = out}
end

--- Load a reading and check it named the SAME binary as the baseline.
--- @param base_path string The caller's baseline results path
--- @param base pt.Results The baseline reading, already loaded
--- @param path string The re-measured reading's path
--- @return pt.Results|nil The reading, or nil when it cannot be trusted
--- @return string The reason, when it cannot
local function trusted(base_path: string, base: pt.Results, path: string): pt.Results | nil, string
  local r, rerr = compare.load_results(path)
  if r == nil then
    return nil, rerr
  end
  -- A baseline re-measurement is only a re-measurement if it measured
  -- the SAME binary the baseline file names.
  local refusal = compare.identity_refusal(base_path, base, path, r, true)
  if refusal then
    return nil, refusal
  end
  return r
end

--- Resolve the baseline side the gate's later passes are judged against.
---
--- Measures the baseline binary into `baseline`'s own `-retry.json`
--- sibling. When that reading agrees with the caller's everywhere under
--- the bar, it IS the baseline side and nothing further is measured.
--- When they disagree, a third reading goes into `-retry2.json`, held to
--- the same identity rule, and the per-scenario median of the three is
--- written to `-median.json` and returned.
--- @param baseline string The caller's baseline results path
--- @param threshold number Noise bar in percent
--- @param measure function Re-measures the baseline binary into a path
--- @return string|nil The path passes 2 and 3 read, nil on failure
--- @return string The reason, when it failed
local function baseline_side(baseline: string, threshold: number,
    measure: function(out: string): integer): string | nil, string
  local retry = sibling(baseline, "retry")
  print("perf-compare: re-measuring the baseline into " .. retry ..
    " so a one-off baseline reading cannot anchor the verdict")
  if measure(retry) ~= 0 then
    return nil, "perf-compare: the baseline re-measurement into " .. retry ..
    " failed"
  end
  local base, berr = compare.load_results(baseline)
  if base == nil then
    return nil, berr
  end
  local first, ferr = trusted(baseline, base, retry)
  if first == nil then
    return nil, ferr
  end
  if not disagrees(base, first, threshold) then
    return retry
  end
  local retry2 = sibling(baseline, "retry2")
  local median = sibling(baseline, "median")
  print("perf-compare: the two baseline readings disagree past the bar, and" ..
    " which one was the outlier is not in the pair; measuring a third into " ..
    retry2 .. " and judging against the per-scenario median in " .. median)
  if measure(retry2) ~= 0 then
    return nil, "perf-compare: the baseline re-measurement into " .. retry2 ..
    " failed"
  end
  local second, serr = trusted(baseline, base, retry2)
  if second == nil then
    return nil, serr
  end
  local encoded, eerr = json.encode(median_of({base, first, second}))
  if encoded == nil then
    return nil, "perf-compare: encode " .. median .. ": " .. tostring(eerr)
  end
  local wrote, werr = fs.write(median, encoded)
  if not wrote then
    return nil, "perf-compare: write " .. median .. ": " .. tostring(werr)
  end
  return median
end

local record tiebreak
  disagrees: function(a: pt.Results, b: pt.Results, threshold: number): boolean
  median_of: function(runs: {pt.Results}): pt.Results
  baseline_side: function(baseline: string, threshold: number, measure: function(out: string): integer): string | nil, string
end

local M: tiebreak = {
  disagrees = disagrees,
  median_of = median_of,
  baseline_side = baseline_side,
}

return M
