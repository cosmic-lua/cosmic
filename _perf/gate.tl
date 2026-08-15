#!/usr/bin/env lua
--- Perf gate orchestration: the compare retry and the A/A triage behind
--- the compare and selfcheck gates, in Teal rather than as
--- shell ||-chains. A flagged regression re-measures once (noise
--- must strike twice in the same direction); if it persists, an A/A
--- self-check reclassifies swings the current binary shows against
--- itself as noise. Measurement is injected so the orchestration is
--- testable without running real benchmarks; main wires perf.run.
local compare = require("_perf.compare")
local proc = require("cosmic.proc")

local type Measure = function(out: string): integer

local record GateOptions
  baseline: string
  current: string
  selfcheck_b: string
  threshold: number
  measure: Measure
end

local record SelfcheckOptions
  a: string
  b: string
  threshold: number
  measure: Measure
end

local usage < const > = [[
usage: gate.lua compare BASE.json CUR.json SELFB.json [--threshold PCT] <run args...>
       gate.lua selfcheck A.json B.json [--threshold PCT] <run args...>
]]

--- Load, compare (optionally triaged), and print one comparison.
--- @param base_path string Baseline results path
--- @param cur_path string Current results path
--- @param threshold number? Noise bar in percent
--- @param na_path string? A/A control A (triage mode when both set)
--- @param nb_path string? A/A control B
--- @return integer Failure count, or -1 on a load error
--- @return string? Error message when loading failed
local function compare_once(base_path: string, cur_path: string,
    threshold: number, na_path?: string, nb_path?: string): integer, string
  local base, berr = compare.load_results(base_path)
  if base == nil then
    return -1, berr
  end
  local cur, cerr = compare.load_results(cur_path)
  if cur == nil then
    return -1, cerr
  end
  local deltas, failures = compare.diff(base, cur, threshold)
  if na_path and nb_path then
    local na, naerr = compare.load_results(na_path)
    if na == nil then
      return -1, naerr
    end
    local nb, nberr = compare.load_results(nb_path)
    if nb == nil then
      return -1, nberr
    end
    deltas, failures = compare.triage(base, cur, na, nb, threshold)
  end
  print(compare.format(deltas))
  return failures
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
  local failures, err = compare_once(opts.baseline, opts.current, opts.threshold)
  if failures < 0 then
    io.stderr:write(tostring(err) .. "\n")
    return 1
  end
  if failures == 0 then
    return 0
  end
  print("perf-compare: regression flagged; re-measuring once to filter noise")
  local rc = opts.measure(opts.current)
  if rc ~= 0 then
    return rc
  end
  -- The retry just overwrote current.json under whatever binary is
  -- running now, which may not be the one the baseline was measured
  -- against. Re-check identity against that freshly measured file, or a
  -- real regression can be masked by an identity change mid-retry.
  refusal = identity_refusal(opts.baseline, opts.current, false)
  if refusal then
    io.stderr:write(refusal .. "\n")
    return 1
  end
  failures, err = compare_once(opts.baseline, opts.current, opts.threshold)
  if failures < 0 then
    io.stderr:write(tostring(err) .. "\n")
    return 1
  end
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
  refusal = identity_refusal(opts.current, opts.selfcheck_b, true)
  if refusal then
    io.stderr:write(refusal .. "\n")
    return 1
  end
  failures, err = compare_once(opts.baseline, opts.current, opts.threshold,
    opts.current, opts.selfcheck_b)
  if failures < 0 then
    io.stderr:write(tostring(err) .. "\n")
    return 1
  end
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
  local failures, err = compare_once(opts.a, opts.b, opts.threshold)
  if failures < 0 then
    io.stderr:write(tostring(err) .. "\n")
    return 1
  end
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
  local runargs: {string} = {}
  local i = want + 2
  while i <= #argv do
    local v = argv[i]
    if v == "--threshold" then
      i = i + 1
      threshold = tonumber(argv[i])
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
  if mode == "compare" then
    return gate({
        baseline = paths[1],
        current = paths[2],
        selfcheck_b = paths[3],
        threshold = threshold,
        measure = measure,
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
