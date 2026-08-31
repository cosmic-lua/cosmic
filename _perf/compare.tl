--- Baseline-vs-current comparison gate for perf results.
--- Loads two results files produced by perf.run, compares median wall ns
--- per operation, and classifies each scenario. A delta only counts as a
--- regression (or improvement) when it clears the noise bar:
--- max(threshold, baseline spread, current spread).
---
--- Guardrails: scenarios that error, scenarios present in the baseline
--- but missing from the current run (deleting a benchmark cannot hide a
--- regression), scenarios whose baseline row itself errored ("new" would
--- hide a permanently-broken scenario), and malformed rows (no error but
--- no timing either) all count as failures.

local json = require("cosmic.json")
local harness = require("_perf.harness")
local pt = require("_perf.perf_types")
local fs = require("cosmic.fs")
local shape = require("cosmic.shape")
local time = require("cosmic.time")

local DEFAULT_THRESHOLD_PCT = 10.0

--- Multiplier applied to the A/A self-check delta in triage(): a
--- regression reclassifies to "noise" only when its own magnitude is
--- within TRIAGE_K times the self-check's swing (see triage() below).
--- K=2 lets the reclassification absorb ordinary variance (a self-check
--- that swings 15% clears a 30% regression) without waving through a
--- regression many times larger than anything the self-check showed.
local TRIAGE_K = 2.0

--- What a results file must carry for this module to read it: the
--- `results` list, and a `name` on every row. Everything else this
--- module consults it already guards for absence — `meta` and its
--- `bin_sha` in identity_refusal, `wall_ns` as the "malformed"
--- verdict, `spread_pct` behind `or 0`, `error` as the failed-row
--- marker — so demanding any of them here would reject a file the
--- code handles. `meta.timestamp` is the one exception that is named:
--- format_measured below floors it and formats it, so a file carrying
--- a non-number there would throw out of this module rather than be
--- refused on the error channel load_results already has. The fields
--- perf.run also writes but nothing here reads (iterations,
--- samples_ns, cpu_ns, min_ns, max_ns, alloc_kb) are left unnamed:
--- `into` ignores keys a Spec does not name.
local RESULTS_SPEC < const > = shape.record({
    meta = shape.optional(shape.record({
          bin_sha = shape.optional(shape.string),
          timestamp = shape.optional(shape.number),
        })),
    results = shape.list(shape.record({
          name = shape.string,
          wall_ns = shape.optional(shape.number),
          spread_pct = shape.optional(shape.number),
          error = shape.optional(shape.string),
        })),
  })

--- Load a results JSON file written by perf.run.
--- @param path string Path to the results file
--- @return Results|nil The decoded results
--- @return string Error message when the file is missing, malformed,
--- or not the shape a results file has
local function load_results(path: string): pt.Results | nil, string
  local data, rerr = fs.read(path)
  if data == nil then
    return nil, path .. ": " .. tostring(rerr)
  end
  local decoded, jerr = json.decode(data)
  if decoded == nil then
    return nil, path .. ": " .. tostring(jerr)
  end
  local results, serr: pt.Results | nil, string = shape.into(decoded, RESULTS_SPEC)
  if not results then
    return nil, path .. ": not a perf results file (" .. serr .. ")"
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
    elseif c.wall_ns == nil then
      -- No error, but also no timing: malformed input. Computing a
      -- delta against this would arithmetic on nil below; say so
      -- instead of throwing.
      d.verdict = "malformed"
      failures = failures + 1
    elseif b == nil then
      d.cur_ns = c.wall_ns
      d.verdict = "new"
    elseif b.error ~= nil then
      -- The baseline scenario errored last time. Unlike a genuinely new
      -- scenario, this one WAS measured and failed -- treating it as
      -- "new" (never gated) lets a broken scenario stay broken
      -- indefinitely, silently, until someone happens to refresh the
      -- baseline. Count it like "missing": a failing state that a
      -- fresh, passing baseline clears.
      d.cur_ns = c.wall_ns
      d.verdict = "baseline-error"
      failures = failures + 1
    elseif b.wall_ns == nil then
      d.cur_ns = c.wall_ns
      d.verdict = "malformed"
      failures = failures + 1
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

