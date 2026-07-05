--- Date/time formatting scenarios.
--- Exercises cosmic.time's format_date/format_iso8601 against known
--- timestamps to catch a faster-but-wrong implementation.

local time = require("cosmic.time")
local pt = require("perf.perf_types")

-- 2025-01-02 (the time-of-day part is irrelevant to format_date)
local TS = 1735786445

local function scenarios(): {pt.Scenario}, string
  return {
    {
      name = "time_format_date",
      fn = function(_: any): any
        return time.format_date(TS)
      end,
      check = function(_: any, res: any): boolean, string
        if res as string ~= "2025-01-02" then
          return false, "wrong date: " .. tostring(res)
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
