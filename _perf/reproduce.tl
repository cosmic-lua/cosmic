--- The perf gate's reproduction rule, both directions, in one place.
---
--- Two independent current-side samples judge every flagged regression,
--- and the two ways they can disagree are not symmetric:
---
--- - a regression standing in pass 2 that pass 1 did not flag appeared
---   only in the retry. It did not reproduce and reclassifies to the
---   non-failing verdict "noise", with no control required.
--- - a regression pass 1 flagged that pass 2 reads quiet is a
---   DISMISSAL, and a dismissal owes evidence. It stands only when the
---   same-binary controls show that scenario swinging by enough to
---   explain the two samples disagreeing -- the credit rule
---   `triage_many` already applies, |pass-1 delta| <= max(pass-1 noise
---   bar, TRIAGE_K * |loudest control delta|). An unexplained dismissal
---   has its verdict amended back to "regression", which both restores
---   it to the printed record and escalates it to the A/A self-check
---   and full triage like any other persisting regression.
---
--- In closed form, with noise bar N, a pass-1 delta f > N and a pass-2
--- delta r <= N over a control pair reading roughly f - r, a dismissal
--- is unexplained exactly when N < f < 2r: both samples agree the
--- scenario is up and one merely fell under the bar. The loud,
--- genuinely non-reproducing dismissal is absorbed as before.
---
--- The controls are the current-side runs the gate already has on
--- disk, so the rule costs no measurement pass. No baseline-versus-
--- current pair -- the comparison under test -- is ever formed.

local compare = require("_perf.compare")
local pt = require("_perf.perf_types")

--- Amend the verdict of every unexplained dismissal in `deltas`.
--- Walks `deltas` in array order, so the messages come out in the
--- report's own order rather than a hash order.
--- @param deltas {Delta} The final pass's deltas, amended in place
--- @param flagged {string: Delta} Pass 1's flags, by scenario name
--- @param controls {Results} Same-binary control runs
--- @param threshold number? Noise bar in percent
--- @return {string} One message per restored dismissal
local function restore(deltas: {pt.Delta}, flagged: {string: pt.Delta},
    controls: {pt.Results}, threshold?: number): {string}
  local messages: {string} = {}
  local loudest = compare.loudest_control(controls, threshold)
  for _, d in ipairs(deltas) do
    local first = flagged[d.name]
    if first ~= nil and (d.verdict == "ok" or d.verdict == "faster") then
      -- Record FIELDS do not narrow, so the two the rule reads are
      -- copied to locals before the guard.
      local flagged_pct = first.delta_pct
      local flagged_noise = first.noise_pct
      if flagged_pct ~= nil then
        local credit = flagged_noise or 0
        local control = loudest[d.name]
        if control ~= nil and control.delta_pct ~= nil then
          credit = math.max(credit, compare.TRIAGE_K * math.abs(control.delta_pct))
        end
        if math.abs(flagged_pct) > credit then
          d.verdict = "regression"
          messages[#messages + 1] = "perf-compare: " .. d.name ..
          " flagged in pass 1 and read quiet on the retry, but no same-binary" ..
          " control explains the gap -- counted as a regression"
        end
      end
    end
  end
  return messages
end

--- `restore` over control PATHS. A file that will not load is dropped
--- rather than refused: it only removes noise credit, and the file is
--- the next call's error to report, in its own words.
--- @param deltas {Delta} The final pass's deltas, amended in place
--- @param flagged {string: Delta} Pass 1's flags, by scenario name
--- @param control_paths {string} Paths to same-binary control runs
--- @param threshold number? Noise bar in percent
--- @return {string} One message per restored dismissal
local function restore_paths(deltas: {pt.Delta}, flagged: {string: pt.Delta},
    control_paths: {string}, threshold?: number): {string}
  local controls: {pt.Results} = {}
  for _, path in ipairs(control_paths) do
    local results = compare.load_results(path)
    if results ~= nil then
      controls[#controls + 1] = results
    end
  end
  return restore(deltas, flagged, controls, threshold)
end

--- Both directions of the rule over one pass's deltas: reclassify the
--- regressions pass 1 did not flag, then restore the dismissals no
--- control explains.
---
--- The restore half runs only when the two current-side samples
--- measured the SAME binary, since two samples are comparable to each
--- other on no other terms.
--- @param deltas {Delta} The final pass's deltas, amended in place
--- @param flagged {string: Delta} Pass 1's flags, by scenario name
--- @param control_paths {string} Paths to same-binary control runs
--- @param threshold number? Noise bar in percent
--- @param same_side boolean Whether the two current-side samples agree on the binary
--- @return {string} The messages to print, in report order
--- @return integer The change to the caller's failure count
local function reconcile(deltas: {pt.Delta}, flagged: {string: pt.Delta},
    control_paths: {string}, threshold: number, same_side: boolean): {string}, integer
  local messages: {string} = {}
  local change = 0
  for _, d in ipairs(deltas) do
    if d.verdict == "regression" and flagged[d.name] == nil then
      d.verdict = "noise"
      change = change - 1
      messages[#messages + 1] = "perf-compare: " .. d.name ..
      " flagged only in the retry -- not reproduced, counted as noise"
    end
  end
  if same_side then
    for _, m in ipairs(restore_paths(deltas, flagged, control_paths, threshold)) do
      messages[#messages + 1] = m
      change = change + 1
    end
  end
  return messages, change
end

local record reproduce
  restore: function(deltas: {pt.Delta}, flagged: {string: pt.Delta}, controls: {pt.Results}, threshold?: number): {string}
  restore_paths: function(deltas: {pt.Delta}, flagged: {string: pt.Delta}, control_paths: {string}, threshold?: number): {string}
  reconcile: function(deltas: {pt.Delta}, flagged: {string: pt.Delta}, control_paths: {string}, threshold: number, same_side: boolean): {string}, integer
end

local M: reproduce = {
  restore = restore,
  restore_paths = restore_paths,
  reconcile = reconcile,
}

return M
