#!/usr/bin/env lua
--- Perf gate orchestration: the compare retry and the A/A triage behind
--- the compare and selfcheck gates, in Teal rather than as
--- shell ||-chains. A flagged regression re-measures once and fails
--- only when it strikes in BOTH passes — a scenario that flags only in
--- the retry did not reproduce and reclassifies to noise. When the
--- caller can re-run the baseline binary (--baseline-bin), the retry
--- re-measures BOTH sides, because a single unlucky baseline reading
--- otherwise anchors every pass and no amount of current-side retrying
--- washes it out. A persisting regression then meets an A/A self-check
--- that reclassifies swings the current binary shows against itself as
--- noise. Measurement is injected so the orchestration is testable
--- without running real benchmarks; main wires perf.run.
local compare = require("_perf.compare")
local pt = require("_perf.perf_types")
local proc = require("cosmic.proc")

local type Measure = function(out: string): integer

local record GateOptions
  baseline: string
  current: string
  selfcheck_b: string
  threshold: number
  measure: Measure
  --- Re-measures the BASELINE binary into a path; nil when the caller
  --- cannot re-run it (the retry then re-reads the baseline file).
  measure_baseline: Measure
end

local record SelfcheckOptions
  a: string
  b: string
  threshold: number
  measure: Measure
end

local usage < const > = [[
usage: gate.lua compare BASE.json CUR.json SELFB.json [--threshold PCT]
         [--baseline-bin PATH] <run args...>
         BASE, CUR: read; SELFB: written by the A/A pass
         a flagged regression re-measures into CUR's sibling CUR-retry.json
         and fails only when it flags in both passes; --baseline-bin also
         re-measures PATH into BASE's sibling BASE-retry.json on retry
       gate.lua selfcheck A.json B.json [--threshold PCT] <run args...>
         A, B: both written -- selfcheck's job is to measure twice
]]

--- Where a flagged regression's re-measurement goes: beside the
--- caller's own current file, never over it. A trailing `.json` is
--- replaced so `o/perf/current.json` becomes
--- `o/perf/current-retry.json`; any other spelling just gains the
--- suffix.
--- @param cur_path string The caller's current results path
--- @return string The retry's own path
local function retry_path(cur_path: string): string
  local stem = cur_path:match("^(.*)%.json$")
  return (stem or cur_path) .. "-retry.json"
end

