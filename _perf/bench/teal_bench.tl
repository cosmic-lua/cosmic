--- Teal checker scenario: cosmic.teal.check over a representative
--- module, in-process. startup_compile_teal measures a whole compile
--- child (dominated by process boot and env construction); this
--- isolates the checker's marginal, size-scaling cost — the number
--- that governs how build time grows with the tree and that batching
--- compile children (#1099) cannot amortize away.
--- The input is dependency-free (no requires), so the check needs no
--- include path and the scenario is hermetic.

local teal = require("cosmic.teal")
local pt = require("_perf.perf_types")

local SECTIONS = 18

--- Build a deterministic, warning-free Teal module of about 300
--- lines: records used by function signatures, functions all exported,
--- so `werror` (the default, matching --check types) stays green.
--- @return string The module source
local function build_module_source(): string
  local parts: {string} = {}
  for i = 1, SECTIONS do
    parts[#parts + 1] = string.format([[
--- A labeled span on axis %03d, consumed by its width function.
local record Span%03d
  low: number
  high: number
  label: string
end

--- Width of s scaled by k, negative widths clamped to zero.
--- @param s Span%03d The span
--- @param k number The scale factor
--- @return number The clamped scaled width
local function width%03d(s: Span%03d, k: number): number
  local w = (s.high - s.low) * k
  if w < 0 or s.label == "" then
    return 0
  end
  return w
end
]], i, i, i, i, i)
  end
  parts[#parts + 1] = "return {\n"
  for i = 1, SECTIONS do
    parts[#parts + 1] = string.format("  width%03d = width%03d,\n", i, i)
  end
  parts[#parts + 1] = "}\n"
  return table.concat(parts)
end

local SOURCE = build_module_source()

local function scenarios(): {pt.Scenario}, string
  return {
    {
      name = "teal_check_module",
      fn = function(_: any): any
        return teal.check(SOURCE)
      end,
      check = function(_: any, res: any): boolean, string
        local r = res as teal.CheckResult -- cast: from any
        if r == nil then
          return false, "no result"
        end
        if not r.ok then
          return false, "check failed: " .. teal.format_issues(r.errors)
        end
        if #r.errors > 0 or #r.warnings > 0 then
          return false, string.format("unexpected issues: %d errors, %d warnings",
            #r.errors, #r.warnings)
        end
        return true
      end,
    },
  }
end

local function cleanup()
end

local M: pt.BenchModule = {
  scenarios = scenarios,
  cleanup = cleanup,
}

return M
