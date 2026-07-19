-- Smoke test for the perf harness: every bench module must load, every
-- scenario must define a functional check, carry a unique name, and pass
-- end to end with tiny settings. This keeps the scenarios from bit-rotting
-- and enforces the no-check-no-benchmark guardrail in CI.

local harness = require("perf.harness")
local pt = require("perf.perf_types")

local MODULES = {
  "perf.bench.json_bench",
  "perf.bench.sqlite_bench",
  "perf.bench.http_bench",
  "perf.bench.fs_bench",
  "perf.bench.micro_bench",
  "perf.bench.startup_bench",
}

local SMOKE: pt.Options = {samples = 2, min_sample_secs = 0.001}

local function test_all_scenarios_pass()
  local seen: {string: boolean} = {}
  for _, name in ipairs(MODULES) do
    local ok, mod = pcall(require, name)
    assert(ok, name .. ": " .. tostring(mod))
    local bench = mod as pt.BenchModule -- cast: from any
    assert(bench.scenarios ~= nil, name .. ": missing scenarios()")
    assert(bench.cleanup ~= nil, name .. ": missing cleanup()")

    local scenarios, serr = bench.scenarios()
    assert(scenarios ~= nil, name .. ": scenarios: " .. tostring(serr))
    assert(#scenarios > 0, name .. ": no scenarios returned")

    for _, s in ipairs(scenarios) do
      assert(s.name ~= nil and #s.name > 0, name .. ": scenario without a name")
      assert(not seen[s.name], name .. ": duplicate scenario name " .. s.name)
      seen[s.name] = true
      assert(s.check ~= nil, name .. "/" .. s.name
        .. ": scenario has no check(); every scenario must validate its output")
      assert(s.fn ~= nil, name .. "/" .. s.name .. ": scenario has no fn()")

      local m = harness.run_scenario(s, SMOKE)
      assert(m.error == nil, name .. "/" .. s.name .. ": " .. tostring(m.error))
      assert(m.wall_ns ~= nil and m.wall_ns > 0, name .. "/" .. s.name .. ": no timing")
      assert(m.iterations >= 1, name .. "/" .. s.name .. ": no iterations")
    end
    bench.cleanup()
  end
end
test_all_scenarios_pass()

print("OK perf_test")