--- Load and compare (optionally triaged) one comparison. The caller
--- prints the deltas (`compare.format`) — the final pass amends
--- verdicts before printing, so printing here would show a table the
--- gate did not act on.
--- @param base_path string Baseline results path
--- @param cur_path string Current results path
--- @param threshold number? Noise bar in percent
--- @param control_paths {string}? Same-binary control runs; triage mode when two or more
--- @return integer Failure count, or -1 on a load error
--- @return string? Error message when loading failed
--- @return {pt.Delta}? The per-scenario deltas the count came from
local function compare_once(base_path: string, cur_path: string,
    threshold: number, control_paths?: {string}): integer, string, {pt.Delta}
  local base, berr = compare.load_results(base_path)
  if base == nil then
    return -1, berr
  end
  local cur, cerr = compare.load_results(cur_path)
  if cur == nil then
    return -1, cerr
  end
  local deltas, failures = compare.diff(base, cur, threshold)
  if control_paths and #control_paths >= 2 then
    local controls: {pt.Results} = {}
    for _, path in ipairs(control_paths) do
      local c, cerr2 = compare.load_results(path)
      if c == nil then
        return -1, cerr2
      end
      controls[#controls + 1] = c
    end
    deltas, failures = compare.triage_many(base, cur, controls, threshold)
  end
  return failures, nil, deltas
end

--- The identity rule of `compare.identity_refusal`, over two paths.
--- @param a string First results path
--- @param b string Second results path
--- @param same boolean Whether the two must name the SAME binary
--- @return string|nil The refusal, or nil when the pair is sound
local function identity_refusal(a: string, b: string, same: boolean): string | nil
  local ra = compare.load_results(a)
  local rb = compare.load_results(b)
  if ra == nil or rb == nil then
    -- A file that will not load is the next call's error to report, in
    -- its own words.
    return nil
  end
  return compare.identity_refusal(a, ra, b, rb, same)
end

--- Print the gate's verdict and pass its code through. The line is the
--- same convention as `ci: PASS` and exists for the same reason: a
--- piped invocation (`gate.lua ... | tail`) returns the pipe's exit
--- status, so the verdict must survive in the output itself.
--- @param rc integer The gate's exit code
--- @return integer The same code, unchanged
local function verdict(rc: integer): integer
  if rc == 0 then
    print("perf-compare: PASS")
  else
    print("perf-compare: FAIL")
  end
  return rc
end

--- The compare gate's decision, without its verdict line.
--- @param opts GateOptions Paths, threshold, and the measure function
--- @return integer Exit code: 0 clean or noise, 1 on a real regression
local function gate_inner(opts: GateOptions): integer
  local refusal = identity_refusal(opts.baseline, opts.current, false)
  if refusal then
    io.stderr:write(refusal .. "\n")
    return 1
  end
  local failures, err, deltas =
  compare_once(opts.baseline, opts.current, opts.threshold)
  if failures < 0 then
    io.stderr:write(tostring(err) .. "\n")
    return 1
  end
  print(compare.format(deltas))
  if failures == 0 then
    return 0
  end
  -- Pass 1's flags. A regression fails the gate only when it flags in
  -- BOTH passes: a scenario clean here that flags only in the retry did
  -- not reproduce, and reclassifies at the final judgment below. Only
  -- `regression` is subject to the rule — error/missing/baseline-error/
  -- malformed verdicts fail on their own in whichever pass they appear.
  local flagged_first: {string: boolean} = {}
  for _, d in ipairs(deltas) do
    if d.verdict == "regression" then
      flagged_first[d.name] = true
    end
  end
  local retry = retry_path(opts.current)
  print("perf-compare: regression flagged; re-measuring once into " .. retry ..
    " to filter noise")
  local rc = opts.measure(retry)
  if rc ~= 0 then
    return rc
  end
  local base_side = opts.baseline
  if opts.measure_baseline then
    -- Re-measure the baseline binary too: pass 1's base numbers came
    -- from a single run, and a one-off reading there anchors every
    -- later pass — no amount of current-side retrying washes it out.
    base_side = retry_path(opts.baseline)
    print("perf-compare: re-measuring the baseline into " .. base_side ..
      " so a one-off baseline reading cannot anchor the verdict")
    rc = opts.measure_baseline(base_side)
    if rc ~= 0 then
      return rc
    end
    -- A baseline retry is only a retry if it re-measured the SAME
    -- binary the baseline file names.
    refusal = identity_refusal(opts.baseline, base_side, true)
    if refusal then
      io.stderr:write(refusal .. "\n")
      return 1
    end
  end
  -- The retry measured under whatever binary is running now, which may
  -- not be the one the baseline was measured against. Re-check identity
  -- against that freshly measured file, or a real regression can be
  -- masked by an identity change mid-retry.
  refusal = identity_refusal(base_side, retry, false)
  if refusal then
    io.stderr:write(refusal .. "\n")
    return 1
  end
  failures, err, deltas = compare_once(base_side, retry, opts.threshold)
  if failures < 0 then
    io.stderr:write(tostring(err) .. "\n")
    return 1
  end
  print(compare.format(deltas))
  if failures == 0 then
    return 0
  end
  print("perf-compare: regression persists; running A/A self-check to separate" ..
    " real regressions from machine noise")
  rc = opts.measure(opts.selfcheck_b)
  if rc ~= 0 then
    return rc
  end
  -- The A/A control is only a noise floor if it names the SAME binary
  -- as current; check that before triage(), which otherwise trusts the
  -- pair silently.
  refusal = identity_refusal(retry, opts.selfcheck_b, true)
  if refusal then
    io.stderr:write(refusal .. "\n")
    return 1
  end
  -- Three runs of the current binary exist by now — the caller's
  -- `current`, the retry, and the self-check — so there are three
  -- control PAIRS to read noise from, not one. A scenario can be quiet
  -- in one pair and swing in the next (that is the variance being
  -- measured), so triaging against every pair catches an unstable
  -- scenario the single retry/self-check pair happens to miss. The
  -- extra pairs cost nothing: the runs are already measured.
  --
  -- `current` joins the controls only when it names the SAME binary as
  -- the retry. When it does not, it is a control lost, not a refusal —
  -- the pair that must hold is checked above, and dropping `current`
  -- leaves exactly the one pair the gate read before.
  local controls = {retry, opts.selfcheck_b}
  if identity_refusal(retry, opts.current, true) == nil then
    table.insert(controls, 1, opts.current)
  end
  failures, err, deltas = compare_once(base_side, retry, opts.threshold, controls)
  if failures < 0 then
    io.stderr:write(tostring(err) .. "\n")
    return 1
  end
  -- The strike-twice rule: a regression standing here that pass 1 did
  -- not flag appeared only in the retry — it did not reproduce, and a
  -- verdict the gate would not act on may not stand in the printed
  -- table, which is the record.
  for _, d in ipairs(deltas) do
    if d.verdict == "regression" and not flagged_first[d.name] then
      d.verdict = "noise"
      failures = failures - 1
      print("perf-compare: " .. d.name ..
        " flagged only in the retry -- not reproduced, counted as noise")
    end
  end
  print(compare.format(deltas))
  if failures > 0 then
    io.stderr:write("perf: " .. failures ..
      " scenario(s) regressed, errored, or went missing\n")
    return 1
  end
  return 0
end

--- Run the compare gate over an already-measured current file, ending
--- with the one-line verdict.
--- @param opts GateOptions Paths, threshold, and the measure function
--- @return integer Exit code: 0 clean or noise, 1 on a real regression
local function gate(opts: GateOptions): integer
  return verdict(gate_inner(opts))
end

--- Measure the same binary twice and report the machine's noise floor.
--- Informational: always exits 0 (the verdict text is the product).
--- @param opts SelfcheckOptions Paths, threshold, and the measure function
--- @return integer Exit code: 0 unless measurement or loading failed
local function selfcheck(opts: SelfcheckOptions): integer
  local rc = opts.measure(opts.a)
  if rc ~= 0 then
    return rc
  end
  rc = opts.measure(opts.b)
  if rc ~= 0 then
    return rc
  end
  local refusal = identity_refusal(opts.a, opts.b, true)
  if refusal then
    io.stderr:write(refusal .. "\n")
    return 1
  end
  local failures, err, deltas = compare_once(opts.a, opts.b, opts.threshold)
  if failures < 0 then
    io.stderr:write(tostring(err) .. "\n")
    return 1
  end
  print(compare.format(deltas))
  if failures == 0 then
    print("perf-selfcheck: nothing exceeded the bar — the machine is quiet" ..
      " at this threshold")
  else
    print("perf-selfcheck: the scenarios flagged above vary by more than the" ..
      " bar on noise alone; discount same-named perf-compare regressions")
  end
  return 0
end

--- CLI entry point. The results paths are positional (right after the
--- mode); every remaining argument except --threshold is handed to
--- perf.run per measurement pass (with --out prepended). Deliberately
--- no `--` separator: the cosmic dispatcher consumes a standalone `--`
--- before the script ever sees its arguments (witnessed).
--- @param ... string Command-line arguments
--- @return integer Exit code
local function main(...: string): integer
  local argv = {...}
  local mode = argv[1]
  local want = 0
  if mode == "compare" then
    want = 3
  elseif mode == "selfcheck" then
    want = 2
  end
  if want == 0 or #argv < 1 + want then
    io.stderr:write(usage)
    return 2
  end
  local paths: {string} = {}
  for i = 2, 1 + want do
    paths[#paths + 1] = argv[i]
  end
  local threshold: number = nil
  local baseline_bin: string = nil
  local runargs: {string} = {}
  local i = want + 2
  while i <= #argv do
    local v = argv[i]
    if v == "--threshold" then
      i = i + 1
      threshold = tonumber(argv[i])
    elseif v == "--baseline-bin" then
      i = i + 1
      baseline_bin = argv[i]
    else
      runargs[#runargs + 1] = v
    end
    i = i + 1
  end
  local run = require("_perf.run")
  local function measure(out: string): integer
    local margs: {string} = {"--out", out}
    for _, r in ipairs(runargs) do
      margs[#margs + 1] = r
    end
    return run.main(table.unpack(margs))
  end
  local measure_baseline: Measure = nil
  if baseline_bin then
    -- baserun's shape, which release.yml's compare step also uses: the
    -- TREE's _perf measured on the baseline binary's own cosmic. One
    -- definition rather than two argvs, because the retry is what
    -- decides the gate — a retry that resolved _perf differently from
    -- pass 1 would answer a different question than the one that
    -- flagged.
    local child = require("cosmic.child")
    local baserun = require("_perf.baserun")
    local fs = require("cosmic.fs")
    measure_baseline = function(out: string): integer
      local cwd, cwderr = fs.cwd()
      if cwd == nil then
        io.stderr:write("perf-compare: baseline re-measure failed: " ..
          tostring(cwderr) .. "\n")
        return 1
      end
      local manifest, merr = baserun.ensure_root(cwd, "o")
      if manifest == nil then
        io.stderr:write("perf-compare: baseline re-measure failed: " ..
          merr .. "\n")
        return 1
      end
      local extra: {string} = {"--out", out}
      for _, r in ipairs(runargs) do
        extra[#extra + 1] = r
      end
      local res, cerr = child.run(baserun.argv(baseline_bin, manifest, extra),
        {stdout = "inherit", stderr = "inherit"})
      if res == nil then
        io.stderr:write("perf-compare: baseline re-measure failed: " ..
          tostring(cerr) .. "\n")
        return 1
      end
      return res.code or 1
    end
  end
  if mode == "compare" then
    return gate({
        baseline = paths[1],
        current = paths[2],
        selfcheck_b = paths[3],
        threshold = threshold,
        measure = measure,
        measure_baseline = measure_baseline,
      })
  end
  return selfcheck({
      a = paths[1],
      b = paths[2],
      threshold = threshold,
      measure = measure,
    })
end

if proc.is_main() then
  os.exit(main(...))
end

local record gate_module
  type GateOptions = GateOptions
  type SelfcheckOptions = SelfcheckOptions
  gate: function(opts: GateOptions): integer
  selfcheck: function(opts: SelfcheckOptions): integer
  main: function(...: string): integer
end

local M: gate_module = {
  gate = gate,
  selfcheck = selfcheck,
  main = main,
}

return M
