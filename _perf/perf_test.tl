-- Smoke test for the perf harness: every bench module must load, every
-- scenario must define a functional check, carry a unique name, and pass
-- end to end with tiny settings. This keeps the scenarios from bit-rotting
-- and enforces the no-check-no-benchmark guardrail in CI.
--
-- The module list is DERIVED from _perf/bench/*_bench.tl rather than
-- hardcoded: a hardcoded list silently stops covering a new bench module
-- (add one, forget to list it, no check-presence ratchet ever runs it).

local fs = require("cosmic.fs")
local harness = require("_perf.harness")
local pt = require("_perf.perf_types")

local BENCH_DIR = "_perf/bench"

--- List every bench module under BENCH_DIR as a require()-able name.
--- @return {string} Sorted module names, e.g. "_perf.bench.json_bench"
local function discover_modules(): {string}
  local paths, err = fs.glob(BENCH_DIR, "*_bench.tl")
  if paths == nil then
    error("cannot list " .. BENCH_DIR .. ": " .. tostring(err))
  end
  local names: {string} = {}
  for _, p in ipairs(paths as {string}) do -- cast: narrowed by the nil guard above
    local stem = fs.split_extension(fs.basename(p))
    table.insert(names, "_perf.bench." .. stem)
  end
  table.sort(names)
  return names
end

local MODULES = discover_modules()

local SMOKE: pt.Options = {samples = 2, min_sample_secs = 0.001}

local function test_all_scenarios_pass()
  assert(#MODULES > 0, "no bench modules discovered under " .. BENCH_DIR)
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