--- The loudest delta each scenario showed across the same-binary control
--- pairs, keyed by scenario name — the noise credit `triage_many` reads.
--- A scenario can be quiet in one pair and loud in the next, so the
--- credit comes from the largest swing and not from one designated pair.
--- Sampling every available pair is free: the controls are already
--- measured, and one pair is one `diff` call.
--- Only a pair where the scenario cleared the bar counts — the same
--- binary against itself should read "ok", so anything else is the
--- scenario being too unstable to judge on that pair.
--- @param controls {Results} Same-binary control runs, two or more to have a pair
--- @param threshold_pct number? Noise bar in percent (default 10)
--- @return {string: Delta} Per scenario, the loudest control delta seen
local function loudest_control(controls: {pt.Results}, threshold_pct?: number): {string: pt.Delta}
  local loudest: {string: pt.Delta} = {}
  for i = 1, #controls do
    for j = i + 1, #controls do
      -- `diff` returns a second value, so its call is parenthesized to
      -- hand `ipairs` the delta list alone.
      for _, sd in ipairs((diff(controls[i], controls[j], threshold_pct))) do
        if (sd.verdict == "regression" or sd.verdict == "faster")
        and sd.delta_pct ~= nil then
          local best = loudest[sd.name]
          if best == nil or best.delta_pct == nil
          or math.abs(sd.delta_pct) > math.abs(best.delta_pct) then
            loudest[sd.name] = sd
          end
        end
      end
    end
  end
  return loudest
end

--- Reclassify baseline-vs-current regressions using same-binary controls.
--- A regression whose scenario ALSO moves past its noise bar when the
--- current binary is compared against itself is a CANDIDATE for
--- run-to-run variance, but instability alone does not excuse any
--- magnitude: a scenario whose controls swing 5% does not get to wave
--- through a +300% regression. The candidate reclassifies to the
--- non-failing verdict "noise" only when its own delta is comparable to
--- what the controls showed -- |regression delta| <= max(bar, TRIAGE_K *
--- |control delta|), TRIAGE_K = 2 -- so the controls bound how much
--- variance a scenario gets credit for instead of writing it a blank
--- check. A scenario that stays within the bar under every control pair,
--- or whose regression dwarfs what the controls showed, keeps its
--- "regression" verdict — so a real regression in a stable, low-variance
--- scenario (json, sqlite, ...) still fails the gate, and so does a huge
--- regression in an unstable one. This makes the noise/real call
--- deterministic instead of a manual judgement (see
--- skills/optimize/measurement.md).
---
--- Fewer than two controls means no pairs and no reclassification, which
--- is what a run with no self-check gets.
--- @param base Results Baseline results
--- @param cur Results Current results
--- @param controls {Results} Same-binary control runs
--- @param threshold_pct number? Noise bar in percent (default 10)
--- @return {Delta} Deltas, with confirmed-noise regressions reclassified
--- @return integer Number of real failures (regressions + errors + missing)
local function triage_many(base: pt.Results, cur: pt.Results, controls: {pt.Results}, threshold_pct?: number): {pt.Delta}, integer
  local deltas, failures = diff(base, cur, threshold_pct)
  local self_by_name = loudest_control(controls, threshold_pct)
  for _, d in ipairs(deltas) do
    local sd = self_by_name[d.name]
    if d.verdict == "regression" and sd ~= nil and sd.delta_pct ~= nil
    and math.abs(d.delta_pct) <= math.max(d.noise_pct, TRIAGE_K * math.abs(sd.delta_pct)) then
      d.verdict = "noise"
      failures = failures - 1
    end
  end
  return deltas, failures
end

--- `triage_many` over exactly one control pair.
--- @param base Results Baseline results
--- @param cur Results Current results
--- @param noise_a Results First self-check pass (current binary)
--- @param noise_b Results Second self-check pass (current binary)
--- @param threshold_pct number? Noise bar in percent (default 10)
--- @return {Delta} Deltas, with confirmed-noise regressions reclassified
--- @return integer Number of real failures (regressions + errors + missing)
local function triage(base: pt.Results, cur: pt.Results, noise_a: pt.Results, noise_b: pt.Results, threshold_pct?: number): {pt.Delta}, integer
  return triage_many(base, cur, {noise_a, noise_b}, threshold_pct)
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

--- Name the binary each side of a comparison measured, as one line
--- above the rows.
---
--- The identity is a property of a results FILE, not of a row: every
--- row in one report comes from the same pair of files, so it is said
--- once instead of in a column per side, which the row format has no
--- width left for.
---
--- The 12-hex prefix is the one `identity_refusal` names a binary by,
--- so a printed header and a refusal agree on sight. `unknown` is a
--- side whose `meta.bin_sha` is absent, and `(unverifiable)` the
--- verdict whenever either side is unknown -- never `(same)`, which
--- would assert what the files do not say.
--- @param base Results The baseline file
--- @param cur Results The current file
--- @return string A single line naming both sides
local function format_identity(base: pt.Results, cur: pt.Results): string
  local sb = base.meta and base.meta.bin_sha
  local sc = cur.meta and cur.meta.bin_sha
  local agreement = "(unverifiable)"
  if sb and sc then
    agreement = sb == sc and "(same)" or "(differ)"
  end
  return string.format("binaries: base %s  current %s  %s",
    sb and string.sub(sb, 1, 12) or "unknown",
    sc and string.sub(sc, 1, 12) or "unknown",
    agreement)
