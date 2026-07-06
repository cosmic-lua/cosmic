--- Subprocess execution scenarios: raw fork/exec/wait overhead via
--- cosmic.child, isolated from the "boot a Lua runtime" cost that the
--- startup_* scenarios (startup_bench.tl) measure by spawning cosmic
--- itself. This spawns /bin/true, about as cheap an exec target as
--- exists, so what's left is spawn()'s own pipe setup, fork, and wait.

local child = require("cosmic.child")
local pt = require("perf.perf_types")

local function scenarios(): {pt.Scenario}, string
  return {
    {
      name = "child_spawn_true",
      fn = function(_: any): any
        local handle, err = child.spawn({"/bin/true"})
        assert(handle, err)
        local hh = handle as child.Handle
        local _, _, code = hh:read()
        return code
      end,
      check = function(_: any, res: any): boolean, string
        if res as integer ~= 0 then
          return false, "expected exit code 0, got " .. tostring(res)
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
