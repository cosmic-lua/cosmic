--- Formatter scenario: cosmic.format over a representative module.
--- The formatter runs on every file in every fmt gate and dev loop, so
--- its per-file cost is toolchain wall clock; no scenario covered it.
--- The input is a deterministic ~400-line Teal module built in memory.
--- The check pins ok=true and idempotence — formatting the formatter's
--- own output must be a fixpoint — so a faster-but-wrong renderer that
--- drops or reflows tokens fails instead of winning.

local format = require("cosmic.format")
local pt = require("_perf.perf_types")

local SECTIONS = 24

--- Build a deterministic, syntactically valid Teal module of about
--- 400 lines: records, doc comments, and functions with real bodies,
--- shaped like a typical cosmic module rather than a synthetic token
--- soup.
--- @return string The module source
local function build_module_source(): string
  local parts: {string} = {}
  for i = 1, SECTIONS do
    parts[#parts + 1] = string.format([[
--- A labeled point in plane %03d, used by its magnitude function.
local record Point%03d
  x: number
  y: number
  label: string
end

--- Scale p by k and report the squared magnitude, zero when the
--- label is empty (a placeholder branch so the body has real shape).
--- @param p Point%03d The point
--- @param k number The scale factor
--- @return number The scaled squared magnitude
local function magnitude%03d(p: Point%03d, k: number): number
  local dx = p.x * k
  local dy = p.y * k
  if p.label == "" then
    return 0
  end
  return dx * dx + dy * dy
end
]], i, i, i, i, i)
  end
  parts[#parts + 1] = "return {\n"
  for i = 1, SECTIONS do
    parts[#parts + 1] = string.format("  magnitude%03d = magnitude%03d,\n", i, i)
  end
  parts[#parts + 1] = "}\n"
  return table.concat(parts)
end

local SOURCE = build_module_source()

local function scenarios(): {pt.Scenario}, string
  return {
    {
      name = "format_module_source",
      fn = function(_: any): any
        return format.format(SOURCE, "bench_module.tl")
      end,
      check = function(_: any, res: any): boolean, string
        local r = res as format.FormatResult -- cast: from any
        if r == nil then
          return false, "no result"
        end
        if not r.ok then
          return false, "format failed: " .. format.format_issues(r.errors)
        end
        local code = r.code
        if code == nil then
          return false, "ok result carried no code"
        end
        local again = format.format(code, "bench_module.tl")
        if not again.ok then
          return false, "reformat failed: " .. format.format_issues(again.errors)
        end
        if again.code ~= code then
          return false, "formatting is not idempotent"
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