end

--- Render a signed interval in the largest unit that still answers
--- "same measurement window or not", dropping finer precision above a
--- minute: seconds below a minute, floored minutes below an hour,
--- floored hours and minutes above it.
--- @param secs integer The interval in seconds, negative when the
--- current side is the earlier one
--- @return string The signed interval, e.g. `+12s`, `+2m`, `-8h33m`
local function format_gap(secs: integer): string
  local sign = secs < 0 and "-" or "+"
  local a = secs < 0 and -secs or secs
  if a < 60 then return string.format("%s%ds", sign, a) end
  if a < 3600 then return string.format("%s%dm", sign, a // 60) end
  return string.format("%s%dh%02dm", sign, a // 3600, (a % 3600) // 60)
end

--- Date the measurement window each side of a comparison came from, as
--- one line beneath the binaries line.
---
--- Like the binary, the stamp is a property of a results FILE, so it is
--- said once rather than in a column per side. Each side renders
--- through `time.format_iso8601`, which is UTC with a `Z` suffix, and
--- reads `meta.timestamp`, which perf.run writes when it WRITES the
--- file -- so the line dates the reading, not the start of the run.
---
--- A side is `unknown` -- the word `format_identity` uses for a binary
--- it cannot name -- when its `meta` is absent, its `meta.timestamp` is
--- absent, or the stamp will not format. The parenthetical is signed
--- against the base, matching the `base -> current` direction the rows
--- already read in, and is `(gap unknown)` whenever either side is
--- unknown. It is informational: no gap refuses, warns, or moves a bar.
--- @param base Results The baseline file
--- @param cur Results The current file
--- @return string A single line dating both sides
local function format_measured(base: pt.Results, cur: pt.Results): string
  local bt = base.meta and base.meta.timestamp
  local ct = cur.meta and cur.meta.timestamp
  local bs: string | nil
  local cs: string | nil
  local bi: integer
  local ci: integer
  if bt ~= nil then
    bi = math.floor(bt)
    bs = time.format_iso8601(bi)
  end
  if ct ~= nil then
    ci = math.floor(ct)
    cs = time.format_iso8601(ci)
  end
  local gap = "(gap unknown)"
  if bs ~= nil and cs ~= nil then
    gap = "(current " .. format_gap(ci - bi) .. ")"
  end
  return string.format("measured: base %s  current %s  %s",
    bs or "unknown", cs or "unknown", gap)
end

--- Format a full comparison report with a summary line.
---
--- Given both results files, the report is headed by
--- `format_identity`'s line, so a reader can tell which binary each
--- side came from, and beneath it `format_measured`'s line, so a
--- reader can tell which measurement window each side came from. With
--- either absent it is the rows and the summary alone: a caller
--- holding deltas but no files still gets a report, rather than a
--- header it cannot fill in.
--- @param deltas {Delta} Deltas from diff()
--- @param base Results? The baseline file the deltas came from
--- @param cur Results? The current file the deltas came from
--- @return string The report text
local function format(deltas: {pt.Delta}, base?: pt.Results | nil, cur?: pt.Results | nil): string
  local lines: {string} = {}
  local counts: {string: integer} = {}
  if base and cur then
    table.insert(lines, format_identity(base, cur))
    table.insert(lines, format_measured(base, cur))
  end
  for _, d in ipairs(deltas) do
    table.insert(lines, format_delta(d))
    counts[d.verdict] = (counts[d.verdict] or 0) + 1
  end
  table.insert(lines, string.format(
      "%d scenarios: %d regression, %d faster, %d ok, %d noise, %d new, %d missing," ..
      " %d error, %d baseline-error, %d malformed",
      #deltas,
      counts["regression"] or 0,
      counts["faster"] or 0,
      counts["ok"] or 0,
      counts["noise"] or 0,
      counts["new"] or 0,
      counts["missing"] or 0,
      counts["error"] or 0,
      counts["baseline-error"] or 0,
      counts["malformed"] or 0))
  return table.concat(lines, "\n")
end

--- Whether two results files positively name the SAME binary. Absence is
--- never proof, so a stampless file answers false: reading
--- `identity_refusal(...) == nil` as "same" admitted stampless controls.
--- @param a_res Results The first file
--- @param b_res Results The second file
--- @return boolean True when both files record the same `bin_sha`
local function same_binary(a_res: pt.Results, b_res: pt.Results): boolean
  local sa = a_res.meta and a_res.meta.bin_sha
  local sb = b_res.meta and b_res.meta.bin_sha
  return sa ~= nil and sb ~= nil and sa == sb
end

--- Refuse a pair of results files that cannot answer the question asked
--- of them.
---
--- `meta.bin` is a NAME: two runs forty commits apart both say
--- `o/bin/cosmic`. `meta.bin_sha` is the identity, and these are the
--- two ways a comparison can be about something other than what the
--- operator thinks. Both produce a confident, wrong answer rather than
--- an error, which is why they refuse rather than warn -- a warning
--- above a plausible-looking table gets read past:
---
--- - **compared against the same binary**, "no regression" is a
---   statement about a binary and itself. It is the failure that looks
---   most like success, and a plausible slip: build, forget to
---   rebuild, re-run, compare.
--- - **a noise floor measured across two binaries** reports the change
---   as noise, and raises the bar every real regression afterwards has
---   to clear. A noise floor is only a noise floor if the subject is
---   constant.
---
--- A file with no `bin_sha` names no binary, which is said out loud
--- rather than passed over. Absence is asymmetric evidence: it can
--- never PROVE sameness, so a `same` pair is refused, and it is no
--- evidence of difference either, so a `not same` pair still compares.
--- @param a_path string First results path, for the message
--- @param a_res Results The first file
--- @param b_path string Second results path, for the message
--- @param b_res Results The second file
--- @param same boolean Whether the two must name the SAME binary
--- @return string|nil The refusal, or nil when the pair is sound
local function identity_refusal(a_path: string, a_res: pt.Results,
    b_path: string, b_res: pt.Results, same: boolean): string | nil
  local sa = a_res.meta and a_res.meta.bin_sha
  local sb = b_res.meta and b_res.meta.bin_sha
  if not sa or not sb then
    io.stderr:write("perf: " .. (not sa and a_path or b_path) ..
      " does not record which binary it measured, so these two runs" ..
      " cannot be told apart\n")
    if not same then return nil end
    return "perf: " .. a_path .. " and " .. b_path .. " do not both" ..
    " record a binary; an unidentified pair is not a noise floor."
  end
  if same and sa ~= sb then
    return "perf: " .. a_path .. " and " .. b_path ..
    " measured DIFFERENT binaries (" .. string.sub(sa, 1, 12) .. " vs " ..
    string.sub(sb, 1, 12) .. "). A noise floor is only a noise floor if" ..
    " the subject is constant; across two binaries it reports the" ..
    " change as noise and raises the bar every real regression has to" ..
    " clear."
  end
  if not same and sa == sb then
    return "perf: " .. a_path .. " and " .. b_path ..
    " measured the SAME binary (" .. string.sub(sa, 1, 12) ..
    "). A binary compared against itself has no regression to find," ..
    " so a clean result says nothing about your change."
  end
  return nil
end

local record compare
  DEFAULT_THRESHOLD_PCT: number
  TRIAGE_K: number
  load_results: function(path: string): pt.Results | nil, string
  same_binary: function(a_res: pt.Results, b_res: pt.Results): boolean
  identity_refusal: function(a_path: string, a_res: pt.Results, b_path: string, b_res: pt.Results, same: boolean): string | nil
  diff: function(base: pt.Results, cur: pt.Results, threshold_pct?: number): {pt.Delta}, integer
  triage: function(base: pt.Results, cur: pt.Results, noise_a: pt.Results, noise_b: pt.Results, threshold_pct?: number): {pt.Delta}, integer
  triage_many: function(base: pt.Results, cur: pt.Results, controls: {pt.Results}, threshold_pct?: number): {pt.Delta}, integer
  loudest_control: function(controls: {pt.Results}, threshold_pct?: number): {string: pt.Delta}
  format_delta: function(d: pt.Delta): string
  format_identity: function(base: pt.Results, cur: pt.Results): string
  format: function(deltas: {pt.Delta}, base?: pt.Results | nil, cur?: pt.Results | nil): string
end

local M: compare = {
  DEFAULT_THRESHOLD_PCT = DEFAULT_THRESHOLD_PCT,
  TRIAGE_K = TRIAGE_K,
  load_results = load_results,
  same_binary = same_binary,
  identity_refusal = identity_refusal,
  diff = diff,
  triage = triage,
  triage_many = triage_many,
  loudest_control = loudest_control,
  format_delta = format_delta,
  format_identity = format_identity,
  format = format,
}

return M
