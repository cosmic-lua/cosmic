--- Coverage minimum-percentage gate: `cosmic --make coverage --min PCT
--- [--min-file PCT]` refuses when overall or any file's line coverage
--- falls under the given floor.
---
--- Reads the same `.cov`/`FileReport` data the plain coverage report
--- already reads (`_tool.coverage.report.compute`) -- no committed
--- floor file, no ratchet, no rewrite: the floor is two numbers on the
--- command line, stated where the project's own gate is invoked
--- (`.github/workflows/pr.yml` for this tree). With neither option,
--- `gate` is `report.report` verbatim -- instrumented coverage with no
--- threshold renders the table and passes.
local rep = require("_tool.coverage.report")
local gaps = require("_tool.coverage.gaps")

local type FileReport = rep.FileReport

--- Refusal lines for reports under either floor -- pure, no I/O, so
--- `minimum_test.tl` asserts on synthetic reports with no filesystem
--- or `.cov` data in play.
---
--- The percentage math is inline rather than a shared helper: a file
--- (or a run) with no executable lines counts as fully covered, the
--- same divide-by-zero convention `report.render` uses, but a
--- standalone function with that exact body would be a byte-for-byte
--- copy of `_tool/coverage/baseline.tl`'s `pct` -- the duplicate-body
--- gate's job to catch, not this file's to risk.
--- @param reports {FileReport} Sorted results from report.compute
--- @param min number|nil Overall floor, percent (nil: not checked)
--- @param min_file number|nil Per-file floor, percent (nil: not checked)
--- @return {string} Violations, sorted; empty when both floors hold
local function violations(reports: {FileReport}, min: number | nil,
    min_file: number | nil): {string}
  local problems: {string} = {}
  if min_file then
    for _, r in ipairs(reports) do
      local have = r.total > 0 and (100.0 * r.covered / r.total) or 100.0
      if have < min_file then
        local problem = string.format(
          "%s: %.1f%% under --min-file %.1f%% (%d/%d)",
          r.display, have, min_file, r.covered, r.total)
        if #r.missing > 0 then
          problem = problem .. "  uncovered: " .. gaps.format_ranges(r.missing, 8)
        end
        problems[#problems + 1] = problem
      end
    end
  end
  if min then
    local covered_sum, total_sum = 0, 0
    for _, r in ipairs(reports) do
      covered_sum = covered_sum + r.covered
      total_sum = total_sum + r.total
    end
    local have = total_sum > 0 and (100.0 * covered_sum / total_sum) or 100.0
    if have < min then
      problems[#problems + 1] = string.format(
        "total: %.1f%% under --min %.1f%% (%d/%d)",
        have, min, covered_sum, total_sum)
    end
  end
  table.sort(problems)
  return problems
end

--- `cosmic --make coverage [--min PCT] [--min-file PCT]` -- the
--- min-percent gate.
---
--- A violation is named with its percentage, plus a one-line
--- "declined:" summary last -- the format the coverage ratchet this
--- replaces already earned (`_tool/coverage/baseline.tl`): the record
--- that has to survive a truncated CI log goes last and fits on one
--- line.
--- @param paths {string} Report inputs (see report.compute)
--- @param min number|nil Overall floor, percent
--- @param min_file number|nil Per-file floor, percent
--- @return integer Exit code: 0 when both floors hold, or neither is set
local function gate(paths: {string}, min: number | nil,
    min_file: number | nil): integer
  if min == nil and min_file == nil then
    return rep.report(paths)
  end
  local reports, cerr = rep.compute(paths)
  if not reports then
    io.stderr:write((cerr or "coverage: no data") .. "\n")
    return 1
  end
  local problems = violations(reports, min, min_file)
  if #problems == 0 then
    io.write("coverage minimum ok\n")
    return 0
  end
  local names: {string} = {}
  for _, p in ipairs(problems) do
    io.stderr:write("coverage minimum: " .. p .. "\n")
    names[#names + 1] = (p:match("^([^:]+):")) or p
  end
  io.stderr:write(string.format(
      "coverage minimum: %d problem(s); declined: %s\n",
      #problems, table.concat(names, " ")))
  return 1
end

local record MinimumModule
  violations: function(reports: {FileReport}, min: number | nil,
  min_file: number | nil): {string}
  gate: function(paths: {string}, min: number | nil, min_file: number | nil): integer
end

local M: MinimumModule = {
  violations = violations,
  gate = gate,
}

return M
